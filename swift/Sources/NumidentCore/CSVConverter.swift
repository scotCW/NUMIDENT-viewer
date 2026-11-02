import Foundation

public enum CSVConvertError: Error, Sendable, CustomStringConvertible {
    case targetExists(String)
    case open(String, Int32)
    case read(String, Int32)
    case write(String, Int32)
    case badHeader(String)
    case rowTooLong(row: Int)
    case noRecords
    case sizeMismatch(expected: Int64, actual: Int64)

    public var description: String {
        switch self {
        case .targetExists(let p): return "\(p) already exists; it was not changed"
        case .open(let p, let e): return "can't open \(p): \(String(cString: strerror(e)))"
        case .read(let p, let e): return "can't read \(p): \(String(cString: strerror(e)))"
        case .write(let p, let e): return "can't write \(p): \(String(cString: strerror(e)))"
        case .badHeader(let why): return "not a NUMIDENT CSV: \(why)"
        case .rowTooLong(let row): return "row \(row) is far too long, probably from an unmatched quote"
        case .noRecords: return "no row rebuilt to a whole record, so nothing was written; check the set"
        case .sizeMismatch(let e, let a): return "output is \(a) bytes, expected \(e); nothing was kept"
        }
    }
}

public struct CSVConvertResult: Sendable {
    public struct SkippedRow: Sendable, Equatable {
        /// 1-based row in the CSV, where row 1 is the header.
        public let row: Int
        public let fields: Int
        public let characters: Int
    }
    public var written = 0
    /// Written records whose SSN is all `Z`.
    public var masked = 0
    public var skipped: [SkippedRow] = []
}

/// Converts a CSV of padded NUMIDENT fields to the fixed-width text the app reads.
///
/// Each row's fields, joined with nothing between them, are one record, so the only checks needed are
/// the field count and the rebuilt width. Rows that fail are skipped and listed. Bytes are copied
/// unchanged. An existing target is never overwritten: output goes to `<target>.partial` and is renamed
/// only once complete.
public enum CSVConverter {
    static let chunkSize = 1 << 20
    static let maxRowBytes = 1 << 17

    /// `source` is a path, or `-` for standard input. Blocking.
    public static func convert(source: String, target: String, kind: DatasetKind) throws -> CSVConvertResult {
        guard !FileManager.default.fileExists(atPath: target) else { throw CSVConvertError.targetExists(target) }
        let input = source == "-" ? STDIN_FILENO : open(source, O_RDONLY)
        guard input >= 0 else { throw CSVConvertError.open(source, errno) }
        defer { if source != "-" { close(input) } }

        let partial = target + ".partial"
        unlink(partial) // A leftover from an interrupted run.
        guard let output = fopen(partial, "wb") else { throw CSVConvertError.open(partial, errno) }
        var outputOpen = true
        defer {
            if outputOpen { fclose(output) }
            unlink(partial)
        }

        let terminator: [UInt8] = kind.usesCRLF ? [13, 10] : [10]
        var result = CSVConvertResult()
        var reader = RowReader()
        var headerFields: Int?

        func handle(_ line: [UInt8], _ fields: Int, _ row: Int) throws {
            guard let expected = headerFields else {
                guard String(decoding: line, as: UTF8.self).uppercased().contains("SSN") else {
                    throw CSVConvertError.badHeader("the first row has no SSN column")
                }
                headerFields = fields
                return
            }
            guard fields == expected, line.count == kind.lineLength else {
                result.skipped.append(.init(row: row, fields: fields, characters: line.count))
                return
            }
            if line[12..<21].allSatisfy({ $0 == 90 }) { result.masked += 1 }
            guard fwrite(line, 1, line.count, output) == line.count,
                  fwrite(terminator, 1, terminator.count, output) == terminator.count else {
                throw CSVConvertError.write(partial, errno)
            }
            result.written += 1
        }

        var chunk = [UInt8](repeating: 0, count: chunkSize)
        while true {
            let n = read(input, &chunk, chunkSize)
            if n < 0 {
                if errno == EINTR { continue }
                throw CSVConvertError.read(source, errno)
            }
            if n == 0 { break }
            try reader.feed(chunk[0..<n], onRow: handle)
        }
        try reader.finish(onRow: handle)

        guard headerFields != nil else { throw CSVConvertError.badHeader("the file is empty") }
        guard result.written > 0 else { throw CSVConvertError.noRecords }
        guard fflush(output) == 0, fsync(fileno(output)) == 0 else { throw CSVConvertError.write(partial, errno) }
        fclose(output)
        outputOpen = false

        var st = stat()
        guard stat(partial, &st) == 0 else { throw CSVConvertError.read(partial, errno) }
        let expected = Int64(result.written) * Int64(kind.recordSize)
        guard Int64(st.st_size) == expected else {
            throw CSVConvertError.sizeMismatch(expected: expected, actual: Int64(st.st_size))
        }
        // Checked again because a long conversion leaves time for the target to appear.
        guard !FileManager.default.fileExists(atPath: target) else { throw CSVConvertError.targetExists(target) }
        guard rename(partial, target) == 0 else { throw CSVConvertError.write(target, errno) }
        return result
    }

    /// A byte-level CSV parser that keeps each row's fields joined. Blank lines are ignored.
    struct RowReader {
        private enum State { case fieldStart, unquoted, quoted, quoteInQuoted }
        private var state = State.fieldStart
        private var line: [UInt8] = []
        private var fields = 0
        private var row = 0
        private var lastWasCR = false

        mutating func feed(_ bytes: ArraySlice<UInt8>, onRow: ([UInt8], Int, Int) throws -> Void) throws {
            for c in bytes {
                let afterCR = lastWasCR
                lastWasCR = false
                switch state {
                case .quoted:
                    if c == 34 { state = .quoteInQuoted } else { line.append(c) }
                    if line.count > CSVConverter.maxRowBytes { throw CSVConvertError.rowTooLong(row: row + 1) }
                    continue
                case .quoteInQuoted:
                    if c == 34 {
                        line.append(c)
                        state = .quoted
                        continue
                    }
                    state = .unquoted
                case .fieldStart:
                    if c == 34 {
                        state = .quoted
                        continue
                    }
                case .unquoted:
                    break
                }
                switch c {
                case 44:
                    fields += 1
                    state = .fieldStart
                case 10, 13:
                    lastWasCR = c == 13
                    if c == 10 && afterCR { continue }
                    try endRow(onRow)
                default:
                    state = .unquoted
                    line.append(c)
                    if line.count > CSVConverter.maxRowBytes { throw CSVConvertError.rowTooLong(row: row + 1) }
                }
            }
        }

        mutating func finish(onRow: ([UInt8], Int, Int) throws -> Void) throws {
            if state == .quoted { throw CSVConvertError.rowTooLong(row: row + 1) }
            try endRow(onRow)
        }

        private mutating func endRow(_ onRow: ([UInt8], Int, Int) throws -> Void) throws {
            defer {
                line.removeAll(keepingCapacity: true)
                fields = 0
                state = .fieldStart
            }
            if line.isEmpty && fields == 0 && state == .fieldStart { return }
            row += 1
            try onRow(line, fields + 1, row)
        }
    }
}
