// Package synth generates fake NUMIDENT files in the exact public-use layout
// (fixed-length lines, LF for NUMSS5/NUMCLM and CRLF for NUMDEATH, each file
// sorted by SSN and spanning the whole SSN range). All names are invented.
package synth

import (
	"bufio"
	"fmt"
	"math/rand"
	"os"
	"path/filepath"
	"sort"

	"numident/internal/layout"
)

// Options controls generation.
type Options struct {
	Dir          string
	People       int
	FilesPerSet  int // default 20
	Seed         int64
	Missing      map[layout.Set][]int // 1-based file numbers not to create
	Truncate     []string             // file names to cut mid-line afterwards
	LowerCaseExt bool                 // NUMDEATH uses .TXT in the real release; others .txt
}

// Summary describes what was written.
type Summary struct {
	Files   []string
	Lines   map[layout.Set]int
	Bytes   int64
	People  int
	Samples []Person // a few people, for tests and demos
}

// Person is the ground truth for one generated SSN.
type Person struct {
	SSN       string
	First     string
	Last      string
	BirthYear int
	HasDeath  bool
	HasClaim  bool
}

var (
	firstM  = []string{"ALDEN", "BERNARD", "CALVIN", "DORIAN", "EMMETT", "FLETCHER", "GIDEON", "HOLLIS", "IRVING", "JASPER", "KEARNEY", "LUCIAN", "MERRITT", "NORRIS", "ORVILLE", "PERCIVAL", "QUINCY", "ROSCOE", "SILAS", "THADDEUS"}
	firstF  = []string{"ADELINE", "BEATRIX", "CORDELIA", "DELPHINE", "EULALIA", "FLORINE", "GWENDOLYN", "HONORA", "IMOGENE", "JOSEPHINE", "LAVINIA", "MAREN", "NOVELLA", "OPHELIA", "PHILOMENA", "ROSALIND", "SYBIL", "THEODORA", "VERBENA", "WINIFRED"}
	lasts   = []string{"ABERNATHY", "BRAMBLEWOOD", "CRANSTON", "DELACROIX", "ELDERBERRY", "FAIRWEATHER", "GOODALE", "HARTWELL", "IVERSEN", "JUNIPER", "KETTERING", "LANGSTAFF", "MARLOWE", "NETTLETON", "OAKHURST", "PEMBERTON", "QUILLFEATHER", "ROWANBERRY", "STILLWATER", "THORNBURY", "UPSHAW", "VANDERMEER", "WHITLOCK", "YARBOROUGH", "ZIMMERLY", "ROBERTS", "RUPERTS"}
	places  = [][2]string{{"MAPLETON", "MA"}, {"BIRCHFIELD", "NH"}, {"CEDAR FALLS", "IA"}, {"DOVER PLAINS", "NY"}, {"ELMHURST", "IL"}, {"FOXBORO", "MA"}, {"GLENWOOD", "MN"}, {"HAZELDALE", "PA"}, {"IRONWOOD", "MI"}, {"JUNCTION CTY", "KS"}, {"SPRINGFIELD", "OH"}, {"", "UN"}}
	sources = []string{"  ", "HC", "BX", "FO", "SI", "VA", "PE"}
)

type builder struct{ b [500]byte }

func (w *builder) reset() {
	for i := range w.b {
		w.b[i] = ' '
	}
}

func (w *builder) put(f layout.Field, v string) {
	w.putAt(f.Start, f.End, v)
}

func (w *builder) putAt(start, end int, v string) {
	n := end - start + 1
	if len(v) > n {
		v = v[:n]
	}
	copy(w.b[start-1:], v)
}

func (w *builder) name(off int, n layout.Name) {
	f, m, l, s := layout.NameFields(off)
	w.putAt(f.Start, f.End-1, n.First) // last column is the overflow flag
	w.putAt(m.Start, m.End-1, n.Middle)
	w.putAt(l.Start, l.End-1, n.Last)
	w.put(s, n.Suffix)
}

// line returns the record padded to the set's fixed length plus its
// terminator, as in the real release.
func (w *builder) line(s layout.Set) []byte {
	out := append([]byte(nil), w.b[:s.LineLen()]...)
	return append(out, s.Terminator()...)
}

func mdy(y, m, d int) string {
	ds := fmt.Sprintf("%02d", d)
	if d == 0 {
		ds = "XX"
	}
	ms := fmt.Sprintf("%02d", m)
	if m == 0 {
		ms = "XX"
	}
	return ms + ds + fmt.Sprintf("%04d", y)
}

func ymd(y, m, d int) string {
	ds := fmt.Sprintf("%02d", d)
	if d == 0 {
		ds = "XX"
	}
	return fmt.Sprintf("%04d%02d", y, m) + ds
}

// FileName returns the release file name for set s, number n (1-based).
func FileName(s layout.Set, n int) string {
	ext := ".txt"
	if s == layout.DTH {
		ext = ".TXT"
	}
	return fmt.Sprintf("%s%02d_PU%s", s, n, ext)
}

// Generate writes a synthetic release under o.Dir/<SET>/.
func Generate(o Options) (Summary, error) {
	if o.FilesPerSet == 0 {
		o.FilesPerSet = 20
	}
	rng := rand.New(rand.NewSource(o.Seed))
	sum := Summary{Lines: map[layout.Set]int{}, People: o.People}

	type out struct {
		f *os.File
		w *bufio.Writer
	}
	writers := map[layout.Set][]*out{}
	for _, s := range layout.AllSets {
		dir := filepath.Join(o.Dir, s.String())
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return sum, err
		}
		missing := map[int]bool{}
		for _, n := range o.Missing[s] {
			missing[n] = true
		}
		ws := make([]*out, o.FilesPerSet)
		for i := range ws {
			if missing[i+1] {
				continue
			}
			p := filepath.Join(dir, FileName(s, i+1))
			f, err := os.Create(p)
			if err != nil {
				return sum, err
			}
			ws[i] = &out{f, bufio.NewWriterSize(f, 1<<20)}
			sum.Files = append(sum.Files, p)
		}
		writers[s] = ws
	}
	emit := func(s layout.Set, line []byte) {
		w := writers[s][rng.Intn(o.FilesPerSet)]
		if w == nil {
			return // that file is "missing"
		}
		w.w.Write(line)
		sum.Lines[s]++
		sum.Bytes += int64(len(line))
	}

	// Increasing SSNs spread over the full range so every file spans it.
	ssns := make([]int, o.People)
	for i := range ssns {
		ssns[i] = 1010000 + rng.Intn(771000000)
	}
	sort.Ints(ssns)

	var w builder
	prev := -1
	for _, ssnN := range ssns {
		if ssnN == prev {
			continue
		}
		prev = ssnN
		ssn := fmt.Sprintf("%09d", ssnN)
		female := rng.Intn(2) == 0
		first := firstM[rng.Intn(len(firstM))]
		sex := "1"
		if female {
			first = firstF[rng.Intn(len(firstF))]
			sex = "2"
		}
		middle := ""
		if rng.Intn(3) > 0 {
			middle = string(rune('A' + rng.Intn(26)))
		}
		last := lasts[rng.Intn(len(lasts))]
		by, bm, bd := 1880+rng.Intn(80), 1+rng.Intn(12), 1+rng.Intn(28)
		pl := places[rng.Intn(len(places))]
		mother := layout.Name{First: firstF[rng.Intn(len(firstF))], Last: lasts[rng.Intn(len(lasts))]}
		father := layout.Name{First: firstM[rng.Intn(len(firstM))], Middle: string(rune('A' + rng.Intn(26))), Last: last}
		person := Person{SSN: ssn, First: first, Last: last, BirthYear: by}

		// SS-5 applications: 1–3, later ones sometimes change name or DOB.
		nApps := 1 + rng.Intn(3)
		for a := 0; a < nApps; a++ {
			w.reset()
			cy := by + 16 + a*7
			if cy > 2007 {
				cy = 2007
			}
			name := layout.Name{First: first, Middle: middle, Last: last}
			dobY, dobD := by, bd
			entry := "0"
			if a > 0 {
				entry = "2"
				if female && rng.Intn(2) == 0 {
					name.Last = lasts[rng.Intn(len(lasts))] // married name
				}
				if rng.Intn(6) == 0 {
					dobY++ // conflicting DOB
				}
			}
			if rng.Intn(10) == 0 {
				dobD = 0 // unknown day
			}
			w.put(layout.FRefNum, fmt.Sprintf("%011d", rng.Int63n(99999999999)))
			w.put(layout.FSSN, ssn)
			w.put(layout.FFormCode, "1")
			w.put(layout.FEntryCode, entry)
			if cy < 1940 {
				w.put(layout.FCycleDate, ymd(cy, 1+rng.Intn(12), 0))
			} else {
				w.put(layout.FCycleDate, ymd(cy, 1+rng.Intn(12), 1+rng.Intn(28)))
			}
			w.name(layout.NameOffPrimary, name)
			w.put(layout.FDOB, mdy(dobY, bm, dobD))
			w.put(layout.FSex, sex)
			w.put(layout.FRace, fmt.Sprint(rng.Intn(7)))
			w.put(layout.FMotherFirst, mother.First)
			w.put(layout.FMotherLast, mother.Last)
			w.put(layout.FFatherFirst, father.First)
			w.put(layout.FFatherMiddle, father.Middle)
			w.put(layout.FFatherLast, father.Last)
			w.put(layout.FPOBCity, pl[0])
			w.put(layout.FPOBState, pl[1])
			if name.Last != last {
				w.name(layout.NameOffOther, layout.Name{First: first, Last: last})
			}
			w.put(layout.FSigCode, "S")
			w.put(layout.FConversion, "A")
			emit(layout.SS5, w.line(layout.SS5))
		}

		dies := rng.Intn(10) < 7
		dy := by + 50 + rng.Intn(45)
		if dy > 2007 {
			dy = 2007
		}
		dm := 1 + rng.Intn(12)

		// Claim (life or death).
		if rng.Intn(10) < 4 {
			person.HasClaim = true
			w.reset()
			w.put(layout.FRefNum, fmt.Sprintf("%011d", rng.Int63n(99999999999)))
			w.put(layout.FSSN, ssn)
			w.put(layout.FFormCode, "5")
			cy := by + 65
			if cy > 2007 {
				cy = 2007
			}
			if dies && rng.Intn(2) == 0 {
				w.put(layout.FEntryCode, "D")
				w.put(layout.FDODClaim, mdy(dy, dm, 1+rng.Intn(28)))
				cy = dy
			} else {
				w.put(layout.FEntryCode, "L")
			}
			w.put(layout.FCycleDate, ymd(cy, 1+rng.Intn(12), 1+rng.Intn(28)))
			w.name(layout.NameOffPrimary, layout.Name{First: first, Middle: middle, Last: last})
			w.put(layout.FDOB, mdy(by, bm, bd))
			w.put(layout.FSex, "0")
			w.put(layout.FPOBCity, pl[0])
			w.put(layout.FPOBState, pl[1])
			w.put(layout.FFOAddress, "SPRINGFIELD "+pl[1])
			w.put(layout.FClaimDate, mdy(cy, 1+rng.Intn(12), 1+rng.Intn(28)))
			w.put(layout.FConversion, "A")
			emit(layout.CLM, w.line(layout.CLM))
		}

		// Death record with 1–3 postings.
		if dies {
			person.HasDeath = true
			w.reset()
			w.put(layout.FSSN, ssn)
			w.put(layout.FEntryCode, "T")
			w.put(layout.FCycleDate, ymd(dy, dm, 1+rng.Intn(28)))
			n := 1
			if rng.Intn(5) == 0 {
				n = 2 + rng.Intn(2)
			}
			for k := 0; k < n; k++ {
				off := k * layout.DeathPostingSpan
				at := func(f layout.Field) layout.Field { return f.Shift(off, "", "") }
				w.name(off, layout.Name{First: first, Middle: middle, Last: last})
				w.put(at(layout.FDOB), mdy(by, bm, bd))
				w.put(at(layout.FSex), "0")
				w.put(at(layout.FDthOtherNum), ssn)
				w.put(at(layout.FDthZipRes), fmt.Sprintf("%05d0000", rng.Intn(99999)))
				w.put(at(layout.FDthSource), sources[rng.Intn(len(sources))])
				w.put(at(layout.FDthEDR), "N")
				dd := 1 + rng.Intn(28)
				if rng.Intn(5) == 0 {
					dd = 0
				}
				w.put(at(layout.FDthDOD), mdy(dy, dm, dd))
				w.put(at(layout.FDthPosted), ymd(dy, dm, 1+rng.Intn(28)))
			}
			w.put(layout.FDthNOE, fmt.Sprint(n))
			emit(layout.DTH, w.line(layout.DTH))
		}
		if len(sum.Samples) < 50 && rng.Intn(4) == 0 {
			sum.Samples = append(sum.Samples, person)
		}
	}

	for _, ws := range writers {
		for _, w := range ws {
			if w == nil {
				continue
			}
			if err := w.w.Flush(); err != nil {
				return sum, err
			}
			if err := w.f.Close(); err != nil {
				return sum, err
			}
		}
	}
	for _, name := range o.Truncate {
		for _, p := range sum.Files {
			if filepath.Base(p) == name {
				st, err := os.Stat(p)
				if err != nil {
					return sum, err
				}
				if err := os.Truncate(p, st.Size()-137); err != nil {
					return sum, err
				}
			}
		}
	}
	return sum, nil
}
