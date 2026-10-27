package scan

import (
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"numident/internal/catalog"
	"numident/internal/layout"
	"numident/internal/synth"
)

func genData(t *testing.T, people int) (string, synth.Summary) {
	t.Helper()
	dir := t.TempDir()
	sum, err := synth.Generate(synth.Options{Dir: dir, People: people, Seed: 7})
	if err != nil {
		t.Fatal(err)
	}
	return dir, sum
}

func jobsFor(dir string, sets ...layout.Set) []Job {
	r := catalog.Scan(dir)
	var jobs []Job
	for _, s := range sets {
		for _, f := range r.Set(s).Files {
			if f.Searchable() {
				jobs = append(jobs, Job{Set: s, Name: f.Name, Path: f.Path, Size: f.Size, ModTime: f.ModTime})
			}
		}
	}
	return jobs
}

// bruteForce counts matching lines by reading every file whole.
func bruteForce(t *testing.T, jobs []Job, m *Matcher) int {
	n := 0
	for _, j := range jobs {
		b, err := os.ReadFile(j.Path)
		if err != nil {
			t.Fatal(err)
		}
		for _, line := range bytes.Split(b, []byte("\n")) {
			line = bytes.TrimRight(line, "\r")
			if len(line) > 0 && m.Match(j.Set, line) {
				n++
			}
		}
	}
	return n
}

func run(t *testing.T, q Query, jobs []Job, opt Options) *Search {
	t.Helper()
	m, err := Compile(q)
	if err != nil {
		t.Fatal(err)
	}
	s := Start(context.Background(), "t", q, m, jobs, opt)
	select {
	case <-s.Done():
	case <-time.After(30 * time.Second):
		t.Fatal("search timed out")
	}
	return s
}

func TestScanMatchesBruteForceAcrossChunkBoundaries(t *testing.T) {
	dir, _ := genData(t, 4000)
	jobs := jobsFor(dir, layout.AllSets...)
	q := Query{Last: "MARLOWE", Limit: 100000}
	m, _ := Compile(q)
	want := bruteForce(t, jobs, m)
	if want == 0 {
		t.Fatal("test data has no MARLOWE")
	}
	// A tiny odd chunk size forces many lines to straddle chunk boundaries.
	for _, chunk := range []int{4099, 65536, DefaultChunk} {
		for _, conc := range []int{1, 3} {
			s := run(t, q, jobs, Options{ChunkSize: chunk, Concurrency: conc})
			if got := s.HitCount(); got != want || s.Status() != "done" {
				t.Errorf("chunk %d conc %d: %d hits (%s), want %d", chunk, conc, got, s.Status(), want)
			}
			snap := s.Snapshot()
			if snap.Done != snap.Total || snap.Total == 0 {
				t.Errorf("progress %d/%d", snap.Done, snap.Total)
			}
		}
	}
}

func TestHitOffsetsPointAtLines(t *testing.T) {
	dir, _ := genData(t, 1500)
	jobs := jobsFor(dir, layout.SS5)
	s := run(t, Query{Last: "JUNIPER", Limit: 50}, jobs, Options{ChunkSize: 5000})
	paths := map[string]string{}
	for _, j := range jobs {
		paths[j.Name] = j.Path
	}
	for _, h := range s.Hits(0) {
		f, _ := os.Open(paths[h.File])
		buf := make([]byte, len(h.Line))
		f.ReadAt(buf, h.Offset)
		f.Close()
		if string(buf) != h.Line {
			t.Fatalf("offset %d in %s does not hold the hit line", h.Offset, h.File)
		}
	}
}

func TestSSNBinarySearch(t *testing.T) {
	dir, sum := genData(t, 5000)
	jobs := jobsFor(dir, layout.AllSets...)
	opt := Options{Sorted: NewSortCache()}
	for _, p := range sum.Samples[:10] {
		q := Query{SSN: p.SSN, Limit: 100}
		m, _ := Compile(q)
		want := bruteForce(t, jobs, m)
		s := run(t, q, jobs, opt)
		if s.HitCount() != want || want == 0 {
			t.Errorf("SSN %s: %d hits, want %d", p.SSN, s.HitCount(), want)
		}
		for _, f := range s.Snapshot().Files {
			if f.Method != "binary" {
				t.Errorf("%s used %q", f.Name, f.Method)
			}
		}
	}
	// SSNs before the first and after the last record, and one in a gap.
	for _, ssn := range []string{"000000001", "999999999", "001010000"} {
		s := run(t, Query{SSN: ssn}, jobs, opt)
		if s.HitCount() != 0 {
			t.Errorf("SSN %s: unexpected hits", ssn)
		}
	}
}

func TestSSNUnsortedFallsBackToScanThenLearns(t *testing.T) {
	defer func(h int64) { headScanBytes = h }(headScanBytes)
	headScanBytes = 2000 // so the disorder is found by sampling, not the head pass
	dir, _ := genData(t, 3000)
	jobs := jobsFor(dir, layout.SS5)
	// Reverse the lines of one file so it is no longer sorted.
	j := jobs[0]
	b, _ := os.ReadFile(j.Path)
	lines := strings.SplitAfter(string(b), "\n")
	sort.Sort(sort.Reverse(sort.StringSlice(lines)))
	os.WriteFile(j.Path, []byte(strings.Join(lines, "")), 0o644)
	target := lines[len(lines)/2][12:21]

	cache := NewSortCache()
	s := run(t, Query{SSN: target}, jobs[:1], Options{Sorted: cache})
	if s.HitCount() == 0 {
		t.Fatal("SSN in unsorted file not found")
	}
	if got := s.Snapshot().Files[0].Method; got != "scan" {
		t.Errorf("unsorted file used %q", got)
	}
	// The full pass taught the cache the exact runs: next lookup is binary.
	s = run(t, Query{SSN: target}, jobs[:1], Options{Sorted: cache})
	if got := s.Snapshot().Files[0].Method; got != "binary" || s.HitCount() == 0 {
		t.Errorf("after learning: method %q hits %d", got, s.HitCount())
	}
}

// TestRotatedHeadAndMaskedSSNs reproduces the real files' quirks: a short
// run of high SSNs at the start, and scattered masked SSNs.
func TestRotatedHeadAndMaskedSSNs(t *testing.T) {
	dir, _ := genData(t, 6000)
	jobs := jobsFor(dir, layout.CLM)
	j := jobs[0]
	b, _ := os.ReadFile(j.Path)
	lines := strings.SplitAfter(string(b), "\n")
	lines = lines[:len(lines)-1] // trailing empty element
	// Move a block from 60% to the front.
	k := len(lines) * 6 / 10
	block := append([]string(nil), lines[k:k+20]...)
	rest := append(append([]string(nil), lines[:k]...), lines[k+20:]...)
	lines = append(block, rest...)
	// Mask every 7th SSN.
	var masked []string
	for i := range lines {
		if i%7 == 3 {
			masked = append(masked, lines[i][12:21])
			lines[i] = lines[i][:12] + "ZZZZZZZZZ" + lines[i][21:]
		}
	}
	os.WriteFile(j.Path, []byte(strings.Join(lines, "")), 0o644)

	f, _ := os.Open(j.Path)
	sh, err := NewSortCache().Check(j, f)
	f.Close()
	if err != nil || !sh.Sorted || len(sh.Runs) != 2 || sh.RecSize != 500 {
		t.Fatalf("shape %+v err %v", sh, err)
	}
	cache := NewSortCache()
	for i, l := range lines {
		ssn := l[12:21]
		if ssn == "ZZZZZZZZZ" || i%3 != 0 {
			continue
		}
		s := run(t, Query{SSN: ssn}, jobs[:1], Options{Sorted: cache})
		if s.HitCount() == 0 {
			t.Fatalf("line %d SSN %s not found", i, ssn)
		}
		if m := s.Snapshot().Files[0].Method; m != "binary" {
			t.Fatalf("method %q", m)
		}
	}
	// Masked records cannot be found by their original SSN.
	s := run(t, Query{SSN: masked[0]}, jobs[:1], Options{Sorted: cache})
	for _, h := range s.Hits(0) {
		if strings.Contains(h.Line, "ZZZZZZZZZ") {
			t.Error("masked record returned for SSN lookup")
		}
	}
}

func TestLowerBound(t *testing.T) {
	data := []byte("x           000000001\r\nx           000000005\r\nx           ZZZZZZZZZ\r\nx           000000005\r\nx           000000009\r\n")
	r := bytes.NewReader(data)
	run := Run{0, int64(len(data))}
	cases := map[string]int64{"000000000": 0, "000000001": 0, "000000004": 23, "000000005": 23, "000000006": 92, "000000010": 115}
	for target, want := range cases {
		got, err := lowerBound(r, run, 0, []byte(target))
		if err != nil || got != want {
			t.Errorf("%s: got %d (%v), want %d", target, got, err, want)
		}
		got, err = lowerBound(r, run, 23, []byte(target))
		if err != nil || got != want {
			t.Errorf("fixed %s: got %d (%v), want %d", target, got, err, want)
		}
	}
}

func TestCancel(t *testing.T) {
	dir, _ := genData(t, 20000)
	jobs := jobsFor(dir, layout.AllSets...)
	// A slow opener makes the scan take long enough to cancel mid-way.
	slow := func(p string) (File, error) {
		f, err := os.Open(p)
		return &slowFile{f}, err
	}
	m, _ := Compile(Query{Last: "MARLOWE"})
	s := Start(context.Background(), "c", Query{Last: "MARLOWE"}, m, jobs, Options{Open: slow, ChunkSize: 8192})
	time.Sleep(100 * time.Millisecond)
	t0 := time.Now()
	s.Cancel()
	select {
	case <-s.Done():
	case <-time.After(2 * time.Second):
		t.Fatal("cancel did not stop the search")
	}
	if d := time.Since(t0); d > 500*time.Millisecond {
		t.Errorf("cancel took %v", d)
	}
	snap := s.Snapshot()
	if snap.Status != "cancelled" || snap.Done >= snap.Total {
		t.Errorf("status %s, %d/%d", snap.Status, snap.Done, snap.Total)
	}
}

type slowFile struct{ *os.File }

func (f *slowFile) Read(p []byte) (int, error) {
	time.Sleep(2 * time.Millisecond)
	return f.File.Read(p)
}

func TestLimitStopsSearch(t *testing.T) {
	dir, _ := genData(t, 5000)
	jobs := jobsFor(dir, layout.AllSets...)
	s := run(t, Query{DOBFrom: 1880, DOBTo: 1960, Limit: 25}, jobs, Options{})
	if s.Status() != "limit" || s.HitCount() != 25 {
		t.Errorf("status %s hits %d", s.Status(), s.HitCount())
	}
}

type failingFile struct {
	*os.File
	after int64
	read  int64
}

func (f *failingFile) Read(p []byte) (int, error) {
	if f.read >= f.after {
		return 0, errors.New("input/output error")
	}
	n, err := f.File.Read(p)
	f.read += int64(n)
	return n, err
}

func TestIOErrorReportedPerFile(t *testing.T) {
	dir, _ := genData(t, 3000)
	jobs := jobsFor(dir, layout.DTH)
	bad := jobs[3].Name
	open := func(p string) (File, error) {
		f, err := os.Open(p)
		if err != nil {
			return nil, err
		}
		if filepath.Base(p) == bad {
			return &failingFile{File: f, after: 10000}, nil
		}
		return f, nil
	}
	s := run(t, Query{Last: "MARLOWE"}, jobs, Options{Open: open, ChunkSize: 4096})
	snap := s.Snapshot()
	if snap.Status != "partial" || snap.FilesFailed != 1 || snap.Unread <= 0 || len(snap.Errors) != 1 || snap.Errors[0].Name != bad ||
		!strings.Contains(snap.Errors[0].Error, "input/output error") {
		t.Fatalf("status %s errors %+v", snap.Status, snap.Errors)
	}
	// Every file failing makes the whole search an error.
	allBad := func(p string) (File, error) { return nil, &os.PathError{Op: "open", Path: p, Err: io.ErrUnexpectedEOF} }
	s = run(t, Query{Last: "MARLOWE"}, jobs, Options{Open: allBad})
	if s.Status() != "error" {
		t.Errorf("status %s", s.Status())
	}
}

func TestSetFiltersSkipInapplicableSets(t *testing.T) {
	dir, _ := genData(t, 2000)
	jobs := jobsFor(dir, layout.AllSets...)
	s := run(t, Query{Last: "MARLOWE", DeathFrom: 1900, DeathTo: 2010, Limit: 10000}, jobs, Options{})
	for _, f := range s.Snapshot().Files {
		if strings.HasPrefix(f.Name, "NUMSS5") && f.State != "skipped" {
			t.Fatalf("%s state %s", f.Name, f.State)
		}
	}
	for _, h := range s.Hits(0) {
		if h.Set == layout.SS5 {
			t.Fatal("SS5 hit for a death-year query")
		}
	}
}

func TestMatcherModes(t *testing.T) {
	line := []byte("65008000144 001010501    10 193611XXJOHN            MARSHALL        HOYT                        1110188511MINNIE                          PERKINS                  J               F               HOYT                     LOCONIA      NH")
	cases := []struct {
		q    Query
		want bool
	}{
		{Query{Last: "hoyt"}, true},
		{Query{Last: "HOY"}, false},
		{Query{Last: "HOY", NameMode: ModePrefix}, true},
		{Query{Last: "HOIT", NameMode: ModeSoundex}, true},
		{Query{First: "JOHN", Last: "HOYT", Middle: "MARSHALL"}, true},
		{Query{SSN: "001-01-0501"}, true},
		{Query{SSN: "001010502"}, false},
		{Query{Last: "HOYT", DOBFrom: 1885, DOBTo: 1885}, true},
		{Query{Last: "HOYT", DOBFrom: 1886}, false},
		{Query{Last: "HOYT", Sex: "2"}, false},
		{Query{MotherLast: "PERKINS"}, true},
		{Query{FatherFirst: "J", FatherLast: "HOYT"}, true},
		{Query{POBState: "NH", POBCity: "LOCO"}, true},
		{Query{POBState: "MA"}, false},
		{Query{Last: "HOYT", DeathFrom: 1900}, false}, // SS-5 has no death date
	}
	for i, c := range cases {
		m, err := Compile(c.q)
		if err != nil {
			t.Fatalf("%d: %v", i, err)
		}
		if got := m.Match(layout.SS5, line); got != c.want {
			t.Errorf("case %d %+v: got %v", i, c.q, got)
		}
	}
	if _, err := Compile(Query{}); err == nil {
		t.Error("empty query should fail")
	}
	if _, err := Compile(Query{SSN: "12345"}); err == nil {
		t.Error("short SSN should fail")
	}
}

func TestMatcherDoesNotAllocate(t *testing.T) {
	line := []byte("65008000144 001010501    10 193611XXJOHN            MARSHALL        HOYT                        1110188511MINNIE")
	m, _ := Compile(Query{Last: "HOIT", First: "JON", NameMode: ModeSoundex, DOBFrom: 1800})
	if a := testing.AllocsPerRun(100, func() { m.Match(layout.SS5, line) }); a != 0 {
		t.Errorf("Match allocates %v times", a)
	}
}

func TestFixedAndIrregularShapes(t *testing.T) {
	dir, sum := genData(t, 3000)
	jobs := jobsFor(dir, layout.DTH)
	cache := NewSortCache()
	f, _ := os.Open(jobs[0].Path)
	shape, err := cache.Check(jobs[0], f)
	f.Close()
	if err != nil || !shape.Sorted || shape.RecSize != 489 {
		t.Fatalf("shape %+v err %v", shape, err)
	}
	// Break fixed length in every file: drop 3 blanks from the first line.
	for i, j := range jobs {
		b, _ := os.ReadFile(j.Path)
		i0 := bytes.IndexByte(b, '\n')
		b = append(b[:i0-4:i0-4], b[i0-1:]...)
		os.WriteFile(j.Path, b, 0o644)
		st, _ := os.Stat(j.Path)
		jobs[i].Size, jobs[i].ModTime = st.Size(), st.ModTime()
	}
	f, _ = os.Open(jobs[0].Path)
	shape, _ = NewSortCache().Check(jobs[0], f)
	f.Close()
	if !shape.Sorted || shape.RecSize != 0 {
		t.Fatalf("irregular shape %+v", shape)
	}
	for _, p := range sum.Samples[:10] {
		if !p.HasDeath {
			continue
		}
		q := Query{SSN: p.SSN}
		m, _ := Compile(q)
		want := bruteForce(t, jobs, m)
		if s := run(t, q, jobs, Options{}); s.HitCount() != want {
			t.Errorf("irregular %s: %d hits, want %d", p.SSN, s.HitCount(), want)
		}
	}
}

// TestRealDataSSNLookups does a few binary-search lookups on the real release
// when it is mounted. It never falls back to a full scan: each file's shape is
// probed first (8 MB head + 256 samples) and the test stops if one is unsorted.
func TestRealDataSSNLookups(t *testing.T) {
	const dir = "/Volumes/TranscBlura/NUMIDENT"
	if _, err := os.Stat(dir); err != nil {
		t.Skip("real data not mounted")
	}
	r := catalog.Scan(dir)
	cases := []struct {
		set   layout.Set
		files []int
		ssn   string
		name  string
	}{
		{layout.CLM, []int{1, 13, 15}, "001010002", "JOHN ALEXANDER HAZLETT"},
		{layout.CLM, []int{15}, "101163574", "KATHERINE"}, // first record of a rotated head
		{layout.DTH, []int{1, 4}, "001010104", "ELSIE E BAKER"},
		{layout.DTH, []int{4}, "181166318", "GEORGE"},
		{layout.SS5, []int{1, 5}, "001010501", "JOHN MARSHALL HOYT"},
	}
	cache := NewSortCache()
	for _, c := range cases {
		var jobs []Job
		for _, n := range c.files {
			f := r.Set(c.set).Files[n-1]
			j := Job{Set: c.set, Name: f.Name, Path: f.Path, Size: f.Size, ModTime: f.ModTime}
			fh, err := os.Open(f.Path)
			if err != nil {
				t.Fatal(err)
			}
			sh, err := cache.Check(j, fh)
			fh.Close()
			if err != nil || !sh.Sorted {
				t.Fatalf("%s not usable for binary search: %+v %v", f.Name, sh, err)
			}
			t.Logf("%s: %d run(s), record size %d", f.Name, len(sh.Runs), sh.RecSize)
			jobs = append(jobs, j)
		}
		s := run(t, Query{SSN: c.ssn}, jobs, Options{Concurrency: 4, Sorted: cache})
		hits := s.Hits(0)
		if len(hits) == 0 {
			t.Errorf("%s %s not found", c.set, c.ssn)
			continue
		}
		if got := layout.Parse(c.set, []byte(hits[0].Line)).Name.Full(); !strings.HasPrefix(got, c.name) {
			t.Errorf("%s %s: name %q", c.set, c.ssn, got)
		}
		t.Logf("%s %s: %d hit(s) in %.1f ms", c.set, c.ssn, len(hits), s.Snapshot().Elapsed*1000)
	}
}

// TestDriveVanishesMidScan simulates the data drive unmounting: after three
// files have been opened the data folder disappears. The search must stop
// launching files, mark the rest as not searched and finish as "partial".
func TestDriveVanishesMidScan(t *testing.T) {
	dir, _ := genData(t, 3000)
	jobs := jobsFor(dir, layout.SS5)
	var mu sync.Mutex
	opens := 0
	open := func(p string) (File, error) {
		mu.Lock()
		opens++
		if opens == 4 {
			if err := os.Rename(dir, dir+"-unmounted"); err != nil {
				t.Error(err)
			}
		}
		mu.Unlock()
		return os.Open(p)
	}
	s := run(t, Query{Last: "MARLOWE"}, jobs, Options{Open: open, Concurrency: 1, Root: dir})
	snap := s.Snapshot()
	if snap.Status != "partial" || !snap.DriveLost {
		t.Fatalf("status %s driveLost %v", snap.Status, snap.DriveLost)
	}
	if opens != 4 {
		t.Errorf("%d files opened; expected the search to stop launching after the failure", opens)
	}
	if snap.FilesFailed != len(jobs)-3 || snap.Unread == 0 {
		t.Errorf("failed %d of %d, unread %d", snap.FilesFailed, len(jobs), snap.Unread)
	}
	for _, f := range snap.Files[4:] {
		if f.State != "failed" || !strings.Contains(f.Error, "not searched") {
			t.Errorf("%s: %s %q", f.Name, f.State, f.Error)
		}
	}
	if snap.Sets[0].FilesDone != 3 || snap.Sets[0].Failed != len(jobs)-3 {
		t.Errorf("set progress %+v", snap.Sets[0])
	}
}

// TestBadFileIsNotDriveLoss: one unreadable file with the folder still
// present is a per-file error; the other files are still searched.
func TestBadFileIsNotDriveLoss(t *testing.T) {
	dir, _ := genData(t, 3000)
	jobs := jobsFor(dir, layout.SS5)
	os.Remove(jobs[2].Path)
	s := run(t, Query{Last: "MARLOWE"}, jobs, Options{Concurrency: 1, Root: dir})
	snap := s.Snapshot()
	if snap.Status != "partial" || snap.DriveLost || snap.FilesFailed != 1 || snap.Sets[0].FilesDone != len(jobs)-1 {
		t.Fatalf("status %s driveLost %v failed %d", snap.Status, snap.DriveLost, snap.FilesFailed)
	}
}
