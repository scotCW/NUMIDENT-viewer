import XCTest
@testable import NumidentCore

final class CSVConverterTests: XCTestCase {
    /// A fake record split into three padded fields, with the SSN in columns 13–21.
    func row(_ ssn: String, kind: DatasetKind = .claim, fill: Character = "A") -> (csv: String, line: String) {
        let head = "12345678901 " + ssn
        let rest = String(repeating: fill, count: kind.lineLength - head.count)
        return ("\(head),\(rest.prefix(10)),\(rest.dropFirst(10))", head + rest)
    }

    func convert(_ csv: Data, kind: DatasetKind = .claim, in dir: String) throws -> (CSVConvertResult, Data) {
        let source = dir + "/in.csv", target = dir + "/out.txt"
        try csv.write(to: URL(fileURLWithPath: source))
        let result = try CSVConverter.convert(source: source, target: target, kind: kind)
        return (result, try Data(contentsOf: URL(fileURLWithPath: target)))
    }

    let header = "REF-SSN,NAME,REST\n"

    func testRebuildsFixedWidthRecords() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let a = row("001010002"), b = row("ZZZZZZZZZ")
        let (result, out) = try convert(Data((header + a.csv + "\n" + b.csv + "\n").utf8), in: dir)
        XCTAssertEqual(result.written, 2)
        XCTAssertEqual(result.masked, 1)
        XCTAssertEqual(result.skipped, [])
        XCTAssertEqual(out, Data((a.line + "\n" + b.line + "\n").utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/out.txt.partial"))
    }

    func testDeathRecordsGetCRLF() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let a = row("001010002", kind: .death)
        let (_, out) = try convert(Data((header + a.csv + "\r\n").utf8), kind: .death, in: dir)
        XCTAssertEqual(out, Data((a.line + "\r\n").utf8))
        XCTAssertEqual(out.count, DatasetKind.death.recordSize)
    }

    func testOutputReadsAsAWellFormedFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let rows = (0..<5).map { row(String(format: "00101%04d", $0)) }
        let csv = header + rows.map(\.csv).joined(separator: "\n") + "\n"
        let folder = dir + "/NUMCLM"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try Data(csv.utf8).write(to: URL(fileURLWithPath: dir + "/in.csv"))
        _ = try CSVConverter.convert(source: dir + "/in.csv", target: folder + "/NUMCLM01_PU.txt", kind: .claim)
        let file = try XCTUnwrap(Catalog.scan(root: dir).set(.claim)?.files.first)
        XCTAssertTrue(file.isUsable)
        XCTAssertEqual(file.problems, [])
    }

    func testQuotedFieldsAndUnterminatedLastRow() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let a = row("001010002")
        let head = "12345678901 001010002"
        // A comma and a doubled quote inside quoted fields.
        let rest = String(repeating: "A", count: DatasetKind.claim.lineLength - head.count - 4)
        let csv = header + "\(head),\"B,C\",\"\"\"\(rest)\"\n" + a.csv
        let (result, out) = try convert(Data(csv.utf8), in: dir)
        XCTAssertEqual(result.written, 2)
        XCTAssertEqual(out, Data((head + "B,C\"" + rest + "\n" + a.line + "\n").utf8))
    }

    func testBadRowsAreSkippedAndListed() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let good = row("001010002")
        let short = "too,short,row"
        let extra = good.csv + ","
        let csv = header + short + "\n\n" + good.csv + "\n" + extra + "\n"
        let (result, out) = try convert(Data(csv.utf8), in: dir)
        XCTAssertEqual(result.written, 1)
        // Line numbers are the CSV's own, counting the blank line.
        XCTAssertEqual(result.skipped.map(\.line), [2, 5])
        XCTAssertEqual(result.skippedCount, 2)
        XCTAssertEqual(result.skipped[1].fields, 4)
        XCTAssertEqual(out, Data((good.line + "\n").utf8))
    }

    func testBytesAreCopiedUnchanged() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        var csv = Data((header + "12345678901 001010002,").utf8)
        var line = Data("12345678901 001010002".utf8)
        let rest = [UInt8](repeating: 0xE9, count: DatasetKind.claim.lineLength - line.count)
        csv.append(contentsOf: rest)
        csv.append(contentsOf: [44, 10]) // An empty third field.
        line.append(contentsOf: rest)
        line.append(10)
        let (_, out) = try convert(csv, in: dir)
        XCTAssertEqual(out, line)
    }

    func testChunkBoundariesDoNotChangeTheResult() throws {
        let csv = Array((header + row("001010002").csv + "\r\n\"A\"\"B\",C\r\n").utf8)
        func rows(_ size: Int) throws -> [String] {
            var reader = CSVConverter.RowReader(), out: [String] = []
            let add: ([UInt8], Int, Int) throws -> Void = { l, f, r in out.append("\(r):\(f):\(String(decoding: l, as: UTF8.self))") }
            var i = 0
            while i < csv.count {
                try reader.feed(csv[i..<min(i + size, csv.count)], onRow: add)
                i += size
            }
            try reader.finish(onRow: add)
            return out
        }
        let whole = try rows(csv.count)
        XCTAssertEqual(whole.count, 3)
        XCTAssertTrue(whole[2].hasSuffix(":2:A\"BC"))
        for size in [1, 2, 3, 7] { XCTAssertEqual(try rows(size), whole) }
    }

    func testRefusesToOverwriteAndLeavesNoOutputOnFailure() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let source = dir + "/in.csv", target = dir + "/out.txt"
        try Data((header + row("001010002").csv + "\n").utf8).write(to: URL(fileURLWithPath: source))
        try Data("keep".utf8).write(to: URL(fileURLWithPath: target))
        XCTAssertThrowsError(try CSVConverter.convert(source: source, target: target, kind: .claim))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: target)), Data("keep".utf8))

        // The wrong set: no row has the right width.
        let other = dir + "/other.txt"
        XCTAssertThrowsError(try CSVConverter.convert(source: source, target: other, kind: .ss5))
        XCTAssertFalse(FileManager.default.fileExists(atPath: other))
        XCTAssertFalse(FileManager.default.fileExists(atPath: other + ".partial"))

        // No SSN column in the first row.
        try Data("A,B\n1,2\n".utf8).write(to: URL(fileURLWithPath: source))
        XCTAssertThrowsError(try CSVConverter.convert(source: source, target: other, kind: .claim))
        XCTAssertFalse(FileManager.default.fileExists(atPath: other))
    }

    func testFileWithoutHeaderKeepsItsFirstRecord() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let a = row("001010002"), b = row("ZZZZZZZZZ")
        let (result, out) = try convert(Data((a.csv + "\n" + b.csv + "\n").utf8), in: dir)
        XCTAssertEqual(result.written, 2)
        XCTAssertEqual(out, Data((a.line + "\n" + b.line + "\n").utf8))
    }

    func testRowsStartOnTheLinesReported() throws {
        var reader = CSVConverter.RowReader(), lines: [Int] = []
        try reader.feed(Array("a\r\n\n\"x\ny\"\nb\rc".utf8)[...]) { _, _, line in lines.append(line) }
        try reader.finish { _, _, line in lines.append(line) }
        XCTAssertEqual(lines, [1, 3, 5, 6])
    }

    func testWrongSetGivesUpEarlyAndCapsTheList() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let source = dir + "/in.csv", target = dir + "/out.txt"
        let bad = String(repeating: "x,y,z\n", count: 5000)
        try Data((header + bad + row("001010002").csv + "\n").utf8).write(to: URL(fileURLWithPath: source))
        // The good record comes after the give-up point, so it is never reached.
        XCTAssertThrowsError(try CSVConverter.convert(source: source, target: target, kind: .claim)) {
            guard case CSVConvertError.noRecords = $0 else { return XCTFail("\($0)") }
        }
        // After a first record, bad rows are only counted and the list stays short.
        try Data((header + row("001010002").csv + "\n" + bad).utf8).write(to: URL(fileURLWithPath: source))
        let result = try CSVConverter.convert(source: source, target: target, kind: .claim)
        XCTAssertEqual(result.skippedCount, 5000)
        XCTAssertEqual(result.skipped.count, CSVConverter.maxListedSkips)
    }

    func testPartialFileIsLockedWhileInUseAndReusedWhenLeftOver() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let source = dir + "/in.csv", target = dir + "/out.txt", partial = target + ".partial"
        let a = row("001010002")
        try Data((header + a.csv + "\n").utf8).write(to: URL(fileURLWithPath: source))

        // Another conversion holds the partial file.
        let fd = open(partial, O_WRONLY | O_CREAT, 0o644)
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        XCTAssertEqual(write(fd, "theirs", 6), 6)
        XCTAssertThrowsError(try CSVConverter.convert(source: source, target: target, kind: .claim)) {
            guard case CSVConvertError.busy = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(FileManager.default.contents(atPath: partial), Data("theirs".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target))

        // Once released, it is only a leftover.
        close(fd)
        _ = try CSVConverter.convert(source: source, target: target, kind: .claim)
        XCTAssertEqual(FileManager.default.contents(atPath: target), Data((a.line + "\n").utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial))
    }

    func testDanglingSymlinkCountsAsExisting() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let source = dir + "/in.csv", target = dir + "/out.txt"
        try Data((header + row("001010002").csv + "\n").utf8).write(to: URL(fileURLWithPath: source))
        try FileManager.default.createSymbolicLink(atPath: target, withDestinationPath: dir + "/nowhere")
        XCTAssertThrowsError(try CSVConverter.convert(source: source, target: target, kind: .claim))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/nowhere"))
    }

    func testUnmatchedQuoteStopsTheConversion() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let source = dir + "/in.csv", target = dir + "/out.txt"
        try Data((header + "A,\"never closed\n" + row("001010002").csv + "\n").utf8).write(to: URL(fileURLWithPath: source))
        XCTAssertThrowsError(try CSVConverter.convert(source: source, target: target, kind: .claim))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target))
    }
}
