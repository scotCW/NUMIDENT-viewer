package layout

import "strings"

// Name is a parsed person name.
type Name struct {
	First  string `json:"first,omitempty"`
	Middle string `json:"middle,omitempty"`
	Last   string `json:"last,omitempty"`
	Suffix string `json:"suffix,omitempty"`
}

// IsZero reports whether all parts are blank.
func (n Name) IsZero() bool { return n.First == "" && n.Middle == "" && n.Last == "" && n.Suffix == "" }

// Full joins the non-blank parts.
func (n Name) Full() string {
	var parts []string
	for _, p := range []string{n.First, n.Middle, n.Last, n.Suffix} {
		if p != "" {
			parts = append(parts, p)
		}
	}
	return strings.Join(parts, " ")
}

func nameAt(line []byte, off int) Name {
	f, m, l, s := NameFields(off)
	return Name{
		First:  string(TrimName(f.Raw(line))),
		Middle: string(TrimName(m.Raw(line))),
		Last:   string(TrimName(l.Raw(line))),
		Suffix: s.String(line),
	}
}

func parentName(line []byte, first, middle, last, suffix Field) *Name {
	n := Name{First: first.String(line), Middle: middle.String(line), Last: last.String(line), Suffix: suffix.String(line)}
	if n.IsZero() {
		return nil
	}
	return &n
}

// Coded is a raw code with its decoded description.
type Coded struct {
	Code string `json:"code"`
	Desc string `json:"desc,omitempty"`
}

func coded(line []byte, f Field, table map[string]string) Coded {
	c := f.String(line)
	return Coded{Code: c, Desc: Describe(table, c)}
}

// DeathPosting is one of up to three death postings in a NUMDEATH record.
type DeathPosting struct {
	Index        int    `json:"index"`
	Name         Name   `json:"name"`
	DOB          Date   `json:"dob"`
	Sex          Coded  `json:"sex"`
	OtherNum     string `json:"otherNum,omitempty"`
	RecordID     string `json:"recordId,omitempty"`
	Proof        Coded  `json:"proof"`
	Program      Coded  `json:"program"`
	ZipResidence string `json:"zipResidence,omitempty"`
	ZipLumpSum   string `json:"zipLumpSum,omitempty"`
	Source       Coded  `json:"source"`
	VerifiedEDR  Coded  `json:"verifiedEdr"`
	DOD          Date   `json:"dod"`
	CertNum      string `json:"certNum,omitempty"`
	Posted       Date   `json:"posted"`
}

// Record is a parsed line from any of the three sets. Fields that do not
// apply to the record's set are left empty.
type Record struct {
	Set    string `json:"set"`
	File   string `json:"file,omitempty"`
	Offset int64  `json:"offset"`
	Raw    string `json:"raw"`

	RefNum    string `json:"refNum,omitempty"`
	SSN       string `json:"ssn"`
	Entry     Coded  `json:"entry"`
	CycleDate Date   `json:"cycleDate"`
	Name      Name   `json:"name"`
	DOB       Date   `json:"dob"`
	Sex       Coded  `json:"sex"`

	// SS-5 and claims
	Mother      *Name  `json:"mother,omitempty"`
	Father      *Name  `json:"father,omitempty"`
	POBCity     string `json:"pobCity,omitempty"`
	POBState    string `json:"pobState,omitempty"`
	ForeignBorn bool   `json:"foreignBorn,omitempty"`
	FormCode    Coded  `json:"formCode"`
	DOCode      string `json:"doCode,omitempty"`
	Conversion  Coded  `json:"conversion"`
	Deleted     bool   `json:"deleted,omitempty"`

	// SS-5 only
	Race        Coded `json:"race"`
	Citizenship Coded `json:"citizenship"`
	Interview   Coded `json:"interview"`
	OtherName   *Name `json:"otherName,omitempty"`
	SigName     *Name `json:"sigName,omitempty"`
	SigCode     Coded `json:"sigCode"`
	DOBChanged  bool  `json:"dobChanged,omitempty"`
	PriorDOB    Date  `json:"priorDob"`

	// Claims only
	FOAddress string `json:"foAddress,omitempty"`
	ClaimDate Date   `json:"claimDate"`
	OnsetDate Date   `json:"onsetDate"`
	DODClaim  Date   `json:"dodClaim"`

	// Deaths only
	Postings    []DeathPosting `json:"postings,omitempty"`
	NumPostings int            `json:"numPostings,omitempty"`
}

// Parse decodes one line (without its line terminator) of the given set.
func Parse(set Set, line []byte) Record {
	if n := len(line); n > 0 && line[n-1] == '\r' {
		line = line[:n-1]
	}
	r := Record{
		Set:       set.String(),
		Raw:       string(line),
		RefNum:    FRefNum.String(line),
		SSN:       FSSN.String(line),
		Entry:     coded(line, FEntryCode, EntryCodes),
		CycleDate: ParseYMD(FCycleDate.Raw(line)),
		Name:      nameAt(line, NameOffPrimary),
		DOB:       ParseMDY(FDOB.Raw(line)),
		Sex:       coded(line, FSex, SexCodes),
	}
	switch set {
	case SS5, CLM:
		r.Mother = parentName(line, FMotherFirst, FMotherMiddle, FMotherLast, FMotherSuffix)
		r.Father = parentName(line, FFatherFirst, FFatherMiddle, FFatherLast, FFatherSuffix)
		r.POBCity = FPOBCity.String(line)
		r.POBState = FPOBState.String(line)
		r.ForeignBorn = FPOBForeign.String(line) == "*"
		r.FormCode = coded(line, FFormCode, FormCodes)
		r.DOCode = FDOCode.String(line)
		r.Conversion = coded(line, FConversion, ConversionCodes)
		r.Deleted = FDeleteFlag.String(line) == "F"
	}
	switch set {
	case SS5:
		r.Race = coded(line, FRace, RaceCodes)
		r.Citizenship = coded(line, FCitizenship, CitizenshipCodes)
		r.Interview = coded(line, FInterview, InterviewCodes)
		if n := nameAt(line, NameOffOther); !n.IsZero() {
			r.OtherName = &n
		}
		if n := nameAt(line, NameOffSignature); !n.IsZero() {
			r.SigName = &n
		}
		r.SigCode = coded(line, FSigCode, SigCodes)
		r.DOBChanged = FDOBChange.String(line) == "*"
		r.PriorDOB = ParseMDY(FPriorDOB.Raw(line))
	case CLM:
		r.FOAddress = FFOAddress.String(line)
		r.ClaimDate = ParseMDY(FClaimDate.Raw(line))
		r.OnsetDate = ParseMDY(FOnsetDate.Raw(line))
		r.DODClaim = ParseMDY(FDODClaim.Raw(line))
	case DTH:
		r.NumPostings = num(FDthNOE.Bytes(line))
		for k := 0; k < deathPostings; k++ {
			p := parsePosting(line, k)
			// Keep posting 1 always; later ones only when they hold data.
			if k == 0 || !p.Name.IsZero() || !p.DOD.IsZero() {
				r.Postings = append(r.Postings, p)
			}
		}
	}
	return r
}

func parsePosting(line []byte, k int) DeathPosting {
	off := k * DeathPostingSpan
	at := func(f Field) Field { return f.Shift(off, "", "") }
	return DeathPosting{
		Index:        k + 1,
		Name:         nameAt(line, off),
		DOB:          ParseMDY(at(FDOB).Raw(line)),
		Sex:          coded(line, at(FSex), SexCodes),
		OtherNum:     at(FDthOtherNum).String(line),
		RecordID:     at(FDthRecordID).String(line),
		Proof:        coded(line, at(FDthProof), ProofCodes),
		Program:      coded(line, at(FDthProgram), ProgramCodes),
		ZipResidence: at(FDthZipRes).String(line),
		ZipLumpSum:   at(FDthZipLump).String(line),
		Source:       coded(line, at(FDthSource), SourceOfDeathCodes),
		VerifiedEDR:  coded(line, at(FDthEDR), EDRCodes),
		DOD:          ParseMDY(at(FDthDOD).Raw(line)),
		CertNum:      at(FDthCertNum).String(line),
		Posted:       ParseYMD(at(FDthPosted).Raw(line)),
	}
}

// DeathDate returns the best date of death in the record: the first death
// posting's DOD for NUMDEATH, the claim DOD for NUMCLM.
func (r Record) DeathDate() Date {
	for _, p := range r.Postings {
		if !p.DOD.IsZero() {
			return p.DOD
		}
	}
	return r.DODClaim
}
