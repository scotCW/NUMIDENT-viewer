import XCTest
@testable import NumidentCore

final class ScannerTests: XCTestCase {
    override func setUp() {
        SSNIndex.diskCacheEnabled = false
    }

    /// Reference implementation: split the whole file in memory.
    func referenceLines(_ path: String) throws -> [(Int64, [UInt8])] {
        let data = try [UInt8](Data(contentsOf: URL(fileURLWithPath: path)))
        var out: [(Int64, [UInt8])] = []
        var start = 0
        for i in data.indices where data[i] == 10 {
            var line = Array(data[start..<i])
            if line.last == 13 { line.removeLast() }
            out.append((Int64(start), line))
            start = i + 1
        }
        if start < data.count { out.append((Int64(start), Array(data[start...]))) }
        return out
    }

    func scanAll(_ path: String, chunk: Int) throws -> (lines: [(Int64, [UInt8])], bytes: Int) {
        var lines: [(Int64, [UInt8])] = []
        var bytes = 0
        try LineScanner.scan(path: path, buffer: ScanBuffer(chunkSize: chunk), cancel: CancelToken(),
                             progress: { bytes += $0 }) { line, off in lines.append((off, Array(line))) }
        return (lines, bytes)
    }

    func testChunkBoundariesCRLFAndLF() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        var c = SyntheticDataset.Config()
        c.persons = 3_000
        c.filesPerSet = 2
        try SyntheticDataset.generate(at: root, config: c)
        for path in [root + "/NUMDEATH/NUMDEATH01_PU.TXT", root + "/NUMSS5/NUMSS501_PU.txt"] {
            let ref = try referenceLines(path)
            let size = try FileManager.default.attributesOfItem(atPath: path)[.size] as! Int
            // Chunk sizes that split records in every possible place, plus the production size.
            for chunk in [64, 487, 500, 501, 1000, 4096, 65_537, 4 << 20] {
                let got = try scanAll(path, chunk: chunk)
                XCTAssertEqual(got.bytes, size, "chunk \(chunk)")
                XCTAssertEqual(got.lines.count, ref.count, "chunk \(chunk)")
                XCTAssertTrue(zip(got.lines, ref).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }, "chunk \(chunk)")
            }
            XCTAssertFalse(ref.contains { $0.1.last == 13 })
        }
    }

    func testTrimmedLinesAndMissingFinalNewline() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        var b = LineBuilder()
        b.put(13, "123456789")
        b.put(69, "SHORT")
        var data = b.line(length: nil, crlf: true) + b.line(length: nil, crlf: false)
        data += Array("tail-without-newline".utf8)
        let path = root + "/x.txt"
        FileManager.default.createFile(atPath: path, contents: Data(data))
        let got = try scanAll(path, chunk: 7)
        XCTAssertEqual(got.lines.count, 3)
        XCTAssertEqual(got.lines[0].1.count, 73)
        XCTAssertEqual(got.lines[1].1, got.lines[0].1)
        XCTAssertEqual(String(decoding: got.lines[2].1, as: UTF8.self), "tail-without-newline")
        // Fields past the end of a trimmed line read as blanks.
        let r = NumidentRecord(kind: .ss5, fileName: "x", offset: 0, bytes: got.lines[0].1)
        XCTAssertEqual(r.lastName, "SHORT")
        XCTAssertEqual(r.value("pobCity"), "")
    }

    func testRunMapFindsLeadingBlockAndSkipsSeparators() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        var c = SyntheticDataset.Config()
        c.persons = 40_000
        c.filesPerSet = 3
        c.separatorEvery = 997
        try SyntheticDataset.generate(at: root, config: c)
        for kind in DatasetKind.allCases {
            let path = root + "/\(kind.rawValue)/" + SyntheticDataset.fileName(kind, 2)
            let map = try XCTUnwrap(SSNIndex.runMap(path: path, kind: kind))
            XCTAssertEqual(map.runs.count, 2, "\(kind): leading block + main run")
            XCTAssertTrue(map.searchable)
            // Ground truth: every descent in valid SSNs is a run boundary.
            let ref = try referenceLines(path)
            var boundaries: [Int64] = []
            var last: [UInt8]?
            for (i, l) in ref.enumerated() {
                guard let k = SSNIndex.validKey(l.1) else { continue }
                if let p = last, k.lexicographicallyPrecedes(p) { boundaries.append(Int64(i)) }
                last = k
            }
            XCTAssertEqual(map.runs.dropFirst().map { $0[0] }, boundaries)
        }
    }

    func testSSNLookupMatchesFullScan() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        var c = SyntheticDataset.Config()
        c.persons = 30_000
        c.filesPerSet = 4
        c.separatorEvery = 500
        let stats = try SyntheticDataset.generate(at: root, config: c)
        let files = Catalog.scan(root: root).allFiles
        // Sample SSNs include the very first and last persons, which land in leading blocks.
        var ssns = Array(stats.sampleSSNs.prefix(40))
        ssns.append(stats.sampleSSNs.last!)
        ssns.append("000000001")
        for ssn in ssns {
            let (fast, s1) = await SearchEngine.collect(.ssn(ssn), files: files)
            XCTAssertEqual(s1?.mode, .ssnLookup)
            XCTAssertTrue(s1!.outcomes.allSatisfy { $0.method.hasPrefix("binary search") }, "\(s1!.outcomes.map(\.method))")
            // Same query forced through a full scan: SSN plus a no-op filter still uses lookup,
            // so compare against a direct line scan instead.
            var slow: [String] = []
            for f in files {
                try LineScanner.scan(path: f.path, buffer: ScanBuffer(), cancel: CancelToken(), progress: { _ in }) { l, off in
                    if l.count >= 21 && Array(l[12..<21]) == Array(ssn.utf8) { slow.append("\(f.name):\(off)") }
                }
            }
            XCTAssertEqual(Set(fast.map(\.id)), Set(slow), "SSN \(ssn)")
            if ssn != "000000001" { XCTAssertFalse(fast.isEmpty, "SSN \(ssn) should exist") }
        }
    }

    /// Reproduces the real NUMCLM14 / NUMCLM20 / NUMDEATH03 shape: a short ascending leading block
    /// whose SSNs are above the main run's first SSN but below the next sample point, so sampling
    /// alone never sees a drop. Lookups must find both the block records and those just after the drop.
    func testHiddenLeadingBlockIsFound() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        for kind in DatasetKind.allCases {
            try FileManager.default.createDirectory(atPath: root + "/\(kind.rawValue)", withIntermediateDirectories: true)
            func line(_ ssn: Int, _ name: String) -> [UInt8] {
                var b = LineBuilder()
                b.put(13, String(format: "%09d", ssn))
                b.put(37, "TEST")
                b.put(69, name)
                return b.line(kind)
            }
            // Main run: 60,000 records, SSN 001010100 + 10·i (sample spacing ≈ 43 records → ~430 SSNs).
            // Leading block: 29 records 001010105 + 3·k, all between the main run's records 0 and ~9.
            let mainStart = 1_010_100
            var data: [UInt8] = []
            var expected: [String: String] = [:]
            for k in 0..<29 {
                let ssn = 1_010_105 + 3 * k
                data += line(ssn, "BLOCK\(k)")
                expected[String(format: "%09d", ssn), default: ""] += "BLOCK\(k)"
            }
            for i in 0..<60_000 {
                let ssn = mainStart + 10 * i
                data += line(ssn, "MAIN\(i)")
                expected[String(format: "%09d", ssn), default: ""] += "MAIN\(i)"
                if i == 30_000 { data += SyntheticDataset.separatorLine(kind) }
            }
            let path = root + "/\(kind.rawValue)/" + SyntheticDataset.fileName(kind, 1)
            FileManager.default.createFile(atPath: path, contents: Data(data))

            let map = try XCTUnwrap(SSNIndex.runMap(path: path, kind: kind))
            XCTAssertEqual(map.runs, [[0, 29], [29, 60_030]], "\(kind)")

            let f = CatalogFile(kind: kind, number: 1, path: path, size: Int64(data.count))
            // Block records (incl. index 0, 7, 28), main-run records just after the drop, and later ones.
            let probes = [1_010_105, 1_010_105 + 3 * 7, 1_010_105 + 3 * 28,
                          mainStart, mainStart + 10, mainStart + 10 * 5, mainStart + 10 * 29,
                          mainStart + 10 * 30_000, mainStart + 10 * 59_999]
            for ssn in probes {
                let s = String(format: "%09d", ssn)
                let (hits, summary) = await SearchEngine.collect(.ssn(s), files: [f])
                XCTAssertEqual(hits.map(\.lastName).joined(), expected[s], "\(kind) \(s)")
                XCTAssertEqual(summary?.outcomes.first?.method, "binary search (2 sorted runs)")
            }
        }
    }

    func testUnsortedFileFallsBackToFullScan() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        var c = SyntheticDataset.Config()
        c.persons = 20_000
        c.filesPerSet = 1
        c.leadingBlock = false
        let stats = try SyntheticDataset.generate(at: root, config: c)
        // Shuffle NUMSS5 records so there are far more than 64 runs.
        let path = root + "/NUMSS5/" + SyntheticDataset.fileName(.ss5, 1)
        let data = try [UInt8](Data(contentsOf: URL(fileURLWithPath: path)))
        let rs = DatasetKind.ss5.recordSize
        var recs = (0..<(data.count / rs)).map { Array(data[($0 * rs)..<(($0 + 1) * rs)]) }
        var g = SystemRandomNumberGenerator()
        recs.shuffle(using: &g)
        FileManager.default.createFile(atPath: path, contents: Data(recs.flatMap { $0 }))

        let map = try XCTUnwrap(SSNIndex.runMap(path: path, kind: .ss5))
        XCTAssertFalse(map.searchable)
        let files = Catalog.scan(root: root).allFiles.filter { $0.kind == .ss5 }
        let ssn = stats.sampleSSNs[stats.sampleSSNs.count / 2]
        let (hits, summary) = await SearchEngine.collect(.ssn(ssn), files: files)
        XCTAssertFalse(hits.isEmpty)
        XCTAssertTrue(summary!.outcomes[0].method.contains("full scan"))
    }

    func testVariableLengthFileUsesLineResync() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root + "/NUMSS5", withIntermediateDirectories: true)
        var out: [UInt8] = []
        for i in 0..<5_000 {
            var b = LineBuilder()
            b.put(13, String(format: "%09d", 100_000 + i * 3))
            b.put(69, "PERSON\(i)")
            out += b.line(length: nil, crlf: false) // trimmed: not a whole number of records
        }
        let path = root + "/NUMSS5/NUMSS501_PU.txt"
        FileManager.default.createFile(atPath: path, contents: Data(out))
        XCTAssertNil(try SSNIndex.runMap(path: path, kind: .ss5))
        let f = CatalogFile(kind: .ss5, number: 1, path: path, size: Int64(out.count))
        let (hits, summary) = await SearchEngine.collect(.ssn(String(format: "%09d", 100_000 + 4_321 * 3)), files: [f])
        XCTAssertEqual(hits.map(\.lastName), ["PERSON4321"])
        XCTAssertEqual(summary?.outcomes.first?.method, "binary search (line resync)")
    }
}
