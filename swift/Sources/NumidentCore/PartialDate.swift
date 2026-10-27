import Foundation

/// A date where any component may be unknown ("XX", "00" or blank in the source data).
public struct PartialDate: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let year: Int?
    public let month: Int?
    public let day: Int?
    public let raw: String

    public init(year: Int?, month: Int?, day: Int?, raw: String) {
        self.year = year
        self.month = month
        self.day = day
        self.raw = raw
    }

    public static let empty = PartialDate(year: nil, month: nil, day: nil, raw: "")

    /// `MMDDCCYY`
    public static func mdy(_ s: String) -> PartialDate {
        let b = Array(s.utf8)
        guard b.count == 8 else { return PartialDate(year: nil, month: nil, day: nil, raw: s) }
        return PartialDate(year: number(b[4..<8], 1, 9999),
                           month: number(b[0..<2], 1, 12),
                           day: number(b[2..<4], 1, 31), raw: s)
    }

    /// `CCYYMMDD`
    public static func ymd(_ s: String) -> PartialDate {
        let b = Array(s.utf8)
        guard b.count == 8 else { return PartialDate(year: nil, month: nil, day: nil, raw: s) }
        return PartialDate(year: number(b[0..<4], 1, 9999),
                           month: number(b[4..<6], 1, 12),
                           day: number(b[6..<8], 1, 31), raw: s)
    }

    private static func number(_ s: ArraySlice<UInt8>, _ lo: Int, _ hi: Int) -> Int? {
        var v = 0
        for c in s {
            guard c >= 48 && c <= 57 else { return nil }
            v = v * 10 + Int(c - 48)
        }
        return (lo...hi).contains(v) ? v : nil
    }

    public var isEmpty: Bool { year == nil && month == nil && day == nil }
    public var isComplete: Bool { year != nil && month != nil && day != nil }

    /// ISO-like text with `??` for unknown parts, e.g. `1974-06-??`.
    public var description: String {
        if isEmpty { return raw.trimmingCharacters(in: .whitespaces).isEmpty ? "" : "?(\(raw))" }
        let y = year.map { String(format: "%04d", $0) } ?? "????"
        let m = month.map { String(format: "%02d", $0) } ?? "??"
        let d = day.map { String(format: "%02d", $0) } ?? "??"
        return "\(y)-\(m)-\(d)"
    }

    /// Sort key: unknown parts sort first within their parent.
    public var sortKey: Int { (year ?? 0) * 10_000 + (month ?? 0) * 100 + (day ?? 0) }

    public static func < (a: PartialDate, b: PartialDate) -> Bool { a.sortKey < b.sortKey }

    /// True when the known components of both dates agree.
    public func isCompatible(with other: PartialDate) -> Bool {
        func ok(_ a: Int?, _ b: Int?) -> Bool { a == nil || b == nil || a == b }
        return ok(year, other.year) && ok(month, other.month) && ok(day, other.day)
    }

    public static func == (a: PartialDate, b: PartialDate) -> Bool {
        a.year == b.year && a.month == b.month && a.day == b.day
    }

    public func hash(into h: inout Hasher) {
        h.combine(year); h.combine(month); h.combine(day)
    }
}
