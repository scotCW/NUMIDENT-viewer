import XCTest
@testable import NumidentCore

final class LastNameIndexTests: XCTestCase {
    static var root: String = ""

    override class func setUp() {
        SSNIndex.diskCacheEnabled = false
        root = (NSTemporaryDirectory() as NSString).appendingPathComponent("numident-tests/lnindex-\(UUID().uuidString.prefix(8))")
        var c = SyntheticDataset.Config.fixture(persons: 20_000)
        c.truncate = [:]
        _ = try! SyntheticDataset.generate(at: root, config: c)
    }

    override class func tearDown() {
        try? FileManager.default.removeItem(atPath: root)
    }

    var files: [CatalogFile] { Catalog.scan(root: Self.root).allFiles.filter(\.isUsable) }

    override func setUp() {
        // Make the engine fetch every candidate rather than fall back to scanning small files.
        SearchEngine.fetchCost = 1
    }

    override func tearDown() {
        SearchEngine.fetchCost = 50_000
    }

    private func build() throws -> LastNameIndex {
        try LastNameIndexBuilder.build(root: Self.root, files: files, cancel: CancelToken())
        return try XCTUnwrap(LastNameIndex.open(root: Self.root))
    }

    private func ids(_ q: SearchQuery, index: LastNameIndex?) async -> ([String], SearchSummary?) {
        let opts = SearchOptions(concurrency: 2, resultCap: 1_000_000, lastNameIndex: index)
        let (rs, s) = await SearchEngine.collect(q, files: files, options: opts)
        return (rs.map(\.id).sorted(), s)
    }

    func testIndexedResultsMatchFullScan() async throws {
        let index = try build()
        XCTAssertEqual(index.manifest.files.count, files.count)
        XCTAssertTrue(files.allSatisfy { index.fileNumber(for: $0) != nil })

        var queries: [SearchQuery] = []
        func q(_ last: String, _ mode: NameMatch = .exact, _ edit: (inout SearchQuery) -> Void = { _ in }) {
            var s = SearchQuery()
            s.lastName = last
            s.nameMatch = mode
            edit(&s)
            queries.append(s)
        }
        q("SMITH")
        q("smith ")                                   // case and spaces
        q("SMI", .prefix)
        q("S", .prefix)
        q("SMYTH", .soundex)
        q("PETERSON") { $0.firstName = "HENRY" }
        q("MURPHY") { $0.includeOtherNames = true }
        q("MURPHY") { $0.dobYearFrom = 1900; $0.dobYearTo = 1930 }
        q("SCOTT") { $0.deathYearFrom = 1950 }
        q("JOHNSON") { $0.fatherFirst = "JOHN" }
        q("NOSUCHNAME")

        for query in queries {
            let (indexed, s) = await ids(query, index: index)
            let (scanned, _) = await ids(query, index: nil)
            XCTAssertEqual(indexed, scanned, "\(query.lastName) \(query.nameMatch)")
            XCTAssertTrue(s?.outcomes.allSatisfy { $0.method.hasPrefix("last-name index") } ?? false,
                          "every file should be served by the index for \(query.lastName)")
        }
    }

    func testChangedFileIsScannedInstead() async throws {
        let index = try build()
        let victim = try XCTUnwrap(files.first { $0.kind == .claim })
        // A different modification time means the index no longer vouches for this file.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(3600)], ofItemAtPath: victim.path)
        let refreshed = try XCTUnwrap(files.first { $0.path == victim.path })
        XCTAssertNil(index.fileNumber(for: refreshed))

        var q = SearchQuery()
        q.lastName = "SMITH"
        let (indexed, s) = await ids(q, index: index)
        let (scanned, _) = await ids(q, index: nil)
        XCTAssertEqual(indexed, scanned)
        let outcome = try XCTUnwrap(s?.outcomes.first { $0.file.path == victim.path })
        XCTAssertEqual(outcome.method, "full scan")
    }

    func testTooManyCandidatesFallsBackToScanning() async throws {
        let index = try build()
        XCTAssertNil(try index.candidates(lastName: "S", mode: .prefix, limit: 10))
        SearchEngine.fetchCost = 50_000 // the real threshold: these small files are cheaper to scan
        var q = SearchQuery()
        q.lastName = "SMITH"
        let (indexed, s) = await ids(q, index: index)
        let (scanned, _) = await ids(q, index: nil)
        XCTAssertEqual(indexed, scanned)
        // Files with more candidates than size / fetchCost are scanned; the rest use the index.
        let groups = try XCTUnwrap(try index.candidates(lastName: "SMITH", mode: .exact))
        for o in try XCTUnwrap(s?.outcomes) {
            let n = groups[try XCTUnwrap(index.fileNumber(for: o.file))]?.count ?? 0
            let expectIndex = Int64(n) <= o.file.size / SearchEngine.fetchCost
            XCTAssertEqual(o.method.hasPrefix("last-name index"), expectIndex, o.file.name)
        }
        XCTAssertTrue(s?.outcomes.contains { $0.method == "full scan" } ?? false)
    }

    func testRebuildReplacesIndexAndCancelLeavesOldOne() throws {
        let first = try build()
        let cancel = CancelToken()
        cancel.cancel()
        XCTAssertThrowsError(try LastNameIndexBuilder.build(root: Self.root, files: files, cancel: cancel))
        let still = try XCTUnwrap(LastNameIndex.open(root: Self.root))
        XCTAssertEqual(still.manifest.built, first.manifest.built)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: (Self.root as NSString).appendingPathComponent(LastNameIndex.folderName + ".partial")))
    }

    func testNoIndexFolderMeansNoIndex() {
        let empty = (NSTemporaryDirectory() as NSString).appendingPathComponent("numident-tests/none-\(UUID().uuidString.prefix(8))")
        XCTAssertNil(LastNameIndex.open(root: empty))
    }
}
