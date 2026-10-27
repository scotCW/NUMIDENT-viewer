package scan

import (
	"bytes"
	"errors"
	"strings"

	"numident/internal/layout"
)

// Name matching modes.
const (
	ModeExact   = "exact"
	ModePrefix  = "prefix"
	ModeSoundex = "soundex"
)

// Query is a search request as sent by the UI.
type Query struct {
	Sets  []string `json:"sets"`            // set names; empty = all
	Files []string `json:"files,omitempty"` // optional explicit file names

	SSN      string `json:"ssn,omitempty"`
	First    string `json:"first,omitempty"`
	Middle   string `json:"middle,omitempty"`
	Last     string `json:"last,omitempty"`
	NameMode string `json:"nameMode,omitempty"`
	AltNames bool   `json:"altNames,omitempty"` // also match SS-5 other/signature names

	DOBFrom   int `json:"dobFrom,omitempty"`
	DOBTo     int `json:"dobTo,omitempty"`
	DeathFrom int `json:"deathFrom,omitempty"`
	DeathTo   int `json:"deathTo,omitempty"`

	POBCity  string `json:"pobCity,omitempty"`
	POBState string `json:"pobState,omitempty"`

	FatherFirst string `json:"fatherFirst,omitempty"`
	FatherLast  string `json:"fatherLast,omitempty"`
	MotherFirst string `json:"motherFirst,omitempty"`
	MotherLast  string `json:"motherLast,omitempty"`

	Sex string `json:"sex,omitempty"` // "1" male, "2" female, "0" unknown

	Limit int `json:"limit,omitempty"`
}

// term is one compiled name comparison.
type term struct {
	val []byte
	sx  [4]byte
}

// Matcher tests raw lines against a compiled query without allocating.
type Matcher struct {
	mode                   string
	ssn                    []byte
	first, middle, last    *term
	fFirst, fLast          *term
	mFirst, mLast          *term
	pobCity                []byte
	pobState               []byte
	sex                    byte
	dobFrom, dobTo         int
	deathFrom, deathTo     int
	altNames               bool
	needsSS5orCLM, needDOD bool
}

var errEmpty = errors.New("enter at least one search term")

func norm(s string) string { return strings.ToUpper(strings.TrimSpace(s)) }

// Compile validates and prepares q.
func Compile(q Query) (*Matcher, error) {
	m := &Matcher{mode: q.NameMode, altNames: q.AltNames}
	if m.mode == "" {
		m.mode = ModeExact
	}
	if m.mode != ModeExact && m.mode != ModePrefix && m.mode != ModeSoundex {
		return nil, errors.New("unknown name mode " + q.NameMode)
	}
	mk := func(s string) *term {
		s = norm(s)
		if s == "" {
			return nil
		}
		t := &term{val: []byte(s)}
		layout.SoundexInto(&t.sx, t.val)
		return t
	}
	if s := strings.ReplaceAll(strings.ReplaceAll(strings.TrimSpace(q.SSN), "-", ""), " ", ""); s != "" {
		if len(s) != 9 || strings.Trim(s, "0123456789") != "" {
			return nil, errors.New("SSN must be 9 digits")
		}
		m.ssn = []byte(s)
	}
	m.first, m.middle, m.last = mk(q.First), mk(q.Middle), mk(q.Last)
	m.fFirst, m.fLast, m.mFirst, m.mLast = mk(q.FatherFirst), mk(q.FatherLast), mk(q.MotherFirst), mk(q.MotherLast)
	if s := norm(q.POBCity); s != "" {
		m.pobCity = []byte(s)
	}
	if s := norm(q.POBState); s != "" {
		m.pobState = []byte(s)
	}
	if s := strings.TrimSpace(q.Sex); s != "" {
		if s != "0" && s != "1" && s != "2" {
			return nil, errors.New("sex must be 0, 1 or 2")
		}
		m.sex = s[0]
	}
	m.dobFrom, m.dobTo = q.DOBFrom, q.DOBTo
	m.deathFrom, m.deathTo = q.DeathFrom, q.DeathTo
	m.needsSS5orCLM = m.fFirst != nil || m.fLast != nil || m.mFirst != nil || m.mLast != nil || m.pobCity != nil || m.pobState != nil
	m.needDOD = m.deathFrom != 0 || m.deathTo != 0
	if m.ssn == nil && m.first == nil && m.middle == nil && m.last == nil && !m.needsSS5orCLM &&
		m.sex == 0 && m.dobFrom == 0 && m.dobTo == 0 && !m.needDOD {
		return nil, errEmpty
	}
	return m, nil
}

// SSN returns the SSN being searched for, or nil.
func (m *Matcher) SSN() []byte { return m.ssn }

// AppliesTo reports whether records of set s can possibly match. A filter on
// a field the set does not have (e.g. death year on SS-5) excludes the set.
func (m *Matcher) AppliesTo(s layout.Set) bool {
	switch s {
	case layout.SS5:
		return !m.needDOD
	case layout.DTH:
		return !m.needsSS5orCLM
	}
	return true
}

func (m *Matcher) cmp(t *term, field []byte) bool {
	if t == nil {
		return true
	}
	field = layout.TrimName(field)
	switch m.mode {
	case ModePrefix:
		return bytes.HasPrefix(field, t.val)
	case ModeSoundex:
		var sx [4]byte
		if !layout.SoundexInto(&sx, field) {
			return false
		}
		return sx == t.sx
	}
	return bytes.Equal(field, t.val)
}

func sl(line []byte, start, end int) []byte { // 1-based inclusive
	if start-1 >= len(line) {
		return nil
	}
	if end > len(line) {
		end = len(line)
	}
	return line[start-1 : end]
}

func (m *Matcher) nameAt(line []byte, off int) bool {
	return m.cmp(m.first, sl(line, 37+off, 52+off)) &&
		m.cmp(m.middle, sl(line, 53+off, 68+off)) &&
		m.cmp(m.last, sl(line, 69+off, 89+off))
}

func inRange(y, from, to int) bool {
	if y == 0 {
		return false
	}
	if from != 0 && y < from {
		return false
	}
	if to != 0 && y > to {
		return false
	}
	return true
}

// Match reports whether line (without line ending) matches.
func (m *Matcher) Match(s layout.Set, line []byte) bool {
	if m.ssn != nil && !bytes.Equal(sl(line, 13, 21), m.ssn) {
		return false
	}
	if !m.AppliesTo(s) {
		return false
	}
	postings := 1
	if s == layout.DTH {
		postings = 3
	}
	if m.sex != 0 {
		ok := false
		for k := 0; k < postings && !ok; k++ {
			f := sl(line, 105+k*150, 105+k*150)
			ok = len(f) == 1 && f[0] == m.sex
		}
		if !ok {
			return false
		}
	}
	if m.dobFrom != 0 || m.dobTo != 0 {
		ok := false
		for k := 0; k < postings && !ok; k++ {
			ok = inRange(layout.YearMDY(sl(line, 97+k*150, 104+k*150)), m.dobFrom, m.dobTo)
		}
		if !ok {
			return false
		}
	}
	if m.needDOD {
		ok := false
		if s == layout.CLM {
			ok = inRange(layout.YearMDY(sl(line, 298, 305)), m.deathFrom, m.deathTo)
		} else {
			for k := 0; k < 3 && !ok; k++ {
				ok = inRange(layout.YearMDY(sl(line, 145+k*150, 152+k*150)), m.deathFrom, m.deathTo)
			}
		}
		if !ok {
			return false
		}
	}
	if m.needsSS5orCLM {
		if m.pobState != nil && !bytes.Equal(bytes.TrimSpace(sl(line, 234, 235)), m.pobState) {
			return false
		}
		if m.pobCity != nil && !bytes.HasPrefix(bytes.TrimSpace(sl(line, 221, 233)), m.pobCity) {
			return false
		}
		if !m.cmp(m.fFirst, sl(line, 164, 179)) || !m.cmp(m.fLast, sl(line, 196, 216)) ||
			!m.cmp(m.mFirst, sl(line, 107, 122)) || !m.cmp(m.mLast, sl(line, 139, 159)) {
			return false
		}
	}
	if m.first == nil && m.middle == nil && m.last == nil {
		return true
	}
	if m.nameAt(line, 0) {
		return true
	}
	switch s {
	case layout.DTH:
		return m.nameAt(line, 150) || m.nameAt(line, 300)
	case layout.SS5:
		if m.altNames {
			return m.nameAt(line, layout.NameOffOther) || m.nameAt(line, layout.NameOffSignature)
		}
	}
	return false
}
