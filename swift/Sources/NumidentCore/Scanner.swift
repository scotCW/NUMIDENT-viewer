import Foundation
import os

public enum ScanError: Error, Sendable, CustomStringConvertible {
    case open(String, Int32)
    case read(String, Int32)
    case cancelled

    public var description: String {
        switch self {
        case .open(let p, let e): return "cannot open \((p as NSString).lastPathComponent): \(String(cString: strerror(e)))"
        case .read(let p, let e): return "read error in \((p as NSString).lastPathComponent): \(String(cString: strerror(e)))"
        case .cancelled: return "cancelled"
        }
    }
}

/// Thread-safe cancellation flag checked by scanners once per chunk.
public final class CancelToken: @unchecked Sendable {
    private let flag = OSAllocatedUnfairLock(initialState: false)
    public init() {}
    public func cancel() { flag.withLock { $0 = true } }
    public var isCancelled: Bool { flag.withLock { $0 } }
}

/// A reusable read buffer: one per worker, so a scan allocates nothing per chunk.
public final class ScanBuffer {
    public let chunkSize: Int
    let capacity: Int
    let base: UnsafeMutablePointer<UInt8>

    public init(chunkSize: Int = 4 << 20) {
        self.chunkSize = max(chunkSize, 64)
        // Room for a carried-over partial line in front of a full chunk.
        self.capacity = self.chunkSize + 64 * 1024
        self.base = .allocate(capacity: capacity)
    }

    deinit { base.deallocate() }
}

public enum LineScanner {
    /// Streams every line of a file through `body` (line bytes without CR/LF, byte offset of line start).
    /// Calls `progress` with the bytes read after each chunk and checks `cancel` once per chunk.
    public static func scan(path: String, buffer: ScanBuffer, cancel: CancelToken,
                            progress: (Int) -> Void,
                            body: (UnsafeBufferPointer<UInt8>, Int64) -> Void) throws {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw ScanError.open(path, errno) }
        defer { close(fd) }
        _ = fcntl(fd, F_RDAHEAD, 1)
        try scan(fd: fd, path: path, buffer: buffer, cancel: cancel, progress: progress, body: body)
    }

    static func scan(fd: Int32, path: String, buffer: ScanBuffer, cancel: CancelToken,
                     progress: (Int) -> Void,
                     body: (UnsafeBufferPointer<UInt8>, Int64) -> Void) throws {
        let base = buffer.base
        var carry = 0
        var bufferStart: Int64 = 0 // file offset of base[0]

        @inline(__always)
        func emit(_ start: Int, _ end: Int) {
            var e = end
            if e > start && base[e - 1] == 13 { e -= 1 }
            body(UnsafeBufferPointer(start: base + start, count: e - start), bufferStart + Int64(start))
        }

        while true {
            if cancel.isCancelled { throw ScanError.cancelled }
            var space = buffer.capacity - carry
            if space == 0 {
                // A "line" longer than the whole buffer: emit it as-is and move on.
                emit(0, carry)
                bufferStart += Int64(carry)
                carry = 0
                space = buffer.capacity
            }
            let want = min(buffer.chunkSize, space)
            let n = read(fd, base + carry, want)
            if n < 0 {
                if errno == EINTR { continue }
                throw ScanError.read(path, errno)
            }
            if n == 0 {
                if carry > 0 { emit(0, carry) }
                return
            }
            progress(n)
            let total = carry + n
            var lineStart = 0
            while lineStart < total,
                  let p = memchr(base + lineStart, 10, total - lineStart) {
                let nl = base.distance(to: p.assumingMemoryBound(to: UInt8.self))
                emit(lineStart, nl)
                lineStart = nl + 1
            }
            carry = total - lineStart
            if carry > 0 && lineStart > 0 {
                memmove(base, base + lineStart, carry)
            }
            bufferStart += Int64(lineStart)
        }
    }
}

/// Where the sorted stretches of a file are. Real NUMIDENT files are not globally sorted: each is a
/// short leading block followed by a long SSN-sorted run, with all-`Z` separator records in between.
public struct RunMap: Codable, Sendable, Equatable {
    public let recordCount: Int64
    /// Half-open record-index ranges, each sorted by SSN (ignoring separator records).
    public let runs: [[Int64]]
    /// False when too many runs were found to make binary search worthwhile.
    public let searchable: Bool
}

public struct LookupResult: Sendable {
    public let hits: [(offset: Int64, bytes: [UInt8])]
    public let method: String
}

/// SSN lookups by binary search.
public enum SSNIndex {
    /// Persist run maps in ~/Library/Caches so later launches skip the sampling pass.
    nonisolated(unsafe) public static var diskCacheEnabled = true
    static let maxRuns = 64
    static let samples = 1024
    /// Records at the start of each file that are read in full: real files begin with a short
    /// out-of-order block whose SSNs can fall between two sample points, invisible to sampling.
    static let headRecords: Int64 = 16_384
    static let runMapVersion = 2

    private static let cache = OSAllocatedUnfairLock(initialState: [String: RunMap]())
    private static let diskLoaded = OSAllocatedUnfairLock(initialState: false)

    static var cacheURL: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        // Bump the version whenever run detection changes, so stale maps are discarded.
        return base.appendingPathComponent("NumidentViewer/runmaps-v\(runMapVersion).json")
    }

    struct Line {
        let start: Int64
        let bytes: [UInt8]
    }

    static func cacheKey(_ path: String) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(path)|\(size)|\(Int64(mtime))"
    }

    private static func loadDiskCache() {
        guard diskCacheEnabled else { return }
        // Load while holding the flag's lock so concurrent lookups wait for the cache instead of
        // seeing it empty and rebuilding every run map from the drive.
        diskLoaded.withLock { done in
            guard !done else { return }
            done = true
            guard let data = try? Data(contentsOf: cacheURL),
                  let map = try? JSONDecoder().decode([String: RunMap].self, from: data) else { return }
            cache.withLock { c in c.merge(map) { a, _ in a } }
        }
    }

    private static func saveDiskCache() {
        guard diskCacheEnabled else { return }
        let snapshot = cache.withLock { $0 }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }

    @inline(__always)
    static func isSSN(_ k: ArraySlice<UInt8>) -> Bool { k.count == 9 && k.allSatisfy { $0 >= 48 && $0 <= 57 } }

    /// The 9 SSN bytes, or nil for separator / malformed records.
    static func validKey(_ b: [UInt8]) -> [UInt8]? {
        guard b.count >= 21 else { return nil }
        let k = b[12..<21]
        return isSSN(k) ? Array(k) : nil
    }

    static func less(_ a: [UInt8], _ b: [UInt8]) -> Bool { a.lexicographicallyPrecedes(b) }

    private static func readAt(_ fd: Int32, _ buf: inout [UInt8], _ pos: Int64, _ path: String) throws -> Int {
        while true {
            let n = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, off_t(pos)) }
            if n < 0 {
                if errno == EINTR { continue }
                throw ScanError.read(path, errno)
            }
            return n
        }
    }

    // MARK: - Fixed-size records

    static func record(fd: Int32, kind: DatasetKind, index: Int64, buf: inout [UInt8], path: String) throws -> [UInt8] {
        let n = try readAt(fd, &buf, index * Int64(kind.recordSize), path)
        var end = min(n, kind.recordSize)
        while end > 0 && (buf[end - 1] == 10 || buf[end - 1] == 13) { end -= 1 }
        return Array(buf[0..<end])
    }

    /// Checks the first and last records end with the expected terminator.
    static func recordLooksAligned(fd: Int32, kind: DatasetKind, size: Int64, path: String) throws -> Bool {
        let rs = kind.recordSize
        guard size >= rs, size % Int64(rs) == 0 else { return false }
        var b = [UInt8](repeating: 0, count: rs)
        for off in [Int64(0), size - Int64(rs)] {
            let n = try readAt(fd, &b, off, path)
            guard n == rs, b[rs - 1] == 10 else { return false }
            if kind.usesCRLF && b[rs - 2] != 13 { return false }
        }
        return true
    }

    /// Finds the sorted runs of a fixed-size-record file: the first 16,384 records are read in full
    /// (the leading out-of-order block lives there), the rest is sampled at ~1,024 points and, wherever
    /// the SSN drops between two samples, that window is read to locate the exact boundary.
    /// Returns nil when the file is not a whole number of records.
    public static func runMap(path: String, kind: DatasetKind) throws -> RunMap? {
        loadDiskCache()
        let key = cacheKey(path)
        if let m = cache.withLock({ $0[key] }) { return m }
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw ScanError.open(path, errno) }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw ScanError.read(path, errno) }
        let size = Int64(st.st_size)
        guard try recordLooksAligned(fd: fd, kind: kind, size: size, path: path) else { return nil }
        let rs = Int64(kind.recordSize)
        let count = size / rs
        var buf = [UInt8](repeating: 0, count: kind.recordSize)

        var boundaries: [Int64] = []
        var prev: (idx: Int64, key: [UInt8])?

        // 1. Read the head of the file in full and record every drop exactly.
        let head = min(count, headRecords)
        let block: Int64 = 1024
        var start0: Int64 = 0
        while start0 < head {
            let n = min(block, head - start0)
            var chunk = [UInt8](repeating: 0, count: Int(n) * kind.recordSize)
            let got = try readAt(fd, &chunk, start0 * rs, path)
            var r = 0
            while (r + 1) * kind.recordSize <= got {
                let o = r * kind.recordSize
                let kk = chunk[(o + 12)..<(o + 21)]
                if isSSN(kk) {
                    let idx = start0 + Int64(r)
                    if let p = prev, kk.lexicographicallyPrecedes(p.key) { boundaries.append(idx) }
                    prev = (idx, Array(kk))
                }
                r += 1
            }
            start0 += n
        }

        // 2. Sample the rest; where the SSN drops between samples, read that window to find each drop.
        var indices: [Int64] = []
        if count > head {
            let span = count - head
            indices = (0..<Int64(samples)).map { head + span * $0 / Int64(samples) }
            indices.append(count - 1)
        }
        var lastIdx: Int64 = head - 1
        for idx in indices where idx > lastIdx {
            lastIdx = idx
            guard let k = validKey(try record(fd: fd, kind: kind, index: idx, buf: &buf, path: path)) else { continue }
            if let p = prev, less(k, p.key) {
                var window = [UInt8](repeating: 0, count: Int(idx - p.idx + 1) * kind.recordSize)
                let n = try readAt(fd, &window, p.idx * rs, path)
                var last = p.key
                var r = 1
                while (r + 1) * kind.recordSize <= n {
                    let o = r * kind.recordSize
                    let kk = window[(o + 12)..<(o + 21)]
                    if isSSN(kk) {
                        if kk.lexicographicallyPrecedes(last) { boundaries.append(p.idx + Int64(r)) }
                        last = Array(kk)
                    }
                    r += 1
                }
            }
            prev = (idx, k)
        }
        var runs: [[Int64]] = []
        var start: Int64 = 0
        for b in boundaries.sorted() where b > start {
            runs.append([start, b])
            start = b
        }
        runs.append([start, count])
        let map = RunMap(recordCount: count, runs: runs, searchable: runs.count <= maxRuns)
        cache.withLock { $0[key] = map }
        saveDiskCache()
        return map
    }

    /// First valid SSN at or after `from` (skipping separator records), within `before`.
    static func keyAtOrAfter(fd: Int32, kind: DatasetKind, from: Int64, before: Int64, buf: inout [UInt8],
                             path: String) throws -> (Int64, [UInt8])? {
        var i = from
        while i < before && i < from + 4096 {
            if let k = validKey(try record(fd: fd, kind: kind, index: i, buf: &buf, path: path)) { return (i, k) }
            i += 1
        }
        return nil
    }

    static func indexedLookup(fd: Int32, kind: DatasetKind, map: RunMap, ssn: [UInt8], cancel: CancelToken,
                              path: String) throws -> [(offset: Int64, bytes: [UInt8])] {
        var buf = [UInt8](repeating: 0, count: kind.recordSize)
        var out: [(offset: Int64, bytes: [UInt8])] = []
        for run in map.runs {
            let runStart = run[0], runEnd = run[1]
            // Lower bound: first valid record in the run with SSN >= target.
            var lo = runStart, hi = runEnd
            while lo < hi {
                if cancel.isCancelled { throw ScanError.cancelled }
                let mid = lo + (hi - lo) / 2
                guard let (m, k) = try keyAtOrAfter(fd: fd, kind: kind, from: mid, before: hi, buf: &buf, path: path)
                else { hi = mid; continue }
                if less(k, ssn) { lo = m + 1 } else { hi = mid }
            }
            var i = lo
            while i < runEnd {
                let r = try record(fd: fd, kind: kind, index: i, buf: &buf, path: path)
                if let k = validKey(r) {
                    if k == ssn {
                        out.append((offset: i * Int64(kind.recordSize), bytes: r))
                    } else if less(ssn, k) {
                        break
                    }
                }
                i += 1
            }
        }
        return out
    }

    // MARK: - Variable-length lines (fallback when sizes are not whole records)

    /// Reads the first complete line starting at or after `offset`.
    static func line(fd: Int32, at offset: Int64, size: Int64, path: String) throws -> Line? {
        var start = offset
        var buf = [UInt8](repeating: 0, count: 2048)
        if offset > 0 {
            var pos = offset - 1
            var found = false
            while pos < size && !found {
                let n = try readAt(fd, &buf, pos, path)
                if n == 0 { return nil }
                if let i = buf[0..<n].firstIndex(of: 10) {
                    start = pos + Int64(i) + 1
                    found = true
                } else {
                    pos += Int64(n)
                }
            }
            if !found { return nil }
        }
        if start >= size { return nil }
        var out: [UInt8] = []
        var pos = start
        while pos < size {
            let n = try readAt(fd, &buf, pos, path)
            if n == 0 { break }
            if let i = buf[0..<n].firstIndex(of: 10) {
                out.append(contentsOf: buf[0..<i])
                break
            }
            out.append(contentsOf: buf[0..<n])
            pos += Int64(n)
            if out.count > 1 << 20 { break }
        }
        if out.last == 13 { out.removeLast() }
        return Line(start: start, bytes: out)
    }

    /// Samples a variable-length file and checks SSNs never decrease (separators ignored).
    static func linesSorted(fd: Int32, size: Int64, path: String) throws -> Bool {
        var prev: [UInt8]?
        for i in 0...samples {
            let off = size * Int64(i) / Int64(samples + 1)
            guard let l = try line(fd: fd, at: off, size: size, path: path), let k = validKey(l.bytes) else { continue }
            if let p = prev, less(k, p) { return false }
            prev = k
        }
        return true
    }

    static func resyncLookup(fd: Int32, size: Int64, ssn: [UInt8], cancel: CancelToken,
                             path: String) throws -> [(offset: Int64, bytes: [UInt8])] {
        // Invariant: every line starting before `lo` has SSN < target.
        var lo: Int64 = 0
        var hi: Int64 = size
        while hi - lo > 4096 {
            if cancel.isCancelled { throw ScanError.cancelled }
            let mid = lo + (hi - lo) / 2
            // Probe the first non-separator line at or after mid.
            var probe = try line(fd: fd, at: mid, size: size, path: path)
            var hops = 0
            while let p = probe, validKey(p.bytes) == nil, hops < 64 {
                probe = try line(fd: fd, at: p.start + 1, size: size, path: path)
                hops += 1
            }
            guard let l = probe, let k = validKey(l.bytes) else { hi = mid; continue }
            if less(k, ssn) { lo = l.start + 1 } else { hi = mid }
        }
        var out: [(offset: Int64, bytes: [UInt8])] = []
        var pos = lo
        while let l = try line(fd: fd, at: pos, size: size, path: path) {
            if let k = validKey(l.bytes) {
                if k == ssn {
                    out.append((offset: l.start, bytes: l.bytes))
                } else if less(ssn, k) {
                    break
                }
            }
            pos = l.start + Int64(l.bytes.count) + 1
            if cancel.isCancelled { throw ScanError.cancelled }
        }
        return out
    }

    /// Finds every record with this SSN, or returns nil when the file can't be binary-searched
    /// (too many runs, or unsorted variable-length lines) and must be scanned instead.
    public static func lookup(path: String, kind: DatasetKind, ssn: [UInt8], cancel: CancelToken) throws -> LookupResult? {
        if let map = try runMap(path: path, kind: kind) {
            guard map.searchable else { return nil }
            let fd = open(path, O_RDONLY)
            guard fd >= 0 else { throw ScanError.open(path, errno) }
            defer { close(fd) }
            let hits = try indexedLookup(fd: fd, kind: kind, map: map, ssn: ssn, cancel: cancel, path: path)
            let runs = map.runs.count
            return LookupResult(hits: hits, method: "binary search (\(runs) sorted run\(runs == 1 ? "" : "s"))")
        }
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw ScanError.open(path, errno) }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw ScanError.read(path, errno) }
        let size = Int64(st.st_size)
        guard try linesSorted(fd: fd, size: size, path: path) else { return nil }
        let hits = try resyncLookup(fd: fd, size: size, ssn: ssn, cancel: cancel, path: path)
        return LookupResult(hits: hits, method: "binary search (line resync)")
    }
}
