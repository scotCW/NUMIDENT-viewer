import Foundation

/// Builds one fixed-width line: 500 spaces, fields placed at 1-based columns,
/// cut to the set's fixed record length with its LF/CRLF terminator, as in the NARA files.
public struct LineBuilder {
    private var bytes = [UInt8](repeating: 32, count: 500)

    public init() {}

    public mutating func put(_ col: Int, _ s: String, width: Int? = nil) {
        let b = Array(s.utf8)
        let w = width ?? b.count
        for i in 0..<min(w, b.count) where col - 1 + i < 500 { bytes[col - 1 + i] = b[i] }
    }

    /// The record exactly as the real files store it: fixed length per set, LF or CRLF.
    public func line(_ kind: DatasetKind) -> [UInt8] {
        line(length: kind.lineLength, crlf: kind.usesCRLF)
    }

    /// `length: nil` trims trailing blanks (used to test variable-length input).
    public func line(length: Int?, crlf: Bool) -> [UInt8] {
        var out: [UInt8]
        if let length {
            out = Array(bytes[0..<min(length, bytes.count)])
        } else {
            var end = bytes.count
            while end > 0 && bytes[end - 1] == 32 { end -= 1 }
            out = Array(bytes[0..<end])
        }
        if crlf { out += [13, 10] } else { out.append(10) }
        return out
    }

    public func string(_ kind: DatasetKind) -> String {
        String(decoding: bytes[0..<kind.lineLength], as: UTF8.self)
    }
}

/// Deterministic generator of fake NUMIDENT data for tests and benchmarks.
/// All names are drawn from small generic lists; no real records are produced.
public enum SyntheticDataset {
    public struct Config: Sendable {
        public var persons: Int = 10_000
        public var filesPerSet: Int = 20
        public var missing: [DatasetKind: Set<Int>] = [:]
        /// Files to cut short mid-line after writing.
        public var truncate: [DatasetKind: Set<Int>] = [:]
        public var seed: UInt64 = 42
        public var claimFraction = 0.3
        public var deathFraction = 0.6
        /// Mimic the real files: an all-`Z` separator record every N records (0 = none).
        public var separatorEvery = 2_500
        /// Mimic the real files: move the last few records of each file to the front, creating a
        /// short out-of-order leading block followed by the main sorted run.
        public var leadingBlock = true
        public init() {}

        /// The standard test fixture: NUMCLM 02–11 missing and NUMDEATH03 truncated.
        public static func fixture(persons: Int = 5_000) -> Config {
            var c = Config()
            c.persons = persons
            c.missing = [.claim: Set(2...11)]
            c.truncate = [.death: [3]]
            return c
        }
    }

    public struct Stats: Sendable {
        public var lines: [DatasetKind: Int] = [:]
        public var bytes: Int64 = 0
        /// A sample of generated SSNs (every ~100th person) for lookup tests.
        public var sampleSSNs: [String] = []
    }

    struct RNG {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func int(_ r: ClosedRange<Int>) -> Int {
            r.lowerBound + Int(next() % UInt64(r.count))
        }
        mutating func chance(_ p: Double) -> Bool { Double(next() % 1_000_000) / 1_000_000 < p }
        mutating func pick<T>(_ a: [T]) -> T { a[Int(next() % UInt64(a.count))] }
    }

    static let maleFirst = ["JOHN", "WILLIAM", "JAMES", "GEORGE", "CHARLES", "FRANK", "JOSEPH", "HENRY", "ROBERT",
                            "EDWARD", "THOMAS", "WALTER", "HAROLD", "ARTHUR", "ALBERT", "RAYMOND", "CARL", "LOUIS"]
    static let femaleFirst = ["MARY", "ANNA", "HELEN", "MARGARET", "RUTH", "ELIZABETH", "DOROTHY", "MILDRED", "ALICE",
                              "FLORENCE", "ETHEL", "LILLIAN", "EDNA", "GLADYS", "FRANCES", "ROSE", "GRACE", "IRENE"]
    static let lastNames = ["SMITH", "SMYTH", "SMYTHE", "JOHNSON", "BROWN", "MILLER", "DAVIS", "WILSON", "MOORE",
                            "TAYLOR", "ANDERSON", "THOMAS", "JACKSON", "WHITE", "HARRIS", "MARTIN", "THOMPSON",
                            "GARCIA", "CLARK", "LEWIS", "ROBINSON", "WALKER", "YOUNG", "ALLEN", "KING", "WRIGHT",
                            "SCOTT", "GREEN", "BAKER", "ADAMS", "NELSON", "HILL", "CAMPBELL", "MITCHELL", "ROBERTS",
                            "CARTER", "PHILLIPS", "EVANS", "TURNER", "TORRES", "PARKER", "COLLINS", "EDWARDS",
                            "STEWART", "MORRIS", "MURPHY", "COOK", "ROGERS", "MORGAN", "PETERSON", "COOPER", "REED",
                            "BAILEY", "BELL", "GOMEZ", "KELLY", "HOWARD", "WARD", "COX", "DIAZ", "RICHARDSON"]
    static let places: [(String, String)] = [
        ("BOSTON", "MA"), ("SPRINGFIELD", "IL"), ("COLUMBUS", "OH"), ("RICHMOND", "VA"), ("DAYTON", "OH"),
        ("PORTLAND", "ME"), ("ALBANY", "NY"), ("TRENTON", "NJ"), ("MADISON", "WI"), ("AUSTIN", "TX"),
        ("FRESNO", "CA"), ("DENVER", "CO"), ("TOLEDO", "OH"), ("SALEM", "OR"), ("ERIE", "PA"),
        ("NAPLES", "IT"), ("DUBLIN", "EI"), ("HAMBURG", "GM"),
    ]
    static let deathSources = ["HC", "BX", "FO", "PE", "SI", "VA", "  ", "  ", "  "]

    static func mdy(_ m: Int, _ d: Int, _ y: Int, partialDay: Bool = false, partialMonth: Bool = false) -> String {
        (partialMonth ? "XX" : String(format: "%02d", m)) + (partialDay ? "XX" : String(format: "%02d", d))
            + String(format: "%04d", y)
    }

    static func ymd(_ y: Int, _ m: Int, _ d: Int, partialDay: Bool = false) -> String {
        String(format: "%04d%02d", y, m) + (partialDay ? "XX" : String(format: "%02d", d))
    }

    final class Writer {
        let handle: FileHandle?
        let path: String?
        let kind: DatasetKind
        let separatorEvery: Int
        var records = 0
        var buf: [UInt8] = []
        var written: Int64 = 0
        init(path: String?, kind: DatasetKind, separatorEvery: Int) throws {
            self.path = path
            self.kind = kind
            self.separatorEvery = separatorEvery
            if let path {
                FileManager.default.createFile(atPath: path, contents: nil)
                handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            } else {
                handle = nil
            }
            buf.reserveCapacity(1 << 20)
        }
        func write(_ b: [UInt8]) throws {
            guard handle != nil else { return }
            records += 1
            if separatorEvery > 0 && records % separatorEvery == 0 {
                try write(raw: separatorLine(kind))
            }
            try write(raw: b)
        }
        func write(raw b: [UInt8]) throws {
            buf += b
            written += Int64(b.count)
            if buf.count >= 1 << 20 { try flush() }
        }
        func flush() throws {
            if let handle, !buf.isEmpty { try handle.write(contentsOf: buf) }
            buf.removeAll(keepingCapacity: true)
        }
        func close() throws {
            try flush()
            try handle?.close()
        }
    }

    public static func fileName(_ kind: DatasetKind, _ n: Int) -> String {
        let ext = kind == .death ? "TXT" : "txt"
        return String(format: "%@%02d_PU.%@", kind.rawValue, n, ext)
    }

    /// Writes `<root>/<SET>/<SET>NN_PU.txt` files (fixed-size records). SSNs increase monotonically, so every file is sorted.
    @discardableResult
    public static func generate(at root: String, config: Config) throws -> Stats {
        let fm = FileManager.default
        var writers: [DatasetKind: [Int: Writer]] = [:]
        for kind in DatasetKind.allCases {
            let dir = (root as NSString).appendingPathComponent(kind.rawValue)
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            var w: [Int: Writer] = [:]
            for n in 1...config.filesPerSet {
                let missing = config.missing[kind]?.contains(n) ?? false
                w[n] = try Writer(path: missing ? nil : (dir as NSString).appendingPathComponent(fileName(kind, n)),
                                  kind: kind, separatorEvery: config.separatorEvery)
            }
            writers[kind] = w
        }

        var rng = RNG(state: config.seed)
        var stats = Stats()
        let span = 899_999_999 / max(1, config.persons)
        var ssn = 1_010_000
        for i in 0..<config.persons {
            ssn += rng.int(1...max(1, 2 * span - 1))
            if ssn > 999_999_999 { break }
            let ssnStr = String(format: "%09d", ssn)
            if i % 100 == 0 { stats.sampleSSNs.append(ssnStr) }
            let person = makePerson(&rng)
            func file(_ kind: DatasetKind) -> Writer {
                let salt: Int
                switch kind { case .ss5: salt = 0; case .claim: salt = 7; case .death: salt = 13 }
                return writers[kind]![(ssn / 3 + salt) % config.filesPerSet + 1]!
            }
            // SS-5: original plus occasional replacements / name changes.
            let apps = 1 + (rng.chance(0.3) ? 1 : 0) + (rng.chance(0.1) ? 1 : 0)
            var cycleYear = min(2007, max(1936, person.dobYear + rng.int(14...40)))
            for a in 0..<apps {
                let line = ss5Line(ssn: ssnStr, p: person, app: a, cycleYear: cycleYear, rng: &rng)
                try file(.ss5).write(line)
                stats.lines[.ss5, default: 0] += 1
                cycleYear = min(2007, cycleYear + rng.int(1...15))
            }
            if rng.chance(config.claimFraction) {
                try file(.claim).write(claimLine(ssn: ssnStr, p: person, rng: &rng))
                stats.lines[.claim, default: 0] += 1
            }
            if rng.chance(config.deathFraction) {
                try file(.death).write(deathLine(ssn: ssnStr, p: person, rng: &rng))
                stats.lines[.death, default: 0] += 1
            }
        }

        for (kind, w) in writers {
            for (n, writer) in w {
                try writer.close()
                stats.bytes += writer.written
                if config.leadingBlock, let path = writer.path {
                    try rotateTail(path: path, kind: kind, records: 10 + (n * 7) % 50)
                }
                if config.truncate[kind]?.contains(n) == true, writer.handle != nil {
                    let path = (root as NSString).appendingPathComponent(kind.rawValue + "/" + fileName(kind, n))
                    let h = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
                    let size = try h.seekToEnd()
                    if size > 40 { try h.truncate(atOffset: size - 37) }
                    try h.close()
                }
            }
        }
        return stats
    }

    /// An all-`Z` record, as found between sorted batches in the real files.
    public static func separatorLine(_ kind: DatasetKind) -> [UInt8] {
        var b = [UInt8](repeating: 90, count: kind.lineLength)
        b += kind.usesCRLF ? [13, 10] : [10]
        return b
    }

    /// Moves the last `records` records to the front of the file.
    static func rotateTail(path: String, kind: DatasetKind, records: Int) throws {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        guard data.count % kind.recordSize == 0 else { return }
        let tail = min(records, data.count / kind.recordSize / 2) * kind.recordSize
        guard tail > 0 else { return }
        var out = Data(capacity: data.count)
        out.append(data[(data.count - tail)...])
        out.append(data[..<(data.count - tail)])
        try out.write(to: url)
    }

    struct Person {
        var first, middle, last, suffix: String
        var sex: String
        var dobYear, dobMonth, dobDay: Int
        var dobPartial: Bool
        var city, state: String
        var foreign: Bool
        var fFirst, fMiddle, fLast, mFirst, mMiddle, mLast: String
        var race: String
    }

    static func makePerson(_ rng: inout RNG) -> Person {
        let male = rng.chance(0.5)
        let first = rng.pick(male ? maleFirst : femaleFirst)
        let middle = rng.chance(0.7) ? rng.pick(male ? maleFirst : femaleFirst) : (rng.chance(0.5) ? "A" : "")
        let last = rng.pick(lastNames)
        let place = rng.pick(places)
        return Person(first: first, middle: middle, last: last, suffix: male && rng.chance(0.05) ? "JR" : "",
                      sex: rng.chance(0.03) ? "0" : (male ? "1" : "2"),
                      dobYear: rng.int(1870...1990), dobMonth: rng.int(1...12), dobDay: rng.int(1...28),
                      dobPartial: rng.chance(0.03), city: place.0, state: place.1,
                      foreign: ["IT", "EI", "GM"].contains(place.1),
                      fFirst: rng.pick(maleFirst), fMiddle: rng.chance(0.5) ? "J" : "", fLast: last,
                      mFirst: rng.pick(femaleFirst), mMiddle: rng.chance(0.3) ? "E" : "", mLast: rng.pick(lastNames),
                      race: String(rng.int(0...6)))
    }

    static func header(_ b: inout LineBuilder, ref: String, ssn: String, entry: String, form: String, cycle: String) {
        b.put(1, ref, width: 11)
        b.put(13, ssn, width: 9)
        b.put(26, form, width: 1)
        b.put(27, entry, width: 1)
        b.put(29, cycle, width: 8)
    }

    static func names(_ b: inout LineBuilder, at o: Int, _ f: String, _ m: String, _ l: String, _ s: String) {
        b.put(37 + o, f, width: 15)
        b.put(53 + o, m, width: 15)
        b.put(69 + o, l, width: 20)
        b.put(90 + o, s, width: 4)
    }

    static func ss5Line(ssn: String, p: Person, app: Int, cycleYear: Int, rng: inout RNG) -> [UInt8] {
        var b = LineBuilder()
        let partialCycle = cycleYear < 1940 && rng.chance(0.5)
        let entry = app == 0 ? "0" : rng.pick(["2", "K", "P"])
        header(&b, ref: String(format: "%011d", rng.int(10_000_000_000...99_999_999_999)), ssn: ssn,
               entry: entry, form: app == 0 ? "1" : rng.pick(["1", "2", "T"]),
               cycle: ymd(cycleYear, rng.int(1...12), rng.int(1...28), partialDay: partialCycle))
        var last = p.last
        var other: (String, String, String)?
        if entry == "K" && p.sex == "2" {
            other = (p.first, p.middle, p.last)
            last = rng.pick(lastNames)
        }
        names(&b, at: 0, p.first, p.middle, last, p.suffix)
        b.put(97, mdy(p.dobMonth, p.dobDay, p.dobYear, partialDay: p.dobPartial))
        b.put(105, p.sex)
        b.put(106, p.race)
        b.put(107, p.mFirst, width: 15); b.put(123, p.mMiddle, width: 15); b.put(139, p.mLast, width: 20)
        b.put(164, p.fFirst, width: 15); b.put(180, p.fMiddle, width: 15); b.put(196, p.fLast, width: 20)
        b.put(221, p.city, width: 12)
        b.put(234, p.state, width: 2)
        if p.foreign { b.put(236, "*") }
        if let o = other {
            b.put(237, o.0, width: 15); b.put(253, o.1, width: 15); b.put(269, o.2, width: 20)
        }
        b.put(354, rng.pick(["S", "S", "P", " "]))
        b.put(498, "A")
        return b.line(.ss5)
    }

    static func claimLine(ssn: String, p: Person, rng: inout RNG) -> [UInt8] {
        var b = LineBuilder()
        let death = rng.chance(0.4)
        let claimYear = min(2007, p.dobYear + rng.int(40...80))
        header(&b, ref: String(format: "%011d", rng.int(10_000_000_000...99_999_999_999)), ssn: ssn,
               entry: death ? "D" : "L", form: rng.pick(["5", "9", " "]),
               cycle: ymd(max(1936, claimYear), rng.int(1...12), rng.int(1...28)))
        names(&b, at: 0, p.first, p.middle, p.last, p.suffix)
        b.put(97, mdy(p.dobMonth, p.dobDay, p.dobYear, partialDay: p.dobPartial))
        b.put(105, p.sex)
        b.put(107, p.mFirst, width: 15); b.put(139, p.mLast, width: 20)
        b.put(164, p.fFirst, width: 15); b.put(196, p.fLast, width: 20)
        b.put(221, p.city, width: 12)
        b.put(234, p.state, width: 2)
        b.put(237, "\(p.city) \(p.state) FIELD OFFICE", width: 45)
        b.put(282, mdy(rng.int(1...12), rng.int(1...28), claimYear))
        if death { b.put(298, mdy(rng.int(1...12), rng.int(1...28), max(p.dobYear, claimYear - 1))) }
        b.put(498, "A")
        return b.line(.claim)
    }

    static func deathLine(ssn: String, p: Person, rng: inout RNG) -> [UInt8] {
        var b = LineBuilder()
        let postings = rng.chance(0.7) ? 1 : (rng.chance(0.67) ? 2 : 3)
        let dodYear = min(2007, p.dobYear + rng.int(30...100))
        let dodMonth = rng.int(1...12), dodDay = rng.int(1...28)
        header(&b, ref: rng.chance(0.5) ? "" : String(format: "%011d", rng.int(10_000_000_000...99_999_999_999)),
               ssn: ssn, entry: "T", form: " ", cycle: ymd(dodYear, dodMonth, dodDay))
        for i in 0..<postings {
            let o = i * Layouts.deathPostingStride
            names(&b, at: o, p.first, i == 1 ? "" : p.middle, p.last, p.suffix)
            // Later postings occasionally disagree on the birth year.
            let dy = i == 2 && rng.chance(0.5) ? p.dobYear + 1 : p.dobYear
            b.put(97 + o, mdy(p.dobMonth, p.dobDay, dy, partialDay: p.dobPartial))
            b.put(105 + o, p.sex)
            if rng.chance(0.5) { b.put(107 + o, ssn) }
            b.put(117 + o, rng.pick([" ", "P", "V", "N"]))
            b.put(119 + o, String(format: "%05d0000", rng.int(1000...99_950)))
            b.put(142 + o, rng.pick(deathSources), width: 2)
            b.put(144 + o, rng.pick(["N", "Y", " "]))
            let partial = rng.chance(0.08)
            b.put(145 + o, mdy(dodMonth, dodDay, dodYear, partialDay: partial, partialMonth: partial && rng.chance(0.3)))
            b.put(179 + o, ymd(dodYear, dodMonth, dodDay))
        }
        b.put(487, String(postings))
        return b.line(.death)
    }
}
