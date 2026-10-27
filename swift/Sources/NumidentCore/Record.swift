import Foundation

/// One line from a NUMIDENT file, kept as raw bytes and decoded on demand.
public struct NumidentRecord: Sendable, Identifiable, Hashable {
    public let kind: DatasetKind
    public let fileName: String
    /// Byte offset of the start of the line in its file.
    public let offset: Int64
    /// Line bytes without the CR/LF terminator.
    public let bytes: [UInt8]

    public init(kind: DatasetKind, fileName: String, offset: Int64, bytes: [UInt8]) {
        self.kind = kind
        self.fileName = fileName
        self.offset = offset
        self.bytes = bytes
    }

    public init(kind: DatasetKind, line: String, fileName: String = "", offset: Int64 = 0) {
        var b = Array(line.utf8)
        while let l = b.last, l == 10 || l == 13 { b.removeLast() }
        self.init(kind: kind, fileName: fileName, offset: offset, bytes: b)
    }

    public var id: String { "\(fileName):\(offset)" }
    public static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    public func hash(into h: inout Hasher) { h.combine(id) }

    public var rawLine: String { String(decoding: bytes, as: UTF8.self) }

    /// Raw text of a field, padded with spaces if the line was trimmed short.
    public func rawValue(_ f: FieldDef) -> String {
        let r = f.range
        var out = [UInt8](repeating: 32, count: f.length)
        if r.lowerBound < bytes.count {
            let end = min(r.upperBound, bytes.count)
            for i in r.lowerBound..<end { out[i - r.lowerBound] = bytes[i] }
        }
        return String(decoding: out, as: UTF8.self)
    }

    public func value(_ f: FieldDef) -> String {
        rawValue(f).trimmingCharacters(in: .whitespaces)
    }

    public func value(_ key: String) -> String {
        guard let f = Layouts.field(key, in: kind) else { return "" }
        return value(f)
    }

    public func date(_ key: String) -> PartialDate {
        guard let f = Layouts.field(key, in: kind) else { return .empty }
        let raw = rawValue(f)
        if raw.trimmingCharacters(in: .whitespaces).isEmpty { return .empty }
        switch f.type {
        case .dateMDY: return .mdy(raw)
        case .dateYMD: return .ymd(raw)
        case .text: return .empty
        }
    }

    /// Human-readable value including decoded code description.
    public func display(_ f: FieldDef) -> String {
        let v = value(f)
        switch f.type {
        case .dateMDY, .dateYMD:
            let d = date(f.key)
            return d.isEmpty ? v : "\(d) (\(v))"
        case .text:
            if let c = f.codes, let desc = c.describe(v) { return "\(v) – \(desc)" }
            return v
        }
    }

    // MARK: - Convenience accessors

    private var p: String { kind == .death ? "d1." : "" }

    public var ssn: String { value("ssn") }
    public var firstName: String { value(p + "first") }
    public var middleName: String { value(p + "middle") }
    public var lastName: String { value(p + "last") }
    public var suffix: String { value(p + "suffix") }
    public var fullName: String {
        [firstName, middleName, lastName, suffix].filter { !$0.isEmpty }.joined(separator: " ")
    }
    public var dob: PartialDate { date(p + "dob") }
    public var sexCode: String { value(p + "sex") }
    public var sex: String { Codes.sex.describe(sexCode) ?? sexCode }
    public var cycleDate: PartialDate { date("cycle") }
    public var entryCode: String { value("entry") }

    public var birthplace: String {
        guard kind != .death else { return "" }
        let city = value("pobCity"), st = value("pobState")
        let foreign = value("pobForeign") == "*" ? " (foreign)" : ""
        return [city, st].filter { !$0.isEmpty }.joined(separator: ", ") + foreign
    }

    public var fatherName: String {
        guard kind != .death else { return "" }
        return [value("fFirst"), value("fMiddle"), value("fLast"), value("fSuffix")]
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    public var motherName: String {
        guard kind != .death else { return "" }
        return [value("mFirst"), value("mMiddle"), value("mLast"), value("mSuffix")]
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Death date: first death posting for NUMDEATH, claim DOD for NUMCLM.
    public var deathDate: PartialDate {
        switch kind {
        case .death: return deathPostings.first?.dod ?? .empty
        case .claim: return date("dodClaim")
        case .ss5: return .empty
        }
    }

    /// The most informative event date for the results table.
    public var eventDate: PartialDate {
        switch kind {
        case .ss5: return cycleDate
        case .claim: return date("claimDate")
        case .death: return deathDate
        }
    }

    public var deathPostings: [DeathPosting] {
        guard kind == .death else { return [] }
        return (1...3).compactMap { DeathPosting(record: self, number: $0) }
    }
}

public struct DeathPosting: Sendable, Hashable {
    public let number: Int
    public let name: String
    public let dob: PartialDate
    public let sex: String
    public let dod: PartialDate
    public let source: String
    public let proof: String
    public let posted: PartialDate
    public let zipResidence: String
    public let certificate: String

    init?(record r: NumidentRecord, number p: Int) {
        let k = "d\(p)."
        let name = [r.value(k + "first"), r.value(k + "middle"), r.value(k + "last"), r.value(k + "suffix")]
            .filter { !$0.isEmpty }.joined(separator: " ")
        let dod = r.date(k + "dod")
        let posted = r.date(k + "posted")
        if name.isEmpty && dod.isEmpty && posted.isEmpty { return nil }
        self.number = p
        self.name = name
        self.dob = r.date(k + "dob")
        self.sex = r.value(k + "sex")
        self.dod = dod
        self.source = r.value(k + "source")
        self.proof = r.value(k + "proof")
        self.posted = posted
        self.zipResidence = r.value(k + "zipResidence")
        self.certificate = r.value(k + "cert")
    }
}
