package scan

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sync"
)

// The real release is *mostly* sorted by SSN, with two quirks found on the
// actual files:
//
//   - many files begin with a short sorted run of higher SSNs (a few hundred
//     to ~10,000 records) before the main sorted body starts again near 001…;
//   - some records carry a masked SSN "ZZZZZZZZZ" scattered through the file.
//
// So a file is modelled as a few sorted runs, and records whose SSN is not
// nine digits are ignored for ordering (they cannot be found by SSN anyway).
// An SSN lookup binary-searches every run.

// Run is a byte range [Start, End) of a file whose digit SSNs never decrease.
type Run struct {
	Start int64 `json:"start"`
	End   int64 `json:"end"`
}

// FileShape is what is known about a file's ordering.
type FileShape struct {
	Sorted   bool   `json:"sorted"`            // binary search per run is safe
	RecSize  int64  `json:"recSize,omitempty"` // > 0 when all records are this many bytes
	Runs     []Run  `json:"runs,omitempty"`
	Verified bool   `json:"verified,omitempty"` // learned from a complete pass, not sampled
	Reason   string `json:"reason,omitempty"`   // why it is not sorted
}

// Tunables (variables so tests can shrink them).
var (
	headScanBytes int64 = 8 << 20 // read the start of each file in full (real head runs reach ~4.7 MB)
	sortSamples         = 256     // then sample this many points in the rest
	maxRuns             = 1024    // more runs than this: just scan the file
)

// SortCache remembers each file's shape, optionally persisted to disk.
type SortCache struct {
	mu   sync.Mutex
	m    map[string]FileShape
	path string
}

// NewSortCache returns an in-memory cache.
func NewSortCache() *SortCache { return &SortCache{m: map[string]FileShape{}} }

// LoadSortCache returns a cache persisted at path (created on first save).
func LoadSortCache(path string) *SortCache {
	c := &SortCache{m: map[string]FileShape{}, path: path}
	if b, err := os.ReadFile(path); err == nil {
		json.Unmarshal(b, &c.m)
	}
	return c
}

func shapeKey(j Job) string {
	return fmt.Sprintf("%s|%d|%d", j.Path, j.Size, j.ModTime.Unix())
}

func (c *SortCache) get(j Job) (FileShape, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	v, ok := c.m[shapeKey(j)]
	return v, ok
}

func (c *SortCache) put(j Job, sh FileShape) {
	c.mu.Lock()
	c.m[shapeKey(j)] = sh
	var b []byte
	if c.path != "" {
		b, _ = json.Marshal(c.m)
	}
	c.mu.Unlock()
	if b != nil {
		os.MkdirAll(filepath.Dir(c.path), 0o755)
		tmp := c.path + ".tmp"
		if os.WriteFile(tmp, b, 0o644) == nil {
			os.Rename(tmp, c.path)
		}
	}
}

// Learn records an exact shape found by a complete pass over the file.
func (c *SortCache) Learn(j Job, sh FileShape) { c.put(j, sh) }

func digitSSN(line []byte) ([9]byte, bool) {
	var out [9]byte
	if len(line) < 21 {
		return out, false
	}
	for i, ch := range line[12:21] {
		if ch < '0' || ch > '9' {
			return out, false
		}
		out[i] = ch
	}
	return out, true
}

// runTracker finds run boundaries while lines are read in order.
type runTracker struct {
	want      int // expected line length without terminator
	irregular bool
	prev      [9]byte
	have      bool
	bounds    []int64
}

func (t *runTracker) see(off int64, line []byte) {
	if len(line) != t.want {
		t.irregular = true
	}
	ssn, ok := digitSSN(line)
	if !ok {
		return
	}
	if t.have && bytes.Compare(ssn[:], t.prev[:]) < 0 {
		t.bounds = append(t.bounds, off)
	}
	t.prev, t.have = ssn, true
}

func runsFrom(bounds []int64, size int64) []Run {
	var runs []Run
	start := int64(0)
	for _, b := range bounds {
		runs = append(runs, Run{start, b})
		start = b
	}
	return append(runs, Run{start, size})
}

func (t *runTracker) shape(j Job) FileShape {
	sh := FileShape{Sorted: len(t.bounds) < maxRuns, Verified: true}
	if !t.irregular && j.Size%j.Set.RecordSize() == 0 {
		sh.RecSize = j.Set.RecordSize()
	}
	if sh.Sorted {
		sh.Runs = runsFrom(t.bounds, j.Size)
	} else {
		sh.Reason = fmt.Sprintf("%d out-of-order places", len(t.bounds))
	}
	return sh
}

// Check returns the file's shape: from the cache if known, otherwise by
// reading the first headScanBytes in full and sampling the rest.
func (c *SortCache) Check(j Job, f io.ReaderAt) (FileShape, error) {
	if sh, ok := c.get(j); ok {
		return sh, nil
	}
	sh, err := probeShape(j, f)
	if err != nil {
		return sh, err
	}
	c.put(j, sh)
	return sh, nil
}

func probeShape(j Job, f io.ReaderAt) (FileShape, error) {
	t := runTracker{want: j.Set.LineLen()}
	// 1. Head: every line of the first headScanBytes.
	headLen := j.Size
	if headLen > headScanBytes {
		headLen = headScanBytes
	}
	r := bufio.NewReaderSize(io.NewSectionReader(f, 0, headLen), 64<<10)
	var off, headEnd int64
	for {
		line, err := r.ReadSlice('\n')
		if err == nil {
			n := int64(len(line))
			t.see(off, bytes.TrimRight(line, "\r\n"))
			off += n
			headEnd = off
			continue
		}
		if err == io.EOF || err == bufio.ErrBufferFull {
			break
		}
		return FileShape{}, err
	}
	fixed := !t.irregular && j.Size%j.Set.RecordSize() == 0
	rs := j.Set.RecordSize()

	// 2. Samples across the rest of the file.
	if headEnd < j.Size {
		prevSet := t.have
		prev := t.prev
		for i := 1; i <= sortSamples; i++ {
			pos := headEnd + (j.Size-headEnd)*int64(i)/int64(sortSamples+1)
			var start int64
			if fixed {
				start = (pos + rs - 1) / rs * rs
				var nl [1]byte
				if _, err := f.ReadAt(nl[:], start-1); err != nil {
					return FileShape{}, err
				}
				if nl[0] != '\n' {
					fixed = false // not fixed after all; resync instead
				}
			}
			if !fixed {
				var err error
				if start, err = lineStart(f, j.Size, pos); err != nil {
					return FileShape{}, err
				}
			}
			ssn, ok, err := nextDigitSSN(f, start, j.Size, recOrZero(fixed, rs))
			if err != nil {
				return FileShape{}, err
			}
			if !ok {
				continue
			}
			if prevSet && bytes.Compare(ssn[:], prev[:]) < 0 {
				return FileShape{Reason: fmt.Sprintf("SSNs out of order near byte %d", start)}, nil
			}
			prev, prevSet = ssn, true
		}
	}
	if len(t.bounds) >= maxRuns {
		return FileShape{Reason: "too many out-of-order places at the start of the file"}, nil
	}
	sh := FileShape{Sorted: true, Runs: runsFrom(t.bounds, j.Size)}
	if fixed {
		sh.RecSize = rs
	}
	return sh, nil
}

func recOrZero(fixed bool, rs int64) int64 {
	if fixed {
		return rs
	}
	return 0
}

// lineStart returns the offset of the first line starting at or after off.
func lineStart(f io.ReaderAt, size, off int64) (int64, error) {
	if off <= 0 {
		return 0, nil
	}
	var buf [1024]byte
	pos := off - 1
	for pos < size {
		n, err := f.ReadAt(buf[:], pos)
		if i := bytes.IndexByte(buf[:n], '\n'); i >= 0 {
			return pos + int64(i) + 1, nil
		}
		if err == io.EOF || n == 0 {
			return size, nil
		}
		if err != nil {
			return 0, err
		}
		pos += int64(n)
	}
	return size, nil
}

// nextDigitSSN returns the first nine-digit SSN of a record starting at or
// after start (a record boundary) and before end, skipping masked SSNs.
func nextDigitSSN(f io.ReaderAt, start, end, recSize int64) ([9]byte, bool, error) {
	buf := make([]byte, 32<<10)
	for start < end {
		n, err := f.ReadAt(buf[:min64(int64(len(buf)), end-start)], start)
		if n == 0 {
			if err != nil && err != io.EOF {
				return [9]byte{}, false, err
			}
			break
		}
		data := buf[:n]
		consumed := 0
		for consumed < len(data) {
			var line []byte
			if recSize > 0 {
				if consumed+int(recSize) > len(data) && start+int64(len(data)) < end {
					break
				}
				e := consumed + int(recSize)
				if e > len(data) {
					e = len(data)
				}
				line = data[consumed:e]
				consumed = e
			} else {
				i := bytes.IndexByte(data[consumed:], '\n')
				if i < 0 {
					if start+int64(len(data)) < end {
						break
					}
					i = len(data) - consumed - 1
				}
				line = data[consumed : consumed+i+1]
				consumed += i + 1
			}
			if ssn, ok := digitSSN(line); ok {
				return ssn, true, nil
			}
		}
		if consumed == 0 {
			return [9]byte{}, false, fmt.Errorf("record longer than %d bytes at byte %d", len(buf), start)
		}
		start += int64(consumed)
	}
	return [9]byte{}, false, nil
}

func min64(a, b int64) int64 {
	if a < b {
		return a
	}
	return b
}

// lowerBound returns the start of the first record in run whose next digit
// SSN is >= target. Records are indexed directly when recSize > 0; otherwise
// probes seek to a byte offset and resync to the next line.
func lowerBound(f io.ReaderAt, run Run, recSize int64, target []byte) (int64, error) {
	probe := func(pos int64) (bool, error) {
		ssn, ok, err := nextDigitSSN(f, pos, run.End, recSize)
		if err != nil || !ok {
			return true, err // nothing digit-keyed after pos: treat as >=
		}
		return bytes.Compare(ssn[:], target) >= 0, nil
	}
	if recSize > 0 {
		lo, hi := run.Start/recSize, run.End/recSize
		for lo < hi {
			mid := lo + (hi-lo)/2
			ge, err := probe(mid * recSize)
			if err != nil {
				return 0, err
			}
			if ge {
				hi = mid
			} else {
				lo = mid + 1
			}
		}
		return lo * recSize, nil
	}
	lo, hi := run.Start, run.End
	for lo < hi {
		mid := lo + (hi-lo)/2
		st, err := lineStart(f, run.End, mid)
		if err != nil {
			return 0, err
		}
		if st < run.Start {
			st = run.Start
		}
		ge, err := probe(st)
		if err != nil {
			return 0, err
		}
		if ge {
			hi = mid
		} else {
			lo = mid + 1
		}
	}
	st, err := lineStart(f, run.End, lo)
	if st < run.Start {
		st = run.Start
	}
	return st, err
}

// lookupSSN binary-searches every run for target and reads forward through
// the matching records.
func (s *Search) lookupSSN(fs *FileState, f File, target []byte, sh FileShape) error {
	runs := sh.Runs
	if len(runs) == 0 {
		runs = []Run{{0, fs.Size}}
	}
	for _, run := range runs {
		if err := context.Cause(s.ctx); err != nil {
			return err
		}
		start, err := lowerBound(f, run, sh.RecSize, target)
		if err != nil {
			return err
		}
		r := bufio.NewReaderSize(io.NewSectionReader(f, start, run.End-start), 64<<10)
		off := start
		for {
			line, rerr := r.ReadSlice('\n')
			if len(line) > 0 {
				body := bytes.TrimRight(line, "\r\n")
				if ssn, ok := digitSSN(body); ok {
					c := bytes.Compare(ssn[:], target)
					if c > 0 {
						break
					}
					if c == 0 && s.m.Match(fs.Set, body) && !s.addHit(fs.Set, fs.Name, off, body) {
						return context.Cause(s.ctx)
					}
				}
				off += int64(len(line))
			}
			if rerr == io.EOF {
				break
			}
			if rerr != nil {
				return rerr
			}
		}
	}
	return nil
}
