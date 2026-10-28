import Foundation
import os

/// A last-name index kept in `<data folder>/LASTNAME-INDEX/`, next to the data it covers.
///
/// Every surname on every record (SS-5 card, other and signature names; claim; all three death
/// postings) maps to the records carrying it. A record is identified by `fileNumber << 32 | byteOffset`,
/// stored per surname as ascending, delta-coded varints. Files: `manifest.json` (which data files the
/// index covers, by name, size and modification time), `names.bin` (sorted surnames with where their
/// list starts) and `postings.bin` (the lists).
///
/// A search with a last name looks the name up here and reads only the candidate records; the normal
/// matcher still checks every candidate, so results are identical to a full scan. Files the index does
/// not cover (added or changed since it was built) are scanned as usual.
public final class LastNameIndex: @unchecked Sendable {
    public static let folderName = "LASTNAME-INDEX"
    static let formatVersion = 1

    public struct Manifest: Codable, Sendable {
        public struct Entry: Codable, Sendable, Hashable {
            public let set: String
            public let name: String
            public let size: Int64
            public let modified: Double
        }
        public let version: Int
        public let built: Date
        public let files: [Entry]
        public let surnames: Int
        public let postings: Int64
        public let recordsIndexed: Int64
    }

    public let root: String
    public let manifest: Manifest
    public var folder: String { (root as NSString).appendingPathComponent(Self.folderName) }

    private let blob: [UInt8]          // all surnames, sorted, concatenated
    private let nameStart: [UInt32]    // nameStart[i]..<nameStart[i+1] in blob
    private let listOffset: [UInt64]   // byte offset of surname i's list in postings.bin
    private let listCount: [UInt32]    // records in surname i's list
    private let fileByKey: [String: Int]
    private let postingsPath: String
    private let soundexCodes = OSAllocatedUnfairLock<[UInt32]?>(initialState: nil)

    public var surnameCount: Int { listCount.count }

    // MARK: Opening

    /// Opens the index in `root`, or returns nil if there is none or it can't be read.
    public static func open(root: String) -> LastNameIndex? {
        let dir = (root as NSString).appendingPathComponent(folderName)
        guard let data = FileManager.default.contents(atPath: (dir as NSString).appendingPathComponent("manifest.json")),
              let m = try? JSONDecoder.index.decode(Manifest.self, from: data), m.version == formatVersion,
              let names = FileManager.default.contents(atPath: (dir as NSString).appendingPathComponent("names.bin"))
        else { return nil }
        return LastNameIndex(root: root, manifest: m, names: [UInt8](names),
                             postingsPath: (dir as NSString).appendingPathComponent("postings.bin"))
    }

    private init?(root: String, manifest: Manifest, names: [UInt8], postingsPath: String) {
        // names.bin: per surname, u8 length, bytes, u64 list offset, u32 count (little-endian).
        var blob: [UInt8] = []
        var starts: [UInt32] = [0]
        var offsets: [UInt64] = []
        var counts: [UInt32] = []
        blob.reserveCapacity(names.count)
        starts.reserveCapacity(manifest.surnames + 1)
        offsets.reserveCapacity(manifest.surnames)
        counts.reserveCapacity(manifest.surnames)
        var i = 0
        while i < names.count {
            let len = Int(names[i])
            guard i + 1 + len + 12 <= names.count else { return nil }
            blob.append(contentsOf: names[(i + 1)..<(i + 1 + len)])
            starts.append(UInt32(blob.count))
            var p = i + 1 + len
            offsets.append(Self.readLE(names, &p, 8))
            counts.append(UInt32(Self.readLE(names, &p, 4)))
            i = p
        }
        guard counts.count == manifest.surnames else { return nil }
        self.root = root
        self.manifest = manifest
        self.blob = blob
        self.nameStart = starts
        self.listOffset = offsets
        self.listCount = counts
        self.postingsPath = postingsPath
        var keys: [String: Int] = [:]
        for (n, e) in manifest.files.enumerated() { keys[Self.fileKey(e.set, e.name)] = n }
        self.fileByKey = keys
    }

    private static func readLE(_ b: [UInt8], _ p: inout Int, _ n: Int) -> UInt64 {
        var v: UInt64 = 0
        for k in 0..<n { v |= UInt64(b[p + k]) << (8 * UInt64(k)) }
        p += n
        return v
    }

    static func fileKey(_ set: String, _ name: String) -> String { set + "/" + name.uppercased() }

    static func entry(for f: CatalogFile) -> Manifest.Entry {
        let attrs = try? FileManager.default.attributesOfItem(atPath: f.path)
        let modified = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return Manifest.Entry(set: f.kind.rawValue, name: f.name, size: f.size, modified: modified)
    }

    /// The index's number for `f`, or nil if the index doesn't cover this exact file (missing from
    /// the index, or a different size or modification time than when the index was built).
    public func fileNumber(for f: CatalogFile) -> Int? {
        guard let n = fileByKey[Self.fileKey(f.kind.rawValue, f.name)] else { return nil }
        let e = manifest.files[n], now = Self.entry(for: f)
        return e.size == now.size && abs(e.modified - now.modified) < 2 ? n : nil
    }

    // MARK: Lookup

    private func name(_ i: Int) -> ArraySlice<UInt8> { blob[Int(nameStart[i])..<Int(nameStart[i + 1])] }

    /// First surname index whose name is >= `key`.
    private func lowerBound(_ key: [UInt8]) -> Int {
        var lo = 0, hi = listCount.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if name(mid).lexicographicallyPrecedes(key) { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Surnames matching `text` the way the search matcher would.
    func matchingSurnames(_ text: String, mode: NameMatch) -> [Int] {
        let q = Array(text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().utf8)
        guard !q.isEmpty else { return [] }
        let code = mode == .soundex ? Soundex.code(String(decoding: q, as: UTF8.self)) : 0
        switch mode {
        case .soundex where code != 0:
            let codes = soundexTable()
            return codes.indices.filter { codes[$0] == code }
        case .prefix:
            var out: [Int] = []
            var i = lowerBound(q)
            while i < listCount.count, name(i).starts(with: q) { out.append(i); i += 1 }
            return out
        default: // exact, or Soundex of a name with no letters (the matcher then compares text)
            let i = lowerBound(q)
            return i < listCount.count && name(i).elementsEqual(q) ? [i] : []
        }
    }

    private func soundexTable() -> [UInt32] {
        if let t = soundexCodes.withLock({ $0 }) { return t }
        var t = [UInt32](repeating: 0, count: listCount.count)
        blob.withUnsafeBufferPointer { b in
            for i in t.indices { t[i] = Soundex.code(b, Int(nameStart[i])..<Int(nameStart[i + 1])) }
        }
        let table = t
        soundexCodes.withLock { $0 = table }
        return table
    }

    /// Records that carry a matching surname, grouped by index file number with ascending byte
    /// offsets. Returns nil when more than `limit` records would match (a full scan is then cheaper).
    public func candidates(lastName: String, mode: NameMatch, limit: Int = 3_000_000) throws -> [Int: [Int64]]? {
        let ids = matchingSurnames(lastName, mode: mode)
        let total = ids.reduce(0) { $0 + Int(listCount[$1]) }
        if total > limit { return nil }
        var keys: [UInt64] = []
        keys.reserveCapacity(total)
        let fd = Darwin.open(postingsPath, O_RDONLY)
        guard fd >= 0 else { throw ScanError.open(postingsPath, errno) }
        defer { close(fd) }
        for id in ids {
            let start = listOffset[id]
            let end = id + 1 < listOffset.count ? listOffset[id + 1] : UInt64(Self.fileSize(fd))
            var bytes = [UInt8](repeating: 0, count: Int(end - start))
            let n = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, off_t(start)) }
            guard n == bytes.count else { throw ScanError.read(postingsPath, n < 0 ? errno : EIO) }
            var p = 0, key: UInt64 = 0
            for _ in 0..<listCount[id] {
                key &+= Varint.read(bytes, &p)
                keys.append(key)
            }
        }
        if ids.count > 1 { keys.sort() }
        var out: [Int: [Int64]] = [:]
        var previous: UInt64 = .max
        for k in keys where k != previous {
            out[Int(k >> 32), default: []].append(Int64(k & 0xFFFF_FFFF))
            previous = k
        }
        return out
    }

    private static func fileSize(_ fd: Int32) -> Int64 {
        var st = stat()
        return fstat(fd, &st) == 0 ? Int64(st.st_size) : 0
    }
}

extension JSONDecoder {
    static var index: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

extension JSONEncoder {
    static var index: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

enum Varint {
    @inline(__always)
    static func append(_ v: UInt64, to out: inout [UInt8]) {
        var v = v
        while v >= 0x80 {
            out.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        out.append(UInt8(v))
    }

    @inline(__always)
    static func read(_ b: [UInt8], _ p: inout Int) -> UInt64 {
        var v: UInt64 = 0, shift: UInt64 = 0
        while p < b.count {
            let c = b[p]
            p += 1
            v |= UInt64(c & 0x7F) << shift
            if c < 0x80 { break }
            shift += 7
        }
        return v
    }
}

// MARK: - Building

public struct IndexBuildProgress: Sendable {
    public let bytesDone: Int64
    public let bytesTotal: Int64
    public let currentFile: String
    public let elapsed: Double

    public init(bytesDone: Int64, bytesTotal: Int64, currentFile: String, elapsed: Double) {
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
        self.currentFile = currentFile
        self.elapsed = elapsed
    }

    public var fraction: Double { bytesTotal > 0 ? min(1, Double(bytesDone) / Double(bytesTotal)) : 1 }
    public var etaSeconds: Double? {
        guard bytesDone > 0, bytesDone < bytesTotal, elapsed > 1 else { return nil }
        return Double(bytesTotal - bytesDone) / (Double(bytesDone) / elapsed)
    }
}

public enum LastNameIndexBuilder {
    /// 0-based start of each 20-column last-name field the index covers.
    static func surnameColumns(_ kind: DatasetKind) -> [Int] {
        switch kind {
        case .ss5: return [68, 268, 328]     // card name, other name, signature name
        case .claim: return [68]
        case .death: return (0..<3).map { 68 + $0 * Layouts.deathPostingStride }
        }
    }

    /// Reads every usable file once and writes `<root>/LASTNAME-INDEX/`, replacing any old index only
    /// after the new one is complete. Files whose size isn't a whole number of records are left out
    /// (searches scan them). Blocking; call off the main thread.
    @discardableResult
    public static func build(root: String, files: [CatalogFile], cancel: CancelToken,
                             progress: (IndexBuildProgress) -> Void = { _ in }) throws -> LastNameIndex.Manifest {
        let targets = files
            .filter { $0.isUsable && $0.size % Int64($0.kind.recordSize) == 0 && $0.size < (Int64(1) << 32) }
            .sorted { ($0.kind, $0.number) < ($1.kind, $1.number) }
        let total = targets.reduce(Int64(0)) { $0 + $1.size }
        let start = Date()
        var done: Int64 = 0
        var lastReport = Date.distantPast

        var ids: [[UInt8]: Int32] = [:]
        var names: [[UInt8]] = []
        var lists: [[UInt8]] = []
        var lastKey: [UInt64] = []
        var counts: [UInt32] = []
        var postings: Int64 = 0
        var records: Int64 = 0
        let buffer = ScanBuffer()

        for (n, f) in targets.enumerated() {
            let cols = surnameColumns(f.kind)
            let fileBits = UInt64(n) << 32
            try LineScanner.scan(path: f.path, buffer: buffer, cancel: cancel, progress: { read in
                done += Int64(read)
                if Date().timeIntervalSince(lastReport) > 0.25 {
                    lastReport = Date()
                    progress(IndexBuildProgress(bytesDone: done, bytesTotal: total, currentFile: f.name,
                                                elapsed: Date().timeIntervalSince(start)))
                }
            }) { line, offset in
                // Skip masked/separator records (SSN of all Z).
                if line.count > 12 && line[12] == 90 && line[13] == 90 && line[14] == 90 { return }
                records += 1
                let key = fileBits | UInt64(offset)
                var seen: [Int32] = []
                for c in cols {
                    guard let surname = trimmedUpper(line, c, 20) else { continue }
                    let id: Int32
                    if let existing = ids[surname] {
                        id = existing
                    } else {
                        id = Int32(names.count)
                        ids[surname] = id
                        names.append(surname)
                        lists.append([])
                        lastKey.append(0)
                        counts.append(0)
                    }
                    if seen.contains(id) { continue }
                    seen.append(id)
                    let i = Int(id)
                    Varint.append(key &- lastKey[i], to: &lists[i])
                    lastKey[i] = key
                    counts[i] += 1
                    postings += 1
                }
            }
        }
        if cancel.isCancelled { throw ScanError.cancelled }
        progress(IndexBuildProgress(bytesDone: total, bytesTotal: total, currentFile: "writing index",
                                    elapsed: Date().timeIntervalSince(start)))

        let manifest = LastNameIndex.Manifest(
            version: LastNameIndex.formatVersion, built: Date(), files: targets.map(LastNameIndex.entry(for:)),
            surnames: names.count, postings: postings, recordsIndexed: records)
        try write(root: root, manifest: manifest, names: names, lists: lists, counts: counts)
        return manifest
    }

    /// Trimmed, upper-cased field bytes, or nil when the field is blank.
    static func trimmedUpper(_ line: UnsafeBufferPointer<UInt8>, _ start: Int, _ len: Int) -> [UInt8]? {
        var lo = start, hi = min(start + len, line.count)
        while lo < hi && line[lo] == 32 { lo += 1 }
        while hi > lo && line[hi - 1] == 32 { hi -= 1 }
        guard lo < hi else { return nil }
        var out = [UInt8](UnsafeBufferPointer(rebasing: line[lo..<hi]))
        for k in out.indices where out[k] >= 97 && out[k] <= 122 { out[k] -= 32 }
        return out
    }

    private static func write(root: String, manifest: LastNameIndex.Manifest, names: [[UInt8]],
                              lists: [[UInt8]], counts: [UInt32]) throws {
        let fm = FileManager.default
        let final = (root as NSString).appendingPathComponent(LastNameIndex.folderName)
        let partial = final + ".partial"
        try? fm.removeItem(atPath: partial)
        try fm.createDirectory(atPath: partial, withIntermediateDirectories: false)

        let order = names.indices.sorted { names[$0].lexicographicallyPrecedes(names[$1]) }
        guard let post = OutputStream(toFileAtPath: (partial as NSString).appendingPathComponent("postings.bin"),
                                      append: false) else { throw ScanError.open(partial, EIO) }
        post.open()
        var namesOut: [UInt8] = []
        var offset: UInt64 = 0
        for i in order {
            namesOut.append(UInt8(names[i].count))
            namesOut.append(contentsOf: names[i])
            for k in 0..<8 { namesOut.append(UInt8((offset >> (8 * UInt64(k))) & 0xFF)) }
            for k in 0..<4 { namesOut.append(UInt8((counts[i] >> (8 * UInt32(k))) & 0xFF)) }
            try writeAll(post, lists[i], partial)
            offset += UInt64(lists[i].count)
        }
        post.close()
        try Data(namesOut).write(to: URL(fileURLWithPath: (partial as NSString).appendingPathComponent("names.bin")))
        try JSONEncoder.index.encode(manifest)
            .write(to: URL(fileURLWithPath: (partial as NSString).appendingPathComponent("manifest.json")))

        // Swap in the new index; the old one stays usable until this point.
        let old = final + ".old"
        try? fm.removeItem(atPath: old)
        if fm.fileExists(atPath: final) { try fm.moveItem(atPath: final, toPath: old) }
        try fm.moveItem(atPath: partial, toPath: final)
        try? fm.removeItem(atPath: old)
    }

    private static func writeAll(_ s: OutputStream, _ bytes: [UInt8], _ path: String) throws {
        var written = 0
        while written < bytes.count {
            let n = bytes[written...].withUnsafeBufferPointer { s.write($0.baseAddress!, maxLength: $0.count) }
            guard n > 0 else { throw ScanError.read(path, EIO) }
            written += n
        }
    }
}
