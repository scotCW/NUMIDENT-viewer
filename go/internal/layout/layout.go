// Package layout describes the fixed-width record layouts of NARA's public-use
// NUMIDENT files (SS-5 applications, claims, and death records) and parses
// raw lines into structured records.
//
// Positions are 1-based and inclusive, exactly as in NARA's layout PDFs
// (docs/nara/rg047_num_*_layout.pdf). Lines in the release end in CRLF and
// have trailing blanks trimmed, so any field may be absent from a short line;
// absent bytes read as blanks.
package layout

import (
	"bytes"
	"strings"
)

// Set identifies one of the three NUMIDENT record types.
type Set int

const (
	SS5 Set = iota
	CLM
	DTH
)

// AllSets lists the sets in display order.
var AllSets = []Set{SS5, CLM, DTH}

var setNames = [...]string{"NUMSS5", "NUMCLM", "NUMDEATH"}
var setLabels = [...]string{"SS-5 applications", "Claims", "Deaths"}

func (s Set) String() string { return setNames[s] }

// Label is a human-readable name for the set.
func (s Set) Label() string { return setLabels[s] }

// ParseSet converts "NUMSS5"/"NUMCLM"/"NUMDEATH" (any case) to a Set.
func ParseSet(name string) (Set, bool) {
	for i, n := range setNames {
		if strings.EqualFold(n, name) {
			return Set(i), true
		}
	}
	return 0, false
}

// Field is one fixed-width column range.
type Field struct {
	Key   string `json:"key"`
	Label string `json:"label"`
	Start int    `json:"start"` // 1-based, inclusive
	End   int    `json:"end"`   // 1-based, inclusive
}

// Raw returns the field's bytes (untrimmed); nil if the line is too short.
func (f Field) Raw(line []byte) []byte {
	s := f.Start - 1
	if s >= len(line) {
		return nil
	}
	e := f.End
	if e > len(line) {
		e = len(line)
	}
	return line[s:e]
}

// Bytes returns the field with surrounding blanks removed.
func (f Field) Bytes(line []byte) []byte { return bytes.TrimSpace(f.Raw(line)) }

// String returns the trimmed field as a string.
func (f Field) String(line []byte) string { return string(f.Bytes(line)) }

func fld(key, label string, start, end int) Field {
	return Field{Key: key, Label: label, Start: start, End: end}
}

// Columns shared by all three sets.
var (
	FRefNum    = fld("ref_num", "Reference number", 1, 11)
	FSSN       = fld("ssn", "SSN", 13, 21)
	FEntryCode = fld("entry_code", "Entry code", 27, 27)
	FCycleDate = fld("cycle_date", "Cycle date (CCYYMMDD)", 29, 36)
	FSuffix    = fld("suffix", "Suffix", 90, 93)
	FDOB       = fld("dob", "Date of birth (MMDDCCYY)", 97, 104)
	FSex       = fld("sex", "Sex", 105, 105)
)

// Name blocks. Every name in every set uses the same shape: first name in a
// 16-column slot, middle in 16, last in 21 (each slot ends with the overflow
// indicator '*'). The blocks differ only by offset from the primary name.
const (
	NameOffPrimary   = 0
	NameOffOther     = 200 // SS-5 "other name used" (237-288)
	NameOffSignature = 260 // SS-5 signature name (297-348)
	DeathPostingSpan = 150 // NUMDEATH repeats its posting block 3 times
)

// Parent name blocks (SS-5 and claim records).
var (
	FMotherFirst  = fld("mother_first", "Mother first name", 107, 121)
	FMotherMiddle = fld("mother_middle", "Mother middle name", 123, 137)
	FMotherLast   = fld("mother_last", "Mother last name", 139, 158)
	FMotherSuffix = fld("mother_suffix", "Mother suffix", 160, 163)
	FFatherFirst  = fld("father_first", "Father first name", 164, 178)
	FFatherMiddle = fld("father_middle", "Father middle name", 180, 194)
	FFatherLast   = fld("father_last", "Father last name", 196, 215)
	FFatherSuffix = fld("father_suffix", "Father suffix", 217, 220)
	FPOBCity      = fld("pob_city", "Place of birth (city/county)", 221, 232)
	FPOBState     = fld("pob_state", "Place of birth (state/country)", 234, 235)
	FPOBForeign   = fld("pob_foreign", "Foreign-born indicator", 236, 236)
)

// SS-5 only.
var (
	FInterview   = fld("interview", "Interview code (evidence)", 12, 12)
	FCitizenship = fld("citizenship", "Citizenship code", 22, 22)
	FDOCode      = fld("do_code", "Office code", 23, 25)
	FFormCode    = fld("form_code", "Form code", 26, 26)
	FPrintCode   = fld("print_code", "Print code", 28, 28)
	FRace        = fld("race", "Race/ethnicity", 106, 106)
	FSigCode     = fld("sig_code", "Signature code", 354, 354)
	FNotify      = fld("notify", "Notify code", 358, 359)
	FCardCode    = fld("card_code", "Card code", 360, 360)
	FDIBFreeze   = fld("dib_freeze", "Disability status", 361, 361)
	FDOBChange   = fld("dob_change", "DOB changed indicator", 362, 362)
	FPriorDOB    = fld("prior_dob", "Prior DOB (MMDDCCYY)", 363, 370)
	FCorrInd     = fld("corr_ind", "Correspondence code", 371, 372)
	FBirthCert   = fld("birth_cert", "Birth certificate number", 373, 383)
	FAlienReg    = fld("alien_reg", "Alien registration number", 386, 400)
	FControlNum  = fld("control_num", "Card control number", 413, 421)
	FDiffReason  = fld("diff_reason", "Different-number reason", 497, 497)
	FConversion  = fld("conversion", "Conversion record code", 498, 498)
	FEntrySub    = fld("entry_subcode", "Entry subcode", 499, 499)
	FDeleteFlag  = fld("delete_flag", "Logically deleted", 500, 500)
)

// Claim only.
var (
	FFOAddress = fld("fo_address", "Field office address", 237, 281)
	FClaimDate = fld("claim_date", "Claim date (MMDDCCYY)", 282, 289)
	FOnsetDate = fld("onset_date", "Date of onset (MMDDCCYY)", 290, 297)
	FDODClaim  = fld("dod_claim", "Date of death from claim (MMDDCCYY)", 298, 305)
)

// Death only. Posting fields are given for posting 1; add
// k*DeathPostingSpan for posting k+1.
var (
	FDthOtherNum  = fld("other_num", "Other number (CAN/HUN)", 107, 115)
	FDthRecordID  = fld("record_id", "Record ID code", 116, 116)
	FDthProof     = fld("proof", "Proof of death", 117, 117)
	FDthProgram   = fld("program", "Program involvement", 118, 118)
	FDthZipRes    = fld("zip_residence", "Residence ZIP", 119, 127)
	FDthZipLump   = fld("zip_lump_sum", "Lump-sum payment ZIP", 128, 136)
	FDthSource    = fld("source", "Source of death", 142, 143)
	FDthEDR       = fld("verified_edr", "Verified EDR", 144, 144)
	FDthDOD       = fld("dod", "Date of death (MMDDCCYY)", 145, 152)
	FDthCertNum   = fld("cert_num", "Death certificate number", 153, 178)
	FDthPosted    = fld("posted", "Posting date (CCYYMMDD)", 179, 186)
	FDthNOE       = fld("noe", "Number of death postings", 487, 487)
	deathPostings = 3
)

// Shift returns f moved right by off columns.
func (f Field) Shift(off int, keySuffix, labelSuffix string) Field {
	return Field{Key: f.Key + keySuffix, Label: f.Label + labelSuffix, Start: f.Start + off, End: f.End + off}
}

// NameFields returns first/middle/last/suffix fields for a name block at off.
// The first three include their trailing overflow column.
func NameFields(off int) (first, middle, last, suffix Field) {
	return fld("first", "First name", 37+off, 52+off),
		fld("middle", "Middle name", 53+off, 68+off),
		fld("last", "Last name", 69+off, 89+off),
		fld("suffix", "Suffix", 90+off, 93+off)
}

func nameBlock(off int, prefix, label string) []Field {
	f, m, l, s := NameFields(off)
	return []Field{
		{prefix + "first", label + " first name", f.Start, f.End},
		{prefix + "middle", label + " middle name", m.Start, m.End},
		{prefix + "last", label + " last name", l.Start, l.End},
		{prefix + "suffix", label + " suffix", s.Start, s.End},
	}
}

// Fields returns the documented, non-filler fields of a set in column order,
// used for the raw-line overlay in the UI.
func Fields(s Set) []Field {
	var out []Field
	switch s {
	case SS5:
		out = []Field{FRefNum, FInterview, FSSN, FCitizenship, FDOCode, FFormCode, FEntryCode, FPrintCode, FCycleDate}
		out = append(out, nameBlock(0, "", "NH")...)
		out = append(out, FDOB, FSex, FRace,
			FMotherFirst, FMotherMiddle, FMotherLast, FMotherSuffix,
			FFatherFirst, FFatherMiddle, FFatherLast, FFatherSuffix,
			FPOBCity, FPOBState, FPOBForeign)
		out = append(out, nameBlock(NameOffOther, "other_", "Other")...)
		out = append(out, nameBlock(NameOffSignature, "sig_", "Signature")...)
		out = append(out, FSigCode, FNotify, FCardCode, FDIBFreeze, FDOBChange, FPriorDOB, FCorrInd,
			FBirthCert, FAlienReg, FControlNum, FDiffReason, FConversion, FEntrySub, FDeleteFlag)
	case CLM:
		out = []Field{FRefNum, FSSN, FDOCode, FFormCode, FEntryCode, FCycleDate}
		out = append(out, nameBlock(0, "", "NH")...)
		out = append(out, FDOB, FSex,
			FMotherFirst, FMotherMiddle, FMotherLast, FMotherSuffix,
			FFatherFirst, FFatherMiddle, FFatherLast, FFatherSuffix,
			FPOBCity, FPOBState, FPOBForeign,
			FFOAddress, FClaimDate, FOnsetDate, FDODClaim, FConversion, FDeleteFlag)
	case DTH:
		out = []Field{FRefNum, FSSN, FEntryCode, FCycleDate}
		for k := 0; k < deathPostings; k++ {
			off := k * DeathPostingSpan
			ks := "_" + string(rune('1'+k))
			ls := " (posting " + string(rune('1'+k)) + ")"
			for _, f := range nameBlock(off, "", "NH") {
				out = append(out, f.Shift(0, ks, ls))
			}
			for _, f := range []Field{FDOB, FSex, FDthOtherNum, FDthRecordID, FDthProof, FDthProgram,
				FDthZipRes, FDthZipLump, FDthSource, FDthEDR, FDthDOD, FDthCertNum, FDthPosted} {
				out = append(out, f.Shift(off, ks, ls))
			}
		}
		out = append(out, FDthNOE)
	}
	return out
}

// TrimName removes blanks and the overflow marker '*' from a name slot.
func TrimName(b []byte) []byte {
	return bytes.Trim(b, " *")
}

// Physical record shape, verified against the real release: every line in a
// set has the same length (no trimming). NUMSS5 and NUMCLM end in LF, NUMDEATH
// in CRLF. NUMCLM omits column 500 and NUMDEATH columns 488–500.
var (
	lineLen    = [...]int{500, 499, 487}
	terminator = [...]string{"\n", "\n", "\r\n"}
)

// LineLen is the number of data characters per line (without terminator).
func (s Set) LineLen() int { return lineLen[s] }

// Terminator is the line ending used by the set.
func (s Set) Terminator() string { return terminator[s] }

// RecordSize is the number of bytes per record including the terminator.
func (s Set) RecordSize() int64 { return int64(lineLen[s] + len(terminator[s])) }
