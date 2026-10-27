package layout

import (
	"encoding/json"
	"fmt"
)

// Date is a possibly partial date. A zero component means unknown: the
// release writes unknown parts as "XX" (e.g. 06XX1974, 193611XX) or zeros.
type Date struct {
	Year, Month, Day int
	Raw              string
}

// IsZero reports whether no part of the date is known.
func (d Date) IsZero() bool { return d.Year == 0 && d.Month == 0 && d.Day == 0 }

// Partial reports whether some but not all parts are known.
func (d Date) Partial() bool { return !d.IsZero() && (d.Year == 0 || d.Month == 0 || d.Day == 0) }

// String renders YYYY-MM-DD with "??" for unknown parts, or "" if unknown.
func (d Date) String() string {
	if d.IsZero() {
		return ""
	}
	part := func(v, w int) string {
		if v == 0 {
			if w == 4 {
				return "????"
			}
			return "??"
		}
		return fmt.Sprintf("%0*d", w, v)
	}
	return part(d.Year, 4) + "-" + part(d.Month, 2) + "-" + part(d.Day, 2)
}

// MarshalJSON encodes the date as its display string.
func (d Date) MarshalJSON() ([]byte, error) { return json.Marshal(d.String()) }

// num parses an all-digit field; anything else (XX, blanks) is 0.
func num(b []byte) int {
	if len(b) == 0 {
		return 0
	}
	n := 0
	for _, c := range b {
		if c < '0' || c > '9' {
			return 0
		}
		n = n*10 + int(c-'0')
	}
	return n
}

func clean(d Date) Date {
	if d.Month < 1 || d.Month > 12 {
		d.Month = 0
	}
	if d.Day < 1 || d.Day > 31 {
		d.Day = 0
	}
	if d.Year < 1700 || d.Year > 2100 {
		d.Year = 0
	}
	return d
}

// ParseMDY parses an 8-column MMDDCCYY field.
func ParseMDY(b []byte) Date {
	if len(b) < 8 {
		return Date{Raw: string(b)}
	}
	return clean(Date{Month: num(b[0:2]), Day: num(b[2:4]), Year: num(b[4:8]), Raw: string(b)})
}

// ParseYMD parses an 8-column CCYYMMDD field.
func ParseYMD(b []byte) Date {
	if len(b) < 8 {
		return Date{Raw: string(b)}
	}
	return clean(Date{Year: num(b[0:4]), Month: num(b[4:6]), Day: num(b[6:8]), Raw: string(b)})
}

// YearMDY extracts just the year from a raw MMDDCCYY field without
// allocating; 0 when unknown.
func YearMDY(b []byte) int {
	if len(b) < 8 {
		return 0
	}
	y := num(b[4:8])
	if y < 1700 || y > 2100 {
		return 0
	}
	return y
}
