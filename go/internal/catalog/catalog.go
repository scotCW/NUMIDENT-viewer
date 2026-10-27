// Package catalog discovers the NUMIDENT files in a data folder and reports
// on the health of the dataset: which files are present, missing, empty,
// suspiciously small, truncated or unreadable.
package catalog

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"numident/internal/layout"
)

// ExpectedFiles is the number of files NARA delivered per set.
const ExpectedFiles = 20

// Status of one expected file.
const (
	StatusOK         = "ok"
	StatusMissing    = "missing"
	StatusEmpty      = "empty"
	StatusSmall      = "small"     // far smaller than its siblings
	StatusTruncated  = "truncated" // last line has no line ending
	StatusBadFormat  = "badformat" // first line does not look like a record
	StatusIrregular  = "irregular" // size is not a whole number of records
	StatusUnreadable = "unreadable"
)

// File describes one expected (or extra) file.
type File struct {
	Set     string    `json:"set"`
	Number  int       `json:"number"`
	Name    string    `json:"name"`
	Path    string    `json:"path,omitempty"`
	Size    int64     `json:"size"`
	ModTime time.Time `json:"modTime,omitempty"`
	Status  string    `json:"status"`
	Problem string    `json:"problem,omitempty"`
}

// Searchable reports whether the file can be read at all. Small, truncated
// and badly formatted files are still searched; the banner warns about them.
func (f File) Searchable() bool {
	switch f.Status {
	case StatusMissing, StatusEmpty, StatusUnreadable:
		return false
	}
	return true
}

// SetReport summarises one set.
type SetReport struct {
	Set        string `json:"set"`
	Label      string `json:"label"`
	Expected   int    `json:"expected"`
	Present    int    `json:"present"`
	Searchable int    `json:"searchable"`
	Missing    []int  `json:"missing"`
	MissingStr string `json:"missingStr"`
	Problems   int    `json:"problems"`
	Bytes      int64  `json:"bytes"`
	Files      []File `json:"files"`
	Summary    string `json:"summary"`
}

// Report is the dataset health report.
type Report struct {
	Dir      string      `json:"dir"`
	DirOK    bool        `json:"dirOk"`
	DirError string      `json:"dirError,omitempty"`
	Sets     []SetReport `json:"sets"`
	Extra    []string    `json:"extra,omitempty"`
	Complete bool        `json:"complete"`
	Warnings []string    `json:"warnings"`
	Scanned  time.Time   `json:"scanned"`
}

// Set returns the report for one set.
func (r *Report) Set(s layout.Set) *SetReport {
	for i := range r.Sets {
		if r.Sets[i].Set == s.String() {
			return &r.Sets[i]
		}
	}
	return nil
}

var fileRE = regexp.MustCompile(`(?i)^(NUMSS5|NUMCLM|NUMDEATH)(\d{2})_PU\.txt$`)

// Scan inspects dir. Files may be in per-set subfolders (as released) or
// directly in dir. It only stats files and reads a few bytes from each.
func Scan(dir string) Report {
	r := Report{Dir: dir, Scanned: time.Now()}
	found := map[string]File{} // key SET/NN
	st, err := os.Stat(dir)
	switch {
	case err != nil:
		r.DirError = fmt.Sprintf("Data folder not found: %s. Is the drive connected?", dir)
	case !st.IsDir():
		r.DirError = fmt.Sprintf("%s is not a folder", dir)
	default:
		r.DirOK = true
		dirs := []string{dir}
		if ents, err := os.ReadDir(dir); err == nil {
			for _, e := range ents {
				if e.IsDir() {
					if _, ok := layout.ParseSet(e.Name()); ok {
						dirs = append(dirs, filepath.Join(dir, e.Name()))
					}
				}
			}
		} else {
			r.DirOK = false
			r.DirError = fmt.Sprintf("Cannot read data folder %s: %v", dir, err)
		}
		for _, d := range dirs {
			ents, err := os.ReadDir(d)
			if err != nil {
				continue
			}
			for _, e := range ents {
				// Skip macOS metadata (AppleDouble "._*" files on exFAT, .DS_Store).
				if e.IsDir() || strings.HasPrefix(e.Name(), "._") || e.Name() == ".DS_Store" {
					continue
				}
				m := fileRE.FindStringSubmatch(e.Name())
				if m == nil {
					if strings.HasSuffix(strings.ToLower(e.Name()), ".txt") {
						r.Extra = append(r.Extra, filepath.Join(d, e.Name()))
					}
					continue
				}
				set, _ := layout.ParseSet(m[1])
				n, _ := strconv.Atoi(m[2])
				f := File{Set: set.String(), Number: n, Name: e.Name(), Path: filepath.Join(d, e.Name())}
				key := fmt.Sprintf("%s/%02d", f.Set, n)
				if n < 1 || n > ExpectedFiles {
					r.Extra = append(r.Extra, f.Path)
					continue
				}
				if _, dup := found[key]; dup {
					r.Extra = append(r.Extra, f.Path)
					continue
				}
				found[key] = inspect(f)
			}
		}
	}

	r.Complete = r.DirOK
	for _, s := range layout.AllSets {
		sr := SetReport{Set: s.String(), Label: s.Label(), Expected: ExpectedFiles, Missing: []int{}}
		var sizes []int64
		for n := 1; n <= ExpectedFiles; n++ {
			f, ok := found[fmt.Sprintf("%s/%02d", s, n)]
			if !ok {
				f = File{Set: s.String(), Number: n, Name: fmt.Sprintf("%s%02d_PU", s, n), Status: StatusMissing}
				sr.Missing = append(sr.Missing, n)
			} else {
				sr.Present++
				if f.Status == StatusOK {
					sizes = append(sizes, f.Size)
				}
			}
			sr.Files = append(sr.Files, f)
		}
		// Flag files far smaller than the median of their healthy siblings.
		if len(sizes) >= 3 {
			sort.Slice(sizes, func(i, j int) bool { return sizes[i] < sizes[j] })
			median := sizes[len(sizes)/2]
			for i := range sr.Files {
				f := &sr.Files[i]
				if f.Status == StatusOK && f.Size < median/2 {
					f.Status = StatusSmall
					f.Problem = fmt.Sprintf("Only %s; other %s files are about %s. The copy may be incomplete.",
						HumanBytes(f.Size), s, HumanBytes(median))
				}
			}
		}
		for _, f := range sr.Files {
			if f.Searchable() {
				sr.Searchable++
				sr.Bytes += f.Size
			}
			if f.Status != StatusOK && f.Status != StatusMissing {
				sr.Problems++
			}
		}
		sr.MissingStr = Ranges(sr.Missing)
		sr.Summary = summarize(sr)
		if !r.DirOK {
			sr.Summary = ""
		}
		if len(sr.Missing) > 0 || sr.Problems > 0 {
			r.Complete = false
			if r.DirOK {
				r.Warnings = append(r.Warnings, sr.Summary)
			}
		}
		r.Sets = append(r.Sets, sr)
	}
	if !r.DirOK {
		r.Complete = false
		r.Warnings = append([]string{r.DirError}, r.Warnings...)
	}
	return r
}

func summarize(sr SetReport) string {
	var parts []string
	if sr.Present == 0 {
		return fmt.Sprintf("%s: no files found (expected %d). This set cannot be searched.", sr.Set, sr.Expected)
	}
	if len(sr.Missing) > 0 {
		parts = append(parts, fmt.Sprintf("%d of %d files present (missing %s)", sr.Present, sr.Expected, sr.MissingStr))
	} else {
		parts = append(parts, fmt.Sprintf("all %d files present", sr.Expected))
	}
	byStatus := map[string][]string{}
	for _, f := range sr.Files {
		if f.Status != StatusOK && f.Status != StatusMissing {
			byStatus[f.Status] = append(byStatus[f.Status], fmt.Sprintf("%02d", f.Number))
		}
	}
	for _, st := range []string{StatusEmpty, StatusUnreadable, StatusTruncated, StatusSmall, StatusBadFormat, StatusIrregular} {
		if l := byStatus[st]; len(l) > 0 {
			parts = append(parts, fmt.Sprintf("%s: %s", statusWord[st], strings.Join(l, ", ")))
		}
	}
	return sr.Set + ": " + strings.Join(parts, "; ")
}

var statusWord = map[string]string{
	StatusEmpty: "empty", StatusUnreadable: "unreadable", StatusTruncated: "cut off mid-record",
	StatusSmall: "unusually small", StatusBadFormat: "unexpected format", StatusIrregular: "irregular record length",
}

// inspect stats and spot-checks one file.
func inspect(f File) File {
	f.Status = StatusOK
	fh, err := os.Open(f.Path)
	if err != nil {
		f.Status, f.Problem = StatusUnreadable, err.Error()
		return f
	}
	defer fh.Close()
	st, err := fh.Stat()
	if err != nil {
		f.Status, f.Problem = StatusUnreadable, err.Error()
		return f
	}
	f.Size, f.ModTime = st.Size(), st.ModTime()
	if f.Size == 0 {
		f.Status, f.Problem = StatusEmpty, "File is empty."
		return f
	}
	head := make([]byte, 600)
	n, err := fh.ReadAt(head, 0)
	if err != nil && err != io.EOF {
		f.Status, f.Problem = StatusUnreadable, err.Error()
		return f
	}
	head = head[:n]
	if !looksLikeRecord(head) {
		f.Status, f.Problem = StatusBadFormat, "First line does not look like a NUMIDENT record (no SSN in columns 13–21)."
		return f
	}
	last := make([]byte, 1)
	if _, err := fh.ReadAt(last, f.Size-1); err != nil {
		f.Status, f.Problem = StatusUnreadable, err.Error()
		return f
	}
	if last[0] != '\n' {
		f.Status, f.Problem = StatusTruncated, "The last record has no line ending; the file looks cut off (incomplete copy or download)."
		return f
	}
	set, _ := layout.ParseSet(f.Set)
	if rs := set.RecordSize(); f.Size%rs != 0 {
		f.Status = StatusIrregular
		f.Problem = fmt.Sprintf("Size is not a whole number of %d-byte records; some lines have an unexpected length. Searches still work but SSN lookups are slower.", rs)
	}
	return f
}

func looksLikeRecord(b []byte) bool {
	if len(b) < 40 {
		return false
	}
	for _, c := range b[12:21] {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

// Ranges formats sorted numbers as "02–11, 14".
func Ranges(ns []int) string {
	var parts []string
	for i := 0; i < len(ns); {
		j := i
		for j+1 < len(ns) && ns[j+1] == ns[j]+1 {
			j++
		}
		if j == i {
			parts = append(parts, fmt.Sprintf("%02d", ns[i]))
		} else {
			parts = append(parts, fmt.Sprintf("%02d–%02d", ns[i], ns[j]))
		}
		i = j + 1
	}
	return strings.Join(parts, ", ")
}

// HumanBytes formats a byte count.
func HumanBytes(n int64) string {
	switch {
	case n >= 1<<30:
		return fmt.Sprintf("%.1f GB", float64(n)/(1<<30))
	case n >= 1<<20:
		return fmt.Sprintf("%.0f MB", float64(n)/(1<<20))
	case n >= 1<<10:
		return fmt.Sprintf("%.0f KB", float64(n)/(1<<10))
	}
	return fmt.Sprintf("%d B", n)
}
