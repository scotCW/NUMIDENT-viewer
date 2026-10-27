import Foundation

public enum NameMatch: String, CaseIterable, Sendable, Identifiable {
    case exact, prefix, soundex
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .exact: return "Exact"
        case .prefix: return "Starts with"
        case .soundex: return "Sounds like (Soundex)"
        }
    }
}

public enum SexFilter: String, CaseIterable, Sendable, Identifiable {
    case any, male, female, unknown
    public var id: String { rawValue }
    var code: UInt8? {
        switch self {
        case .any: return nil
        case .male: return 49
        case .female: return 50
        case .unknown: return 48
        }
    }
}

/// What the user typed into the search form.
public struct SearchQuery: Sendable, Equatable {
    public var ssn = ""
    public var firstName = ""
    public var middleName = ""
    public var lastName = ""
    public var nameMatch: NameMatch = .exact
    /// Also match SS-5 "other name" and "signature name" fields.
    public var includeOtherNames = false
    public var dobYearFrom: Int?
    public var dobYearTo: Int?
    public var deathYearFrom: Int?
    public var deathYearTo: Int?
    public var pobCity = ""
    public var pobState = ""
    public var fatherFirst = ""
    public var fatherLast = ""
    public var motherFirst = ""
    public var motherLast = ""
    public var sex: SexFilter = .any

    public init() {}

    public static func ssn(_ s: String) -> SearchQuery {
        var q = SearchQuery()
        q.ssn = s
        return q
    }

    static func clean(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    public var normalizedSSN: String { ssn.filter(\.isNumber) }
    public var hasValidSSN: Bool { normalizedSSN.count == 9 }

    var hasName: Bool { !(Self.clean(firstName) + Self.clean(middleName) + Self.clean(lastName)).isEmpty }
    var hasDeath: Bool { deathYearFrom != nil || deathYearTo != nil }
    var hasBirthplace: Bool { !Self.clean(pobCity).isEmpty || !Self.clean(pobState).isEmpty }
    var hasParents: Bool {
        !(Self.clean(fatherFirst) + Self.clean(fatherLast) + Self.clean(motherFirst) + Self.clean(motherLast)).isEmpty
    }

    public var isEmpty: Bool {
        normalizedSSN.isEmpty && !hasName && dobYearFrom == nil && dobYearTo == nil && !hasDeath
            && !hasBirthplace && !hasParents && sex == .any
    }

    /// Record sets whose layout contains every field the query uses.
    public var applicableKinds: Set<DatasetKind> {
        var k = Set(DatasetKind.allCases)
        if hasDeath { k.remove(.ss5) }
        if hasBirthplace || hasParents { k.remove(.death) }
        return k
    }

    /// Explains why sets were dropped, for display.
    public var skippedReasons: [DatasetKind: String] {
        var out: [DatasetKind: String] = [:]
        if hasDeath { out[.ss5] = "SS-5 records have no death date" }
        if hasBirthplace || hasParents { out[.death] = "Death records have no birthplace or parents" }
        return out
    }

    public func validate() -> String? {
        if isEmpty { return "Enter at least one search field." }
        if !normalizedSSN.isEmpty && !hasValidSSN { return "SSN must have 9 digits." }
        if !Self.clean(pobState).isEmpty && Self.clean(pobState).count != 2 {
            return "Birth state/country is a 2-letter code."
        }
        return nil
    }
}

/// Byte-level matcher built from a `SearchQuery`. Works directly on line buffers,
/// so non-matching lines are rejected without any allocation.
public struct CompiledQuery: Sendable {
    struct NameGroup: Sendable { let first: Int; let middle: Int; let last: Int }

    enum Term: Sendable {
        case none
        case text([UInt8])
        case soundex(UInt32)
    }

    let ssn: [UInt8]?
    let first: Term, middle: Term, last: Term
    let fatherFirst: Term, fatherLast: Term, motherFirst: Term, motherLast: Term
    let pobCity: [UInt8]?
    let pobState: [UInt8]?
    let dobRange: ClosedRange<Int>?
    let deathRange: ClosedRange<Int>?
    let sex: UInt8?
    let includeOtherNames: Bool
    let mode: NameMatch

    public init(_ q: SearchQuery) {
        mode = q.nameMatch
        includeOtherNames = q.includeOtherNames
        let s = q.normalizedSSN
        ssn = s.isEmpty ? nil : Array(s.utf8)
        func term(_ s: String) -> Term {
            let c = SearchQuery.clean(s)
            if c.isEmpty { return .none }
            if q.nameMatch == .soundex {
                let code = Soundex.code(c)
                return code == 0 ? .text(Array(c.utf8)) : .soundex(code)
            }
            return .text(Array(c.utf8))
        }
        first = term(q.firstName)
        middle = term(q.middleName)
        last = term(q.lastName)
        fatherFirst = term(q.fatherFirst)
        fatherLast = term(q.fatherLast)
        motherFirst = term(q.motherFirst)
        motherLast = term(q.motherLast)
        let city = SearchQuery.clean(q.pobCity)
        pobCity = city.isEmpty ? nil : Array(city.utf8)
        let st = SearchQuery.clean(q.pobState)
        pobState = st.isEmpty ? nil : Array(st.utf8)
        func range(_ a: Int?, _ b: Int?) -> ClosedRange<Int>? {
            if a == nil && b == nil { return nil }
            let lo = a ?? 0, hi = b ?? 9999
            return min(lo, hi)...max(lo, hi)
        }
        dobRange = range(q.dobYearFrom, q.dobYearTo)
        deathRange = range(q.deathYearFrom, q.deathYearTo)
        sex = q.sex.code
    }

    public var ssnBytes: [UInt8]? { ssn }

    // 0-based column starts.
    private static let nh = NameGroup(first: 36, middle: 52, last: 68)
    private static let other = NameGroup(first: 236, middle: 252, last: 268)
    private static let signature = NameGroup(first: 296, middle: 312, last: 328)
    private static let stride = Layouts.deathPostingStride

    @inline(__always)
    public func matches(_ line: UnsafeBufferPointer<UInt8>, kind: DatasetKind) -> Bool {
        if let ssn {
            guard Self.equalsRaw(line, 12, ssn) else { return false }
        }
        if let sex {
            switch kind {
            case .death:
                var ok = false
                for p in 0..<3 where Self.byte(line, 104 + p * Self.stride) == sex { ok = true; break }
                if !ok { return false }
            default:
                guard Self.byte(line, 104) == sex else { return false }
            }
        }
        if let dobRange {
            if kind == .death {
                var ok = false
                for p in 0..<3 {
                    if let y = Self.year(line, 100 + p * Self.stride), dobRange.contains(y) { ok = true; break }
                }
                if !ok { return false }
            } else {
                guard let y = Self.year(line, 100), dobRange.contains(y) else { return false }
            }
        }
        if let deathRange {
            switch kind {
            case .ss5:
                return false
            case .claim:
                guard let y = Self.year(line, 301), deathRange.contains(y) else { return false }
            case .death:
                var ok = false
                for p in 0..<3 {
                    if let y = Self.year(line, 148 + p * Self.stride), deathRange.contains(y) { ok = true; break }
                }
                if !ok { return false }
            }
        }
        if kind != .death {
            if let pobCity, !Self.hasPrefix(line, 220, 12, pobCity) { return false }
            if let pobState, !Self.equalsTrimmed(line, 233, 2, pobState) { return false }
            if !matchTerm(fatherFirst, line, 163, 15) { return false }
            if !matchTerm(fatherLast, line, 195, 20) { return false }
            if !matchTerm(motherFirst, line, 106, 15) { return false }
            if !matchTerm(motherLast, line, 138, 20) { return false }
        } else if pobCity != nil || pobState != nil || !isNone(fatherFirst) || !isNone(fatherLast)
                    || !isNone(motherFirst) || !isNone(motherLast) {
            return false
        }
        if isNone(first) && isNone(middle) && isNone(last) { return true }
        switch kind {
        case .ss5:
            if matchName(line, Self.nh) { return true }
            if includeOtherNames {
                return matchName(line, Self.other) || matchName(line, Self.signature)
            }
            return false
        case .claim:
            return matchName(line, Self.nh)
        case .death:
            for p in 0..<3 {
                let o = p * Self.stride
                if matchName(line, NameGroup(first: 36 + o, middle: 52 + o, last: 68 + o)) { return true }
            }
            return false
        }
    }

    public func matches(_ record: NumidentRecord) -> Bool {
        record.bytes.withUnsafeBufferPointer { matches($0, kind: record.kind) }
    }

    @inline(__always)
    private func isNone(_ t: Term) -> Bool {
        if case .none = t { return true }
        return false
    }

    @inline(__always)
    private func matchName(_ line: UnsafeBufferPointer<UInt8>, _ g: NameGroup) -> Bool {
        matchTerm(first, line, g.first, 15) && matchTerm(middle, line, g.middle, 15)
            && matchTerm(last, line, g.last, 20)
    }

    @inline(__always)
    private func matchTerm(_ t: Term, _ line: UnsafeBufferPointer<UInt8>, _ start: Int, _ len: Int) -> Bool {
        switch t {
        case .none:
            return true
        case .text(let q):
            return mode == .prefix ? Self.hasPrefix(line, start, len, q) : Self.equalsTrimmed(line, start, len, q)
        case .soundex(let code):
            let r = Self.trimmed(line, start, len)
            if r.isEmpty { return false }
            return Soundex.code(line, r) == code
        }
    }

    // MARK: - Byte helpers (columns beyond the trimmed line end read as spaces)

    @inline(__always)
    static func byte(_ line: UnsafeBufferPointer<UInt8>, _ i: Int) -> UInt8 {
        i < line.count ? line[i] : 32
    }

    @inline(__always)
    static func upper(_ c: UInt8) -> UInt8 { (c >= 97 && c <= 122) ? c - 32 : c }

    @inline(__always)
    static func trimmed(_ line: UnsafeBufferPointer<UInt8>, _ start: Int, _ len: Int) -> Range<Int> {
        var lo = start
        var hi = min(start + len, line.count)
        if lo >= hi { return lo..<lo }
        while lo < hi && line[lo] == 32 { lo += 1 }
        while hi > lo && line[hi - 1] == 32 { hi -= 1 }
        return lo..<hi
    }

    @inline(__always)
    static func equalsRaw(_ line: UnsafeBufferPointer<UInt8>, _ start: Int, _ q: [UInt8]) -> Bool {
        guard start + q.count <= line.count else { return false }
        for i in 0..<q.count where line[start + i] != q[i] { return false }
        return true
    }

    @inline(__always)
    static func equalsTrimmed(_ line: UnsafeBufferPointer<UInt8>, _ start: Int, _ len: Int, _ q: [UInt8]) -> Bool {
        let r = trimmed(line, start, len)
        guard r.count == q.count else { return false }
        var j = 0
        for i in r {
            if upper(line[i]) != q[j] { return false }
            j += 1
        }
        return true
    }

    @inline(__always)
    static func hasPrefix(_ line: UnsafeBufferPointer<UInt8>, _ start: Int, _ len: Int, _ q: [UInt8]) -> Bool {
        let r = trimmed(line, start, len)
        guard r.count >= q.count else { return false }
        var i = r.lowerBound
        for c in q {
            if upper(line[i]) != c { return false }
            i += 1
        }
        return true
    }

    /// Reads a 4-digit year at a 0-based column, nil if not all digits or zero.
    @inline(__always)
    static func year(_ line: UnsafeBufferPointer<UInt8>, _ start: Int) -> Int? {
        guard start + 4 <= line.count else { return nil }
        var v = 0
        for i in start..<(start + 4) {
            let c = line[i]
            guard c >= 48 && c <= 57 else { return nil }
            v = v * 10 + Int(c - 48)
        }
        return v == 0 ? nil : v
    }
}
