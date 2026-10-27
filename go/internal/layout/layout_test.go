package layout

import (
	"bufio"
	"os"
	"testing"
)

func readLines(t *testing.T, path string) [][]byte {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	var out [][]byte
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		out = append(out, append([]byte(nil), sc.Bytes()...))
	}
	return out
}

// Golden cases: real lines from the user's release (first lines of
// NUMCLM01, NUMDEATH01, NUMSS501).
func TestGoldenClaim(t *testing.T) {
	lines := readLines(t, "testdata/clm.txt")
	r := Parse(CLM, lines[0])
	check(t, "ssn", r.SSN, "001010002")
	check(t, "ref", r.RefNum, "65008336049")
	check(t, "entry", r.Entry.Code, "L")
	check(t, "entry desc", r.Entry.Desc, "Life claim")
	check(t, "form", r.FormCode.Code, "5")
	check(t, "cycle", r.CycleDate.String(), "1976-02-19")
	check(t, "name", r.Name.Full(), "JOHN ALEXANDER HAZLETT")
	check(t, "dob", r.DOB.String(), "1879-02-28")
	check(t, "sex", r.Sex.Code, "0")
	check(t, "pob", r.POBCity+"/"+r.POBState, "CAMBRIDGE/MA")
	check(t, "fo address", r.FOAddress, "CAMBRIDGE MASS")
	check(t, "claim date", r.ClaimDate.String(), "1944-03-17")
	check(t, "conversion", r.Conversion.Code, "A")
	if r.Mother != nil || r.Father != nil {
		t.Errorf("expected no parents, got %+v %+v", r.Mother, r.Father)
	}
	r2 := Parse(CLM, lines[1])
	check(t, "pob2", r2.POBCity+"/"+r2.POBState, "/UN")
	check(t, "fo2", r2.FOAddress, "NASHUA N H")
	check(t, "sex2", r2.Sex.Desc, "Male")
}

func TestGoldenDeath(t *testing.T) {
	lines := readLines(t, "testdata/dth.txt")
	r := Parse(DTH, lines[0])
	check(t, "ssn", r.SSN, "001010104")
	check(t, "ref", r.RefNum, "")
	check(t, "entry", r.Entry.Code, "T")
	check(t, "name", r.Name.Full(), "ELSIE E BAKER")
	check(t, "dob", r.DOB.String(), "1909-10-30")
	if len(r.Postings) != 1 || r.NumPostings != 1 {
		t.Fatalf("postings: %d noe %d", len(r.Postings), r.NumPostings)
	}
	p := r.Postings[0]
	check(t, "other num", p.OtherNum, "001010104")
	check(t, "zip", p.ZipResidence, "033030000")
	check(t, "edr", p.VerifiedEDR.Code, "N")
	check(t, "dod", p.DOD.String(), "1989-12-18")
	check(t, "posted", p.Posted.String(), "1989-12-21")

	r2 := Parse(DTH, lines[1])
	check(t, "ref2", r2.RefNum, "87090100000")
	check(t, "dod partial", r2.Postings[0].DOD.String(), "1974-06-??")
	if !r2.Postings[0].DOD.Partial() {
		t.Error("expected partial DOD")
	}
	check(t, "recordid", r2.Postings[0].RecordID, "1")

	r3 := Parse(DTH, lines[2])
	check(t, "source", r3.Postings[0].Source.Code, "HC")
	check(t, "source desc", r3.Postings[0].Source.Desc, "CMS (formerly HCFA)")
	check(t, "dod3", r3.DeathDate().String(), "1993-11-??")
}

func TestGoldenSS5(t *testing.T) {
	lines := readLines(t, "testdata/ss5.txt")
	r := Parse(SS5, lines[0])
	check(t, "ssn", r.SSN, "001010501")
	check(t, "form", r.FormCode.Desc, "SS-5")
	check(t, "entry", r.Entry.Desc, "Original SSN")
	check(t, "cycle partial", r.CycleDate.String(), "1936-11-??")
	check(t, "name", r.Name.Full(), "JOHN MARSHALL HOYT")
	check(t, "dob", r.DOB.String(), "1885-11-10")
	check(t, "sex", r.Sex.Desc, "Male")
	check(t, "race", r.Race.Desc, "White")
	check(t, "mother", r.Mother.Full(), "MINNIE PERKINS")
	check(t, "father", r.Father.Full(), "J F HOYT")
	check(t, "pob", r.POBCity+"/"+r.POBState, "LOCONIA/NH")
	check(t, "sig", r.SigCode.Desc, "Client's signature")
	check(t, "conv", r.Conversion.Code, "A")

	r2 := Parse(SS5, lines[1])
	check(t, "mother2", r2.Mother.Full(), "VERA E BERRY")
	check(t, "father2", r2.Father.Full(), "FRANK P SMITH")
	check(t, "pob2", r2.POBCity, "MEREDITH BEL")
}

func TestCRLFAndShortLines(t *testing.T) {
	r := Parse(SS5, []byte("            123456789\r"))
	check(t, "ssn", r.SSN, "123456789")
	check(t, "dob", r.DOB.String(), "")
	if r.Mother != nil {
		t.Error("short line should have no mother")
	}
}

func TestDates(t *testing.T) {
	cases := []struct{ in, mdy, ymd string }{
		{"12181989", "1989-12-18", ""},
		{"06XX1974", "1974-06-??", ""},
		{"XXXX1974", "1974-??-??", ""},
		{"00000000", "", ""},
		{"        ", "", ""},
		{"19891221", "", "1989-12-21"},
		{"193611XX", "", "1936-11-??"},
	}
	for _, c := range cases {
		if c.mdy != "" || c.ymd == "" {
			check(t, "mdy "+c.in, ParseMDY([]byte(c.in)).String(), c.mdy)
		}
		if c.ymd != "" {
			check(t, "ymd "+c.in, ParseYMD([]byte(c.in)).String(), c.ymd)
		}
	}
	if y := YearMDY([]byte("06XX1974")); y != 1974 {
		t.Errorf("YearMDY = %d", y)
	}
}

func TestSoundex(t *testing.T) {
	for in, want := range map[string]string{
		"ROBERT": "R163", "RUPERT": "R163", "RUBIN": "R150", "ASHCRAFT": "A261",
		"TYMCZAK": "T522", "PFISTER": "P236", "HONEYMAN": "H555", "LEE": "L000",
		"O'BRIEN": "O165", "": "",
	} {
		check(t, "soundex "+in, Soundex(in), want)
	}
}

func TestFieldsOrderedAndInRange(t *testing.T) {
	for _, s := range AllSets {
		prev := 0
		for _, f := range Fields(s) {
			if f.Start < 1 || f.End > 500 || f.End < f.Start {
				t.Errorf("%s %s bad range %d-%d", s, f.Key, f.Start, f.End)
			}
			if f.Start <= prev {
				t.Errorf("%s %s overlaps previous (start %d, prev end %d)", s, f.Key, f.Start, prev)
			}
			prev = f.End
		}
	}
}

func check(t *testing.T, what, got, want string) {
	t.Helper()
	if got != want {
		t.Errorf("%s: got %q, want %q", what, got, want)
	}
}
