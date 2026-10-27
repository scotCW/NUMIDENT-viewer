import Foundation

/// A code → description table from the NARA layout documentation.
public struct CodeTable: Sendable {
    public let name: String
    public let values: [String: String]

    public init(_ name: String, _ values: [String: String]) {
        self.name = name
        self.values = values
    }

    public func describe(_ code: String) -> String? {
        let key = code.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        return values[key]
    }
}

public enum Codes {
    public static let overflow = CodeTable("Overflow", ["*": "Overflow"])
    public static let foreign = CodeTable("Foreign born", ["*": "Foreign born"])
    public static let dobChanged = CodeTable("DOB changed", ["*": "Applicant's DOB corrected"])
    public static let deleteFlag = CodeTable("Delete flag", ["F": "Record logically deleted"])

    public static let sex = CodeTable("Sex", ["0": "Unknown", "1": "Male", "2": "Female"])

    public static let race = CodeTable("Race", [
        "0": "Unknown", "1": "White", "2": "Black", "3": "Other",
        "4": "Asian", "5": "Hispanic", "6": "North American native",
    ])

    public static let interview = CodeTable("Interview code", [
        "A": "Alien temporarily allowed to work during legalization",
        "B": "Alien not allowed to work; birth record before age 5",
        "C": "Evidence other than birth record; citizen or alien allowed to work",
        "D": "Duplicate request; evidence of identity only",
        "E": "Special IRS project (tax year 1977)",
        "H": "Permanent resident alien",
        "I": "Alien not in status",
        "N": "Alien not authorized to work",
        "P": "Birth record established before age 5",
        "R": "Foreign student authorized for restricted employment",
        "X": "U.S. born, not U.S. citizen; not allowed to work",
        "Y": "U.S. born, not U.S. citizen; not allowed to work; birth record before age 5",
    ])

    public static let citizenship = CodeTable("Citizenship", [
        "A": "U.S. citizen",
        "B": "Legal alien authorized to work",
        "C": "Legal alien not authorized to work",
        "D": "Other",
        "E": "Alien student, restricted work authorized",
        "F": "Conditionally legalized alien",
    ])

    public static let form = CodeTable("Form code", [
        "A": "Enumeration at Entry (EAE)",
        "C": "Automated, integrated client process",
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
    ])

    public static let entry = CodeTable("Entry code", [
        "0": "Original SSN",
        "2": "Duplicate SSN: change or replacement",
        "4": "Reestablish void SSN",
        "E": "Special indicator (SPIN)",
        "J": "New account (emergency issue number)",
        "Q": "Correspondence",
        "V": "Voided SSN",
        "1": "Change in DOB",
        "5": "Sex correction",
        "9": "Internal correction",
        "G": "Generated from ERF, MBR or MULTX data",
        "K": "Duplicate: name change",
        "P": "Change identifying information",
        "S": "Supporting application",
        "W": "Welfare request",
        "L": "Life claim",
        "D": "Death claim",
        "T": "Death entry",
    ])

    public static let print = CodeTable("Print code", [
        "2": "'MRS.' shown with husband's name",
        "3": "'SISTER' with male first name",
        "4": "'SISTER' with female first name",
        "8": "Full name printed / compound name",
    ])

    public static let signature = CodeTable("Signature code", [
        "P": "Parent's signature",
        "S": "Client's signature",
        "D": "Not signed, SSA prepared",
        "E": "Signature name from correspondence",
        "F": "Signed in foreign characters",
        "I": "Signature name from IRS form 3912",
        "K": "Signature name differs from NH's name",
        "O": "Signed by other than applicant",
        "R": "Signature name from RRB form",
        "U": "Not signed",
        "W": "Amish waiver (form 4029)",
        "X": "Signed by mark, with witnesses",
    ])

    public static let card = CodeTable("Card code", ["N": "SSN card not printed", "Y": "SSN card printed"])

    public static let dib = CodeTable("Disability status", [
        "/": "DIB established",
        "A": "DIB established, prior termination",
        "B": "Freeze established, prior termination",
        "D": "DAC established, prior termination",
        "J": "DIB terminated",
        "K": "Freeze terminated",
        "M": "DAC terminated",
        "P": "Disability terminated, no record of type",
        "Q": "DIB terminated for statutory blind",
        "S": "Freeze established",
        "U": "DAC established",
        "1": "Disability established, no record of type",
        "2": "Disability denied, no record of type",
        "3": "Disability terminated, no record of type",
        "8": "DIB established for statutory blind",
    ])

    public static let diffReason = CodeTable("Different number reason", [
        "A": "Sequential SSNs, same family",
        "B": "Scrambled earnings",
        "C": "Wrong number case",
        "D": "Religious or cultural objection",
        "E": "SSN misuse and disadvantage",
        "F": "Harassment, abuse, life endangerment",
        "N": "Not requested",
    ])

    public static let conversion = CodeTable("Conversion record", [
        "A": "Conversion record added to ALPHIDENT and NUMIDENT",
        "C": "Conversion record added to NUMIDENT; not on ALPHIDENT",
        "F": "Not a conversion record; full Enumeration System",
        "I": "Not a conversion record; interim Enumeration System",
        "K": "Conversion record; passed high-group test; not on ALPHIDENT",
        "M": "Conversion record with MULTX cross-reference",
        "X": "Conversion record with multiple-SSN cross-reference",
    ])

    public static let subcode = CodeTable("Entry subcode", [
        "D": "0,2 entry 1998–2002",
        "E": "Generated from ERF data",
        "M": "Generated from Title II MBR data",
        "R": "J,4 entry special AESP processing",
        "W": "S,0,2 entry Metro West override",
        "X": "Generated from MULTX cross-reference",
        "J": "Unassigned number from emergency block",
    ])

    public static let recordId = CodeTable("Record ID code", [
        "1": "MBR primary beneficiary",
        "2": "MBR auxiliary beneficiary",
        "3": "SSI recipient",
        "4": "Black Lung beneficiary",
        "5": "MEF master file only",
        "6": "External source (e.g. state death records)",
    ])

    public static let proofOfDeath = CodeTable("Proof of death", [
        "P": "Proven / verified",
        "V": "Verified",
        "N": "Non-verified",
        "S": "Payment alert",
    ])

    public static let program = CodeTable("Program involvement", [
        "A": "Title II only",
        "B": "Title XVI only",
        "C": "Black Lung only",
        "D": "Railroad Board only",
        "E": "Title II and Title XVI",
        "F": "Title II and Black Lung",
        "G": "Title II and Railroad Board",
        "H": "Title II, Title XVI and Black Lung",
        "I": "Title II, Title XVI, Black Lung and Railroad Board",
        "J": "Title XVI and Black Lung",
    ])

    public static let edr = CodeTable("Verified EDR", ["Y": "Yes", "N": "No", "O": "Override"])

    public static let sourceOfDeath: CodeTable = {
        var v: [String: String] = [
            "BX": "BENDEX (Title II data exchange)",
            "FO": "Field office",
            "HC": "CMS (formerly HCFA)",
            "PE": "Post-entitlement (Title II)",
            "SI": "Title XVI system",
            "VA": "Department of Veterans Affairs",
            "CS": "Civil Service",
            "DC": "Death certificate",
            "DD": "Department of Defense",
            "DL": "Department of Labor",
            "HI": "HCFA (uninsured)",
            "RB": "Railroad Retirement Board",
            "54": "New York City",
            "55": "Asia",
            "56": "Canada",
            "57": "Central America and the West Indies",
            "58": "Europe",
            "59": "Mexico",
            "60": "Oceania",
            "61": "Philippines",
            "62": "South America",
            "63": "Trust territories",
            "64": "American Samoa",
            "65": "Guam",
            "70": "Field office (SSA-704)",
            "72": "Field office (SSA-704)",
        ]
        let states = [
            "Alabama", "Alaska", "Arizona", "Arkansas", "California", "Colorado", "Connecticut",
            "Delaware", "District of Columbia", "Florida", "Georgia", "Hawaii", "Idaho", "Illinois",
            "Indiana", "Iowa", "Kansas", "Kentucky", "Louisiana", "Maine", "Maryland", "Massachusetts",
            "Michigan", "Minnesota", "Mississippi", "Missouri", "Montana", "Nebraska", "Nevada",
            "New Hampshire", "New Jersey", "New Mexico", "New York", "North Carolina", "North Dakota",
            "Ohio", "Oklahoma", "Oregon", "Pennsylvania", "Puerto Rico", "Rhode Island",
            "South Carolina", "South Dakota", "Tennessee", "Texas", "Utah", "Vermont",
            "Virgin Islands", "Virginia", "Washington", "West Virginia", "Wisconsin", "Wyoming",
        ]
        for (i, s) in states.enumerated() { v[String(format: "%02d", i + 1)] = "State: \(s)" }
        return CodeTable("Source of death", v)
    }()
}
