import XCTest
@testable import NumidentCore

final class SearchEngineTests: XCTestCase {
    static var root: String = ""
    static var stats = SyntheticDataset.Stats()

    override class func setUp() {
        SSNIndex.diskCacheEnabled = false
        root = (NSTemporaryDirectory() as NSString).appendingPathComponent("numident-tests/engine-\(UUID().uuidString.prefix(8))")
        var c = SyntheticDataset.Config.fixture(persons: 60_000)
        c.truncate = [:]
        stats = try! SyntheticDataset.generate(at: root, config: c)
    }

    override class func tearDown() {
        try? FileManager.default.removeItem(atPath: root)
    }

    var files: [CatalogFile] { Catalog.scan(root: Self.root).allFiles }

    func testFullScanProgressTotalsAndMatches() async throws {
        var q = SearchQuery()
        q.lastName = "SMITH"
        var started: SearchProgress?
        var last: SearchProgress?
        var matches: [NumidentRecord] = []
        var summary: SearchSummary?
        var progressEvents = 0
        let opts = SearchOptions(concurrency: 3, resultCap: 1_000_000, progressInterval: 0.01, chunkSize: 64 * 1024)
        for await e in SearchEngine.search(q, files: files, options: opts) {
            switch e {
            case .started(let p): started = p
            case .progress(let p): last = p; progressEvents += 1
            case .matches(let m): matches += m
            case .fileFailed: XCTFail("no failures expected")
            case .finished(let s): summary = s
            }
        }
        let total = files.reduce(0) { $0 + $1.size }
        XCTAssertEqual(started?.totalBytes, total)
        XCTAssertEqual(last?.doneBytes, total)
        XCTAssertEqual(last?.fraction, 1)
        XCTAssertEqual(summary?.bytesRead, total)
        XCTAssertEqual(summary?.cancelled, false)
        XCTAssertGreaterThan(progressEvents, 0)
        XCTAssertFalse(matches.isEmpty)
        XCTAssertEqual(summary?.matchCount, matches.count)
        XCTAssertTrue(matches.allSatisfy { r in
            r.kind == .death ? (1...3).contains { r.value("d\($0).last") == "SMITH" } : r.lastName == "SMITH"
        })
        XCTAssertEqual(Set(last!.perSet.keys), Set(DatasetKind.allCases))
        for (_, sp) in last!.perSet { XCTAssertEqual(sp.done, sp.total) }

        // Soundex picks up SMYTH / SMYTHE too.
        q.nameMatch = .soundex
        let (sx, _) = await SearchEngine.collect(q, files: files)
        XCTAssertGreaterThan(sx.count, matches.count)
        XCTAssertTrue(sx.contains { $0.lastName == "SMYTHE" })
    }

    func testCancelKeepsMatchesAndReportsPartialProgress() async throws {
        var q = SearchQuery()
        q.lastName = "SMITH"
        // One reader, tiny chunks: the scan takes long enough to cancel midway.
        let opts = SearchOptions(concurrency: 1, progressInterval: 0.005, chunkSize: 2048)
        let handle = SearchEngine.start(q, files: files, options: opts)
        var matches: [NumidentRecord] = []
        var summary: SearchSummary?
        var cancelledAt: Date?
        for await e in handle.events {
            switch e {
            case .matches(let m):
                matches += m
            case .progress(let p):
                if cancelledAt == nil && p.doneBytes > 0 && !matches.isEmpty {
                    handle.cancel()
                    cancelledAt = Date()
                }
            case .finished(let s):
                summary = s
            default:
                break
            }
        }
        let s = try XCTUnwrap(summary)
        XCTAssertTrue(s.cancelled)
        XCTAssertFalse(s.hitCap)
        XCTAssertLessThan(s.bytesRead, s.totalBytes)
        XCTAssertFalse(matches.isEmpty, "matches found before the cancel are kept")
        XCTAssertEqual(s.matchCount, matches.count)
        XCTAssertTrue(s.outcomes.contains { $0.state == .cancelled })
        XCTAssertTrue(s.outcomes.contains { $0.state == .done } || s.outcomes.allSatisfy { $0.state == .cancelled })
        // Workers stop within a chunk, so the summary arrives almost immediately.
        XCTAssertLessThan(Date().timeIntervalSince(try XCTUnwrap(cancelledAt)), 1.0)
    }

    func testDroppingTheStreamStopsWorkers() async throws {
        var q = SearchQuery()
        q.lastName = "NOBODYHASTHISNAME"
        let handle = SearchEngine.start(q, files: files, options: SearchOptions(concurrency: 1, chunkSize: 2048))
        let task = Task { for await _ in handle.events {} }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        _ = await task.value
        XCTAssertTrue(handle.isCancelled)
    }

    func testScannerChecksCancelEveryChunk() throws {
        let path = files.first { $0.kind == .ss5 }!.path
        let token = CancelToken()
        var bytes = 0
        var chunks = 0
        XCTAssertThrowsError(try LineScanner.scan(path: path, buffer: ScanBuffer(chunkSize: 4096), cancel: token,
                                                  progress: { n in
                                                      bytes += n
                                                      chunks += 1
                                                      if chunks == 3 { token.cancel() }
                                                  }) { _, _ in }) { e in
            guard case ScanError.cancelled = e else { return XCTFail("\(e)") }
        }
        XCTAssertEqual(chunks, 3)
        XCTAssertEqual(bytes, 3 * 4096)
    }

    func testResultCap() async throws {
        var q = SearchQuery()
        q.lastName = "S"
        q.nameMatch = .prefix
        let (hits, s) = await SearchEngine.collect(q, files: files, options: SearchOptions(resultCap: 25))
        XCTAssertEqual(hits.count, 25)
        XCTAssertEqual(s?.hitCap, true)
        XCTAssertEqual(s?.cancelled, false)
    }

    func testSetSelectionAndSkippedSets() async throws {
        var q = SearchQuery()
        q.deathYearFrom = 1990
        q.deathYearTo = 1995
        let (hits, s) = await SearchEngine.collect(q, files: files)
        XCTAssertFalse(hits.isEmpty)
        XCTAssertFalse(hits.contains { $0.kind == .ss5 })
        XCTAssertNotNil(s?.skipped[.ss5])
        XCTAssertFalse(s!.outcomes.contains { $0.file.kind == .ss5 })
        XCTAssertTrue(hits.allSatisfy { r in
            let years = r.kind == .death ? r.deathPostings.compactMap(\.dod.year) : [r.deathDate.year ?? 0]
            return years.contains { (1990...1995).contains($0) }
        })

        // Only the files passed in are read.
        let deathOnly = files.filter { $0.kind == .death }
        var q2 = SearchQuery()
        q2.lastName = "BAKER"
        let (h2, s2) = await SearchEngine.collect(q2, files: deathOnly)
        XCTAssertTrue(h2.allSatisfy { $0.kind == .death })
        XCTAssertEqual(s2?.totalBytes, deathOnly.reduce(0) { $0 + $1.size })
    }

    func testIOErrorsAreReportedPerFile() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let good = files.first { $0.kind == .claim }!
        // A directory opens fine but read() fails with EISDIR; a vanished file fails to open.
        let isDir = CatalogFile(kind: .claim, number: 2, path: dir, size: 1000)
        let gone = CatalogFile(kind: .claim, number: 3, path: dir + "/gone.txt", size: 1000)
        var q = SearchQuery()
        q.lastName = "SMITH"
        var failures: [String] = []
        var summary: SearchSummary?
        for await e in SearchEngine.search(q, files: [good, isDir, gone]) {
            if case .fileFailed(let f, let m) = e { failures.append("\(f): \(m)") }
            if case .finished(let s) = e { summary = s }
        }
        XCTAssertEqual(failures.count, 2, "\(failures)")
        XCTAssertEqual(summary?.failed.count, 2)
        XCTAssertEqual(summary?.outcomes.first { $0.file.path == good.path }?.state, .done)
    }

    func testPersonSummaryMergesRecords() async throws {
        // Find an SSN that has SS-5 and death records.
        var chosen: [NumidentRecord] = []
        for ssn in Self.stats.sampleSSNs {
            let (recs, _) = await SearchEngine.collect(.ssn(ssn), files: files)
            if Set(recs.map(\.kind)).isSuperset(of: [.ss5, .death]) { chosen = recs; break }
        }
        XCTAssertFalse(chosen.isEmpty)
        let p = PersonSummary(ssn: chosen[0].ssn, records: chosen, coverageNotes: ["note"])
        XCTAssertFalse(p.names.isEmpty)
        XCTAssertFalse(p.birthDates.isEmpty)
        XCTAssertFalse(p.deathDates.isEmpty)
        XCTAssertTrue(p.timeline.contains { $0.kind == .ss5 })
        XCTAssertTrue(p.timeline.contains { $0.kind == .death })
        XCTAssertEqual(p.timeline.map(\.date.sortKey), p.timeline.map(\.date.sortKey).sorted())
    }

    func testConflictsDetected() {
        // Death postings 1 and 3 disagree on birth year.
        var b = LineBuilder()
        b.put(13, "123456789"); b.put(27, "T")
        for (i, y) in [(0, "1900"), (1, "1900"), (2, "1901")] {
            let o = i * 150
            b.put(37 + o, "ANNA"); b.put(69 + o, "BAKER")
            b.put(97 + o, "0101" + y); b.put(105 + o, "2"); b.put(145 + o, "02021980")
        }
        var s5 = LineBuilder()
        s5.put(13, "123456789"); s5.put(37, "ANNA"); s5.put(69, "BAKER"); s5.put(97, "01011900"); s5.put(105, "1")
        let p = PersonSummary(ssn: "123456789", records: [
            NumidentRecord(kind: .death, line: b.string(.death), fileName: "d", offset: 0),
            NumidentRecord(kind: .ss5, line: s5.string(.ss5), fileName: "s", offset: 0),
        ])
        XCTAssertTrue(p.conflicts.contains { $0.contains("date of birth") })
        XCTAssertTrue(p.conflicts.contains { $0.contains("sex") })
        XCTAssertEqual(p.deathDates.count, 1)
    }
}
