package api

import (
	"fmt"
	"net/http"
	"sort"
	"strings"

	"numident/internal/catalog"
	"numident/internal/layout"
	"numident/internal/scan"
)

// PersonRecord is one record of a person with its field overlay.
type PersonRecord struct {
	layout.Record
	Fields []FieldValue `json:"fields"`
}

// FieldValue locates one field in the raw line.
type FieldValue struct {
	Key   string `json:"key"`
	Label string `json:"label"`
	Start int    `json:"start"`
	End   int    `json:"end"`
	Value string `json:"value"`
}

// Variant is one distinct value of a field and where it appears.
type Variant struct {
	Value   string   `json:"value"`
	Sources []string `json:"sources"`
}

// Fact is a field with all its distinct values across the person's records.
type Fact struct {
	Field    string    `json:"field"`
	Label    string    `json:"label"`
	Variants []Variant `json:"variants"`
	Conflict bool      `json:"conflict"`
}

// Person is everything found for one SSN.
type Person struct {
	SSN      string         `json:"ssn"`
	Records  []PersonRecord `json:"records"`
	Facts    []Fact         `json:"facts"`
	Coverage []string       `json:"coverage"`
	Status   string         `json:"status"`
	Elapsed  float64        `json:"elapsed"`
}

func overlay(set layout.Set, raw string) []FieldValue {
	line := []byte(raw)
	var out []FieldValue
	for _, f := range layout.Fields(set) {
		v := f.String(line)
		if v == "" {
			continue
		}
		out = append(out, FieldValue{f.Key, f.Label, f.Start, f.End, v})
	}
	return out
}

func source(r layout.Record, i int) string {
	s := fmt.Sprintf("%s #%d", r.Set, i+1)
	if c := r.CycleDate.String(); c != "" {
		s += " (" + c + ")"
	}
	return s
}

// buildPerson assembles a person from hits and explains coverage.
func buildPerson(ssn string, hits []scan.Hit, snap scan.Snapshot, rep catalog.Report, q scan.Query) Person {
	p := Person{SSN: ssn, Status: snap.Status, Elapsed: snap.Elapsed}
	for _, h := range hits {
		rec := layout.Parse(h.Set, []byte(h.Line))
		rec.File, rec.Offset = h.File, h.Offset
		p.Records = append(p.Records, PersonRecord{rec, overlay(h.Set, h.Line)})
	}
	sort.SliceStable(p.Records, func(i, j int) bool {
		a, b := p.Records[i].CycleDate, p.Records[j].CycleDate
		if a.Year != b.Year {
			return a.Year < b.Year
		}
		if a.Month != b.Month {
			return a.Month < b.Month
		}
		return a.Day < b.Day
	})

	type acc struct {
		label string
		order []string
		src   map[string][]string
	}
	facts := map[string]*acc{}
	var keys []string
	add := func(key, label, val, src string) {
		val = strings.TrimSpace(val)
		if val == "" {
			return
		}
		a := facts[key]
		if a == nil {
			a = &acc{label: label, src: map[string][]string{}}
			facts[key] = a
			keys = append(keys, key)
		}
		if _, ok := a.src[val]; !ok {
			a.order = append(a.order, val)
		}
		a.src[val] = append(a.src[val], src)
	}
	for i, pr := range p.Records {
		r := pr.Record
		src := source(r, i)
		add("name", "Name", r.Name.Full(), src)
		add("dob", "Date of birth", r.DOB.String(), src)
		if r.Sex.Code == "1" || r.Sex.Code == "2" {
			add("sex", "Sex", r.Sex.Desc, src)
		}
		if r.POBCity != "" || r.POBState != "" {
			add("pob", "Place of birth", strings.Trim(r.POBCity+", "+r.POBState, ", "), src)
		}
		if r.Father != nil {
			add("father", "Father", r.Father.Full(), src)
		}
		if r.Mother != nil {
			add("mother", "Mother", r.Mother.Full(), src)
		}
		if r.Race.Desc != "" && r.Race.Code != "0" {
			add("race", "Race (as recorded)", r.Race.Desc, src)
		}
		if r.OtherName != nil {
			add("other", "Other name used", r.OtherName.Full(), src)
		}
		for _, d := range r.Postings {
			ps := fmt.Sprintf("%s posting %d", src, d.Index)
			add("dod", "Date of death", d.DOD.String(), ps)
			if d.DOB.String() != "" {
				add("dob", "Date of birth", d.DOB.String(), ps)
			}
			if d.ZipResidence != "" {
				add("zip", "Last residence ZIP", d.ZipResidence, ps)
			}
		}
		if !r.DODClaim.IsZero() {
			add("dod", "Date of death", r.DODClaim.String(), src+" (claim)")
		}
	}
	order := []string{"name", "other", "dob", "sex", "pob", "father", "mother", "race", "dod", "zip"}
	for _, k := range order {
		a := facts[k]
		if a == nil {
			continue
		}
		f := Fact{Field: k, Label: a.label}
		for _, v := range a.order {
			f.Variants = append(f.Variants, Variant{v, a.src[v]})
		}
		// Names legitimately change; dates, sex and birthplace should not.
		f.Conflict = len(f.Variants) > 1 && k != "other" && k != "zip" && !compatibleDates(k, f.Variants)
		p.Facts = append(p.Facts, f)
	}
	p.Coverage = coverage(rep, q, snap)
	return p
}

// compatibleDates treats "1974-06-??" and "1974-06-15" as agreeing.
func compatibleDates(key string, vs []Variant) bool {
	if key != "dob" && key != "dod" {
		return false
	}
	for i := range vs {
		for j := i + 1; j < len(vs); j++ {
			if !datesAgree(vs[i].Value, vs[j].Value) {
				return false
			}
		}
	}
	return true
}

func datesAgree(a, b string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] && a[i] != '?' && b[i] != '?' {
			return false
		}
	}
	return true
}

// coverage explains what was and was not searched, so that "no record"
// is never mistaken for "no such event".
func coverage(rep catalog.Report, q scan.Query, snap scan.Snapshot) []string {
	var notes []string
	want := map[string]bool{}
	for _, s := range q.Sets {
		want[strings.ToUpper(s)] = true
	}
	for _, sr := range rep.Sets {
		if len(want) > 0 && !want[sr.Set] {
			notes = append(notes, fmt.Sprintf("%s (%s) was not searched — it was unticked.", sr.Set, sr.Label))
			continue
		}
		if sr.Present == 0 {
			notes = append(notes, fmt.Sprintf("%s: no files are available, so %s records cannot appear here.", sr.Set, strings.ToLower(sr.Label)))
			continue
		}
		if len(sr.Missing) > 0 {
			notes = append(notes, fmt.Sprintf("%s: %d of %d files are missing (%s). A record in those files would not be shown, so absence is not conclusive.",
				sr.Set, len(sr.Missing), sr.Expected, sr.MissingStr))
		}
		var bad []string
		for _, f := range sr.Files {
			if f.Status != catalog.StatusOK && f.Status != catalog.StatusMissing {
				bad = append(bad, fmt.Sprintf("%02d (%s)", f.Number, f.Status))
			}
		}
		if len(bad) > 0 {
			notes = append(notes, fmt.Sprintf("%s: files with problems: %s.", sr.Set, strings.Join(bad, ", ")))
		}
	}
	if len(q.Files) > 0 {
		notes = append(notes, "Only the files you picked were searched.")
	}
	if snap.FilesFailed > 0 {
		head := fmt.Sprintf("%d of %d files could not be read and count as not searched", snap.FilesFailed, snap.FilesTotal)
		if snap.DriveLost {
			head += " — the data drive was disconnected during the search"
		}
		var names []string
		for _, e := range snap.Errors {
			names = append(names, e.Name)
		}
		notes = append(notes, head+": "+strings.Join(names, ", ")+". A record in those files would not be shown.")
	}
	switch snap.Status {
	case "cancelled":
		notes = append(notes, "The lookup was cancelled before every file was searched.")
	case "limit":
		notes = append(notes, "The result limit was reached; there may be more records.")
	}
	return notes
}

func (s *Server) handleSearchPerson(w http.ResponseWriter, r *http.Request) {
	e := s.lookup(r.PathValue("id"))
	if e == nil {
		writeErr(w, 404, "no such search")
		return
	}
	q := e.s.Query
	ssn := strings.ReplaceAll(strings.ReplaceAll(q.SSN, "-", ""), " ", "")
	if ssn == "" {
		writeErr(w, 400, "not an SSN search")
		return
	}
	s.mu.Lock()
	rep := s.report
	s.mu.Unlock()
	writeJSON(w, 200, buildPerson(ssn, e.s.Hits(0), e.s.Snapshot(), rep, q))
}

// handlePerson is a synchronous SSN lookup: GET /api/person/{ssn}?sets=A,B
func (s *Server) handlePerson(w http.ResponseWriter, r *http.Request) {
	q := scan.Query{SSN: r.PathValue("ssn"), Limit: 10000}
	if v := r.URL.Query().Get("sets"); v != "" {
		q.Sets = strings.Split(v, ",")
	}
	sr, err := s.startSearch(q)
	if err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	select {
	case <-sr.Done():
	case <-r.Context().Done():
		sr.Cancel()
		return
	}
	s.mu.Lock()
	rep := s.report
	s.mu.Unlock()
	ssn := strings.ReplaceAll(strings.ReplaceAll(q.SSN, "-", ""), " ", "")
	writeJSON(w, 200, buildPerson(ssn, sr.Hits(0), sr.Snapshot(), rep, q))
}
