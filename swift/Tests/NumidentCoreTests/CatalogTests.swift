import XCTest
@testable import NumidentCore

func makeTempDir(_ name: String = #function) throws -> String {
    let dir = (NSTemporaryDirectory() as NSString)
        .appendingPathComponent("numident-tests/\(name.filter { $0.isLetter || $0.isNumber })-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

final class CatalogTests: XCTestCase {
    func testFixtureHealth() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try SyntheticDataset.generate(at: root, config: .fixture(persons: 3_000))
        // macOS AppleDouble junk on exFAT volumes must be ignored.
        FileManager.default.createFile(atPath: root + "/NUMSS5/._NUMSS501_PU.txt", contents: Data(count: 4096))
        FileManager.default.createFile(atPath: root + "/NUMSS5/.DS_Store", contents: Data(count: 10))
        FileManager.default.createFile(atPath: root + "/._NUMSS5", contents: Data(count: 4096))

        let h = Catalog.scan(root: root)
        XCTAssertTrue(h.rootExists)
        XCTAssertFalse(h.isComplete)

        let clm = try XCTUnwrap(h.set(.claim))
        XCTAssertEqual(clm.presentCount, 10)
        XCTAssertEqual(clm.missingNumbers, Array(2...11))
        XCTAssertEqual(clm.summary, "NUMCLM: 10 of 20 files present (missing 02–11)")
        XCTAssertTrue(clm.suspectFiles.isEmpty)

        let ss5 = try XCTUnwrap(h.set(.ss5))
        XCTAssertEqual(ss5.presentCount, 20)
        XCTAssertTrue(ss5.isComplete, ss5.summary)
        XCTAssertTrue(ss5.extraFiles.isEmpty)

        let death = try XCTUnwrap(h.set(.death))
        XCTAssertEqual(death.missingNumbers, [])
        let d3 = try XCTUnwrap(death.files.first { $0.number == 3 })
        XCTAssertTrue(d3.problems.contains(.truncated))
        XCTAssertTrue(d3.problems.contains { if case .partialRecord = $0 { return true }; return false })
        XCTAssertTrue(d3.isUsable, "truncated files are still searchable")
        XCTAssertEqual(death.suspectFiles.map(\.number), [3])
    }

    func testEmptySmallAndBadFiles() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        var c = SyntheticDataset.Config()
        c.persons = 4_000
        c.filesPerSet = 5
        try SyntheticDataset.generate(at: root, config: c)
        // Empty file, a tiny file, a file with the wrong format, and an unreadable one.
        let dir = root + "/NUMSS5/"
        FileManager.default.createFile(atPath: dir + "NUMSS506_PU.txt", contents: Data())
        let one = SyntheticDataset.separatorLine(.ss5)
        FileManager.default.createFile(atPath: dir + "NUMSS507_PU.txt", contents: Data(one))
        FileManager.default.createFile(atPath: dir + "NUMSS508_PU.txt", contents: "hello world\n".data(using: .utf8))
        FileManager.default.createFile(atPath: dir + "NUMSS509_PU.txt", contents: Data(one))
        chmod(dir + "NUMSS509_PU.txt", 0)
        defer { chmod(dir + "NUMSS509_PU.txt", 0o644) }

        let s = try XCTUnwrap(Catalog.scan(root: root).set(.ss5))
        func f(_ n: Int) -> CatalogFile { s.files.first { $0.number == n }! }
        XCTAssertEqual(f(6).problems, [.empty])
        XCTAssertFalse(f(6).isUsable)
        XCTAssertTrue(f(7).problems.contains { if case .small = $0 { return true }; return false })
        XCTAssertTrue(f(8).problems.contains { if case .badFormat = $0 { return true }; return false })
        XCTAssertFalse(f(9).isUsable)
        XCTAssertTrue(f(9).problems.contains { if case .unreadable = $0 { return true }; return false })
        XCTAssertEqual(s.missingNumbers, Array(10...20))
        XCTAssertEqual(s.usableFiles.count, 7)
    }

    func testMissingRootAndVolume() {
        let h = Catalog.scan(root: "/Volumes/NoSuchVolume-\(UUID().uuidString)/NUMIDENT")
        XCTAssertFalse(h.rootExists)
        XCTAssertNotNil(h.unmountedVolume)
        XCTAssertTrue(h.headline.contains("not mounted"))
        XCTAssertEqual(h.sets.count, 3)
        XCTAssertTrue(h.sets.allSatisfy { !$0.isAvailable })
    }

    func testFormatRanges() {
        XCTAssertEqual(formatRanges(Array(2...11)), "02–11")
        XCTAssertEqual(formatRanges([3, 5, 6, 7, 20]), "03, 05–07, 20")
        XCTAssertEqual(formatRanges([]), "")
    }

    func testCoverageNotes() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try SyntheticDataset.generate(at: root, config: .fixture(persons: 1_000))
        let h = Catalog.scan(root: root)
        let searched = h.allFiles.filter { $0.kind != .death }
        let notes = Coverage.notes(health: h, searched: searched)
        XCTAssertTrue(notes.contains { $0.contains("NUMCLM") && $0.contains("02–11") && $0.contains("not conclusive") })
        XCTAssertTrue(notes.contains { $0.contains("NUMDEATH was not searched") })
    }
}
