import Foundation

/// American Soundex, computed directly on ASCII bytes so the scanner never allocates.
public enum Soundex {
    /// Code for each uppercase letter A–Z; 0 = vowel/ignored, 7 = H/W (transparent).
    private static let table: [UInt8] = {
        var t = [UInt8](repeating: 0, count: 26)
        func set(_ letters: String, _ v: UInt8) {
            for c in letters.utf8 { t[Int(c - 65)] = v }
        }
        set("BFPV", 1); set("CGJKQSXZ", 2); set("DT", 3); set("L", 4); set("MN", 5); set("R", 6)
        set("HW", 7)
        return t
    }()

    /// Packed code: first letter in the top byte, then three digit bytes. 0 when no letters.
    @inline(__always)
    public static func code(_ p: UnsafeBufferPointer<UInt8>, _ range: Range<Int>) -> UInt32 {
        var out: UInt32 = 0
        var n = 0
        var last: UInt8 = 0
        var i = range.lowerBound
        while i < range.upperBound && n < 4 {
            var c = p[i]
            i += 1
            if c >= 97 && c <= 122 { c -= 32 }
            guard c >= 65 && c <= 90 else { continue }
            let v = table[Int(c - 65)]
            if n == 0 {
                out = UInt32(c) << 24
                n = 1
                last = v == 7 ? 0 : v
                continue
            }
            if v == 7 { continue }          // H, W: keep previous code
            if v == 0 { last = 0; continue } // vowel separates
            if v != last {
                out |= UInt32(48 + v) << UInt32(8 * (3 - n))
                n += 1
            }
            last = v
        }
        if n == 0 { return 0 }
        while n < 4 {
            out |= UInt32(48) << UInt32(8 * (3 - n))
            n += 1
        }
        return out
    }

    public static func code(_ s: String) -> UInt32 {
        let b = Array(s.utf8)
        return b.withUnsafeBufferPointer { code($0, 0..<b.count) }
    }

    public static func string(_ s: String) -> String {
        let c = code(s)
        guard c != 0 else { return "" }
        let bytes = [UInt8(c >> 24), UInt8((c >> 16) & 0xFF), UInt8((c >> 8) & 0xFF), UInt8(c & 0xFF)]
        return String(decoding: bytes, as: UTF8.self)
    }
}
