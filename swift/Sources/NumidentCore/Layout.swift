import Foundation

/// The three NUMIDENT record sets in NARA's public-use release.
public enum DatasetKind: String, CaseIterable, Sendable, Codable, Hashable, Identifiable, Comparable {
    case ss5 = "NUMSS5"
    case claim = "NUMCLM"
    case death = "NUMDEATH"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .ss5: return "SS-5 applications"
        case .claim: return "Claims"
        case .death: return "Deaths"
        }
    }

    public var shortTitle: String {
        switch self {
        case .ss5: return "SS-5"
        case .claim: return "Claim"
        case .death: return "Death"
        }
    }

    /// Characters per record line, excluding the terminator (verified on the real files).
    public var lineLength: Int {
        switch self {
        case .ss5: return 500
        case .claim: return 499
        case .death: return 487
        }
    }

    /// NUMDEATH lines end in CRLF; NUMSS5 and NUMCLM lines end in LF.
    public var usesCRLF: Bool { self == .death }

    /// Bytes per record including the line terminator: 501 / 500 / 489.
    public var recordSize: Int { lineLength + (usesCRLF ? 2 : 1) }

    /// NARA ships each set as files 01...20.
    public static let expectedFileNumbers = Array(1...20)

    private var order: Int {
        switch self {
        case .ss5: return 0
        case .claim: return 1
        case .death: return 2
        }
    }

    public static func < (a: DatasetKind, b: DatasetKind) -> Bool { a.order < b.order }
}

public enum FieldType: Sendable {
    case text
    /// MMDDCCYY, components may be "XX" or "00" when unknown.
    case dateMDY
    /// CCYYMMDD, components may be "XX" or "00" when unknown.
    case dateYMD
}

/// One fixed-width field. `start` is 1-based and inclusive, as in the NARA layout PDFs.
public struct FieldDef: Sendable, Identifiable, Hashable {
    public let key: String
    public let label: String
    public let start: Int
    public let length: Int
    public let type: FieldType
    public let codes: CodeTable?
    public let group: String

    public var id: String { key }
    public var end: Int { start + length - 1 }
    /// 0-based byte range.
    public var range: Range<Int> { (start - 1)..<(start - 1 + length) }

    public init(_ key: String, _ label: String, _ start: Int, _ end: Int,
                _ type: FieldType = .text, codes: CodeTable? = nil, group: String) {
        self.key = key
        self.label = label
        self.start = start
        self.length = end - start + 1
        self.type = type
        self.codes = codes
        self.group = group
    }

    public static func == (a: FieldDef, b: FieldDef) -> Bool { a.key == b.key && a.start == b.start }
    public func hash(into h: inout Hasher) { h.combine(key); h.combine(start) }
}

/// Field layouts transcribed from NARA's AAD technical documentation
/// (rg047_num_ss5_layout.pdf, rg047_num_claim_layout.pdf, rg047_num_dth_layout.pdf).
public enum Layouts {
    public static func fields(for kind: DatasetKind) -> [FieldDef] {
        switch kind {
        case .ss5: return ss5
        case .claim: return claim
        case .death: return death
        }
    }

    public static func field(_ key: String, in kind: DatasetKind) -> FieldDef? {
        index[kind]?[key]
    }

    private static let index: [DatasetKind: [String: FieldDef]] = {
        var out: [DatasetKind: [String: FieldDef]] = [:]
        for kind in DatasetKind.allCases {
            out[kind] = Dictionary(fields(for: kind).map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        }
        return out
    }()

    private static let id = "Identification"
    private static let nh = "Number holder"
    private static let parents = "Parents"
    private static let birth = "Birth"
    private static let admin = "Administrative"

    private static func nameFields(group: String) -> [FieldDef] {
        [
            FieldDef("first", "First name", 37, 51, group: group),
            FieldDef("firstOflo", "First name overflow", 52, 52, codes: Codes.overflow, group: group),
            FieldDef("middle", "Middle name", 53, 67, group: group),
            FieldDef("middleOflo", "Middle name overflow", 68, 68, codes: Codes.overflow, group: group),
            FieldDef("last", "Last name", 69, 88, group: group),
            FieldDef("lastOflo", "Last name overflow", 89, 89, codes: Codes.overflow, group: group),
            FieldDef("suffix", "Suffix", 90, 93, group: group),
        ]
    }

    private static func parentAndBirthFields() -> [FieldDef] {
        [
            FieldDef("mFirst", "Mother first name", 107, 121, group: parents),
            FieldDef("mMiddle", "Mother middle name", 123, 137, group: parents),
            FieldDef("mLast", "Mother last name", 139, 158, group: parents),
            FieldDef("mSuffix", "Mother suffix", 160, 163, group: parents),
            FieldDef("fFirst", "Father first name", 164, 178, group: parents),
            FieldDef("fMiddle", "Father middle name", 180, 194, group: parents),
            FieldDef("fLast", "Father last name", 196, 215, group: parents),
            FieldDef("fSuffix", "Father suffix", 217, 220, group: parents),
            FieldDef("pobCity", "Birth city/county", 221, 232, group: birth),
            FieldDef("pobCityOflo", "Birth city overflow", 233, 233, group: birth),
            FieldDef("pobState", "Birth state/country", 234, 235, group: birth),
            FieldDef("pobForeign", "Foreign born", 236, 236, codes: Codes.foreign, group: birth),
        ]
    }

    public static let ss5: [FieldDef] = {
        var f: [FieldDef] = [
            FieldDef("ref", "Reference number", 1, 11, group: id),
            FieldDef("interview", "Interview code", 12, 12, codes: Codes.interview, group: id),
            FieldDef("ssn", "SSN", 13, 21, group: id),
            FieldDef("citizenship", "Citizenship", 22, 22, codes: Codes.citizenship, group: id),
            FieldDef("doCode", "Office code", 23, 25, group: admin),
            FieldDef("form", "Form code", 26, 26, codes: Codes.form, group: admin),
            FieldDef("entry", "Entry code", 27, 27, codes: Codes.entry, group: admin),
            FieldDef("print", "Print code", 28, 28, codes: Codes.print, group: admin),
            FieldDef("cycle", "Cycle date", 29, 36, .dateYMD, group: admin),
        ]
        f += nameFields(group: nh)
        f += [
            FieldDef("dob", "Date of birth", 97, 104, .dateMDY, group: birth),
            FieldDef("sex", "Sex", 105, 105, codes: Codes.sex, group: nh),
            FieldDef("race", "Race/ethnicity", 106, 106, codes: Codes.race, group: nh),
        ]
        f += parentAndBirthFields()
        f += [
            FieldDef("oFirst", "Other first name", 237, 251, group: "Other name"),
            FieldDef("oMiddle", "Other middle name", 253, 267, group: "Other name"),
            FieldDef("oLast", "Other last name", 269, 288, group: "Other name"),
            FieldDef("oSuffix", "Other suffix", 290, 293, group: "Other name"),
            FieldDef("sFirst", "Signature first name", 297, 311, group: "Signature name"),
            FieldDef("sMiddle", "Signature middle name", 313, 327, group: "Signature name"),
            FieldDef("sLast", "Signature last name", 329, 348, group: "Signature name"),
            FieldDef("sSuffix", "Signature suffix", 350, 353, group: "Signature name"),
            FieldDef("sigCode", "Signature code", 354, 354, codes: Codes.signature, group: admin),
            FieldDef("notify", "Notify code", 358, 359, group: admin),
            FieldDef("card", "Card code", 360, 360, codes: Codes.card, group: admin),
            FieldDef("dib", "Disability (DIB/freeze)", 361, 361, codes: Codes.dib, group: admin),
            FieldDef("dobChanged", "DOB changed", 362, 362, codes: Codes.dobChanged, group: birth),
            FieldDef("priorDob", "Prior date of birth", 363, 370, .dateMDY, group: birth),
            FieldDef("corr", "Correspondence code", 371, 372, group: admin),
            FieldDef("birthCert", "Birth certificate number", 373, 383, group: birth),
            FieldDef("alienReg", "Alien registration number", 386, 400, group: id),
            FieldDef("controlNum", "Card control number", 413, 421, group: admin),
            FieldDef("diffReason", "Different number reason", 497, 497, codes: Codes.diffReason, group: admin),
            FieldDef("conversion", "Conversion record", 498, 498, codes: Codes.conversion, group: admin),
            FieldDef("subcode", "Entry subcode", 499, 499, codes: Codes.subcode, group: admin),
            FieldDef("deleteFlag", "Delete flag", 500, 500, codes: Codes.deleteFlag, group: admin),
        ]
        return f
    }()

    public static let claim: [FieldDef] = {
        var f: [FieldDef] = [
            FieldDef("ref", "Reference number", 1, 11, group: id),
            FieldDef("ssn", "SSN", 13, 21, group: id),
            FieldDef("doCode", "Office code", 23, 25, group: admin),
            FieldDef("form", "Form code", 26, 26, group: admin),
            FieldDef("entry", "Entry code", 27, 27, codes: Codes.entry, group: admin),
            FieldDef("cycle", "Cycle date", 29, 36, .dateYMD, group: admin),
        ]
        f += nameFields(group: nh)
        f += [
            FieldDef("dob", "Date of birth", 97, 104, .dateMDY, group: birth),
            FieldDef("sex", "Sex", 105, 105, codes: Codes.sex, group: nh),
        ]
        f += parentAndBirthFields()
        f += [
            FieldDef("doAddress", "Field office address", 237, 281, group: "Claim"),
            FieldDef("claimDate", "Claim filed", 282, 289, .dateMDY, group: "Claim"),
            FieldDef("onsetDate", "Date of onset", 290, 297, .dateMDY, group: "Claim"),
            FieldDef("dodClaim", "Date of death (claim)", 298, 305, .dateMDY, group: "Claim"),
            FieldDef("conversion", "Conversion record", 498, 498, codes: Codes.conversion, group: admin),
            FieldDef("deleteFlag", "Delete flag", 500, 500, codes: Codes.deleteFlag, group: admin),
        ]
        return f
    }()

    /// Offset in bytes between the three repeating death postings.
    public static let deathPostingStride = 150

    public static func deathPostingFields(_ p: Int) -> [FieldDef] {
        let o = (p - 1) * deathPostingStride
        let g = "Death posting \(p)"
        let k = "d\(p)."
        return [
            FieldDef(k + "first", "First name", 37 + o, 51 + o, group: g),
            FieldDef(k + "firstOflo", "First name overflow", 52 + o, 52 + o, codes: Codes.overflow, group: g),
            FieldDef(k + "middle", "Middle name", 53 + o, 67 + o, group: g),
            FieldDef(k + "middleOflo", "Middle name overflow", 68 + o, 68 + o, codes: Codes.overflow, group: g),
            FieldDef(k + "last", "Last name", 69 + o, 88 + o, group: g),
            FieldDef(k + "lastOflo", "Last name overflow", 89 + o, 89 + o, codes: Codes.overflow, group: g),
            FieldDef(k + "suffix", "Suffix", 90 + o, 93 + o, group: g),
            FieldDef(k + "dob", "Date of birth", 97 + o, 104 + o, .dateMDY, group: g),
            FieldDef(k + "sex", "Sex", 105 + o, 105 + o, codes: Codes.sex, group: g),
            FieldDef(k + "otherNum", "Other number (CAN/HUN)", 107 + o, 115 + o, group: g),
            FieldDef(k + "recordId", "Record ID code", 116 + o, 116 + o, codes: Codes.recordId, group: g),
            FieldDef(k + "proof", "Proof of death", 117 + o, 117 + o, codes: Codes.proofOfDeath, group: g),
            FieldDef(k + "program", "Program involvement", 118 + o, 118 + o, codes: Codes.program, group: g),
            FieldDef(k + "zipResidence", "Residence ZIP", 119 + o, 127 + o, group: g),
            FieldDef(k + "zipLumpSum", "Lump-sum ZIP", 128 + o, 136 + o, group: g),
            FieldDef(k + "dobEx", "DOB exception", 137 + o, 137 + o, group: g),
            FieldDef(k + "exceptChange", "Exception change", 138 + o, 138 + o, group: g),
            FieldDef(k + "mbrDobEx", "MBR DOB exception", 139 + o, 139 + o, group: g),
            FieldDef(k + "source", "Source of death", 142 + o, 143 + o, codes: Codes.sourceOfDeath, group: g),
            FieldDef(k + "edr", "Verified EDR", 144 + o, 144 + o, codes: Codes.edr, group: g),
            FieldDef(k + "dod", "Date of death", 145 + o, 152 + o, .dateMDY, group: g),
            FieldDef(k + "cert", "Death certificate number", 153 + o, 178 + o, group: g),
            FieldDef(k + "posted", "Death posting date", 179 + o, 186 + o, .dateYMD, group: g),
        ]
    }

    public static let death: [FieldDef] = {
        var f: [FieldDef] = [
            FieldDef("ref", "Reference number", 1, 11, group: id),
            FieldDef("ssn", "SSN", 13, 21, group: id),
            FieldDef("entry", "Entry code", 27, 27, codes: Codes.entry, group: admin),
            FieldDef("cycle", "Cycle date", 29, 36, .dateYMD, group: admin),
        ]
        for p in 1...3 { f += deathPostingFields(p) }
        f.append(FieldDef("noe", "Number of death postings", 487, 487, group: admin))
        return f
    }()
}
