package layout

// Code tables transcribed from NARA's layout PDFs (docs/nara/).

var SexCodes = map[string]string{"0": "Unknown", "1": "Male", "2": "Female"}

var RaceCodes = map[string]string{
	"0": "Unknown", "1": "White", "2": "Black", "3": "Other",
	"4": "Asian", "5": "Hispanic", "6": "North American native",
}

var EntryCodes = map[string]string{
	"0": "Original SSN",
	"2": "Duplicate SSN – change or replacement",
	"4": "Reestablish void SSN",
	"E": "Special indicator (SPIN)",
	"J": "New account (emergency issue number)",
	"Q": "Correspondence",
	"V": "Voided SSN",
	"1": "Change in DOB",
	"5": "Sex correction",
	"9": "Internal correction",
	"G": "Generated from ERF/MBR/MULTX",
	"K": "Duplicate name change",
	"P": "Change identifying information",
	"S": "Supporting application",
	"W": "Welfare request",
	"L": "Life claim",
	"D": "Death claim",
	"T": "Death entry",
}

var FormCodes = map[string]string{
	"A": "Enumeration at Entry (EAE)",
	"C": "Automated – integrated client process",
	"6": "Enumeration at Birth (EAB)",
	"T": "Telephone replacement request",
	"1": "SS-5",
	"2": "OAAN-7003 or duplicate issued",
	"3": "SSA-9638",
	"4": "SSA-9638 for SSI conversion case",
	"5": "OAC-790 or OAD-840 (Title II claim)",
	"7": "SS-5 for AFDC case",
	"8": "OAAN-7003.2 (OCRO correction)",
	"9": "OA-D840 (older Title II disability claim)",
}

var CitizenshipCodes = map[string]string{
	"A": "U.S. citizen",
	"B": "Legal alien authorized to work",
	"C": "Legal alien not authorized to work",
	"D": "Other",
	"E": "Alien student – restricted work authorized",
	"F": "Conditionally legalized alien",
}

var InterviewCodes = map[string]string{
	"A": "Alien temporarily allowed to work during legalization",
	"B": "Alien not allowed to work; birth record before age 5",
	"C": "Evidence other than birth record",
	"D": "Duplicate request; evidence of identity only",
	"E": "IRS special project (tax year 1977)",
	"H": "Permanent resident alien",
	"I": "Alien not in status",
	"N": "Alien not authorized to work",
	"P": "Birth record established before age 5",
	"R": "Foreign student, restricted employment",
	"X": "U.S. born, not U.S. citizen; not allowed to work",
	"Y": "U.S. born, not U.S. citizen; birth record before age 5",
}

var SigCodes = map[string]string{
	"P": "Parent's signature", "S": "Client's signature",
	"D": "Not signed, SSA prepared", "E": "From correspondence",
	"F": "Signed in foreign characters", "I": "From IRS form 3912",
	"K": "Signature differs from NH's name", "O": "Signed by other than applicant",
	"R": "From RRB form", "U": "Not signed", "W": "Amish waiver (form 4029)",
	"X": "Signed by mark, with witnesses",
}

var ConversionCodes = map[string]string{
	"A": "Conversion record added to ALPHIDENT and NUMIDENT",
	"C": "Conversion record added to NUMIDENT; not on ALPHIDENT",
	"F": "Not a conversion record; full Enumeration System",
	"I": "Not a conversion record; interim Enumeration System",
	"K": "Conversion record; passed high-group test",
	"M": "Conversion record with MULTX cross-reference",
	"X": "Conversion record with cross-reference multiple SSN",
}

var ProofCodes = map[string]string{
	"P": "Proven / verified", "V": "Verified", "N": "Non-verified", "S": "Payment alert",
}

var ProgramCodes = map[string]string{
	"A": "Title II only", "B": "Title XVI only", "C": "Black Lung only", "D": "Railroad Board only",
	"E": "Title II and XVI", "F": "Title II and Black Lung", "G": "Title II and Railroad Board",
	"H": "Title II, XVI and Black Lung", "I": "Title II, XVI, Black Lung and Railroad Board",
	"J": "Title XVI and Black Lung",
}

var EDRCodes = map[string]string{"Y": "Yes", "N": "No", "O": "Override"}

var SourceOfDeathCodes = func() map[string]string {
	m := map[string]string{
		"BX": "BENDEX (Title II data exchange)", "FO": "Field office", "HC": "CMS (formerly HCFA)",
		"PE": "Post-entitlement (Title II)", "SI": "Title XVI system", "VA": "Veterans Affairs",
		"CS": "Civil Service", "DC": "Death certificate", "DD": "Department of Defense",
		"DL": "Department of Labor", "HI": "HCFA (uninsured)", "RB": "Railroad Retirement Board",
		"55": "Asia", "56": "Canada", "57": "Central America and West Indies", "58": "Europe",
		"59": "Mexico", "60": "Oceania", "61": "Philippines", "62": "South America",
		"63": "Trust territories", "64": "American Samoa", "65": "Guam",
		"70": "Field office (SSA-704)", "72": "Field office (SSA-704)",
	}
	states := []string{"Alabama", "Alaska", "Arizona", "Arkansas", "California", "Colorado",
		"Connecticut", "Delaware", "District of Columbia", "Florida", "Georgia", "Hawaii", "Idaho",
		"Illinois", "Indiana", "Iowa", "Kansas", "Kentucky", "Louisiana", "Maine", "Maryland",
		"Massachusetts", "Michigan", "Minnesota", "Mississippi", "Missouri", "Montana", "Nebraska",
		"Nevada", "New Hampshire", "New Jersey", "New Mexico", "New York", "North Carolina",
		"North Dakota", "Ohio", "Oklahoma", "Oregon", "Pennsylvania", "Puerto Rico", "Rhode Island",
		"South Carolina", "South Dakota", "Tennessee", "Texas", "Utah", "Vermont", "Virgin Islands",
		"Virginia", "Washington", "West Virginia", "Wisconsin", "Wyoming", "New York City"}
	for i, s := range states {
		code := []byte{byte('0' + (i+1)/10), byte('0' + (i+1)%10)}
		m[string(code)] = "State: " + s
	}
	return m
}()

// Describe looks up code in table, returning "" when blank or unknown.
func Describe(table map[string]string, code string) string {
	if code == "" {
		return ""
	}
	return table[code]
}
