import Foundation

public enum CSVConvertError: Error, Sendable, CustomStringConvertible {
    case targetExists(String)
    case busy(String)
    case open(String, Int32)
    case read(String, Int32)
    case write(String, Int32)
    case badHeader(String)
    case rowTooLong(line: Int)
    case noRecords
    case sizeMismatch(expected: Int64, actual: Int64)

    public var description: String {
        switch self {
        case .targetExists(let p): return "\(p) already exists; it was not changed"
        case .busy(let p): return "another conversion is writing \(p)"
        case .open(let p, let e): return "can't open \(p): \(String(cString: strerror(e)))"
        case .read(let p, let e): return "can't read \(p): \(String(cString: strerror(e)))"
        case .write(let p, let e): return "can't write \(p): \(String(cString: strerror(e)))"
        case .badHeader(let why): return "not a NUMIDENT CSV: \(why)"
        case .rowTooLong(let line): return "the row at line \(line) is far too long, probably from an unmatched quote"
        case .noRecords: return "no row rebuilt to a whole record, so nothing was written; check the set"
        case .sizeMismatch(let e, let a): return "output is \(a) bytes, expected \(e); nothing was kept"
        }
    }
}

public struct CSVConvertResult: Sendable {
    public struct SkippedRow: Sendable, Equatable {
        /// 1-based line of the CSV on which the row starts.
        public let line: Int
        public let fields: Int
        public let characters: Int
    }
    public var written = 0
    /// Written records whose SSN is all `Z`.
    public var masked = 0
    /// The first skipped rows, up to `CSVConverter.maxListedSkips`.
    public var skipped: [SkippedRow] = []
    public var skippedCount = 0
}

/// Converts a CSV of padded NUMIDENT fields to the fixed-width text the app reads.
///
/// Each row's fields, joined with nothing between them, are one record, so the only checks needed are
/// the field count and the rebuilt width. Rows that fail are skipped and listed. Bytes are copied
/// unchanged. A first row that isn't itself a record is taken as the header. An existing target is
/// never overwritten: output goes to `<target>.partial` and is renamed only once complete.
public enum CSVConverter {
    static let chunkSize = 1 << 20
    static let maxRowBytes = 1 << 17
    static let maxListedSkips = 1000
    /// With no record written after this many rows, the set is wrong or the file isn't NUMIDENT data.
    static let giveUpAfter = 1000

    static func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    static func looksLikeRecord(_ line: [UInt8], _ kind: DatasetKind) -> Bool {
        line.count == kind.lineLength && line[12..<21].allSatisfy { ($0 >= 48 && $0 <= 57) || $0 == 90 }
    }

    /// `source` is a path, or `-` for standard input. Blocking.
    public static func convert(source: String, target: String, kind: DatasetKind) throws -> CSVConvertResult {
        guard !exists(target) else { throw CSVConvertError.targetExists(target) }
        let input = source == "-" ? STDIN_FILENO : open(source, O_RDONLY)
        guard input >= 0 else { throw CSVConvertError.open(source, errno) }
        defer { if source != "-" { close(input) } }

        let partial = target + ".partial"
        let fd = open(partial, O_WRONLY | O_CREAT, 0o644)
        guard fd >= 0 else { throw CSVConvertError.open(partial, errno) }
        // A lock rather than O_EXCL: a leftover from an interrupted run is reused, while a
        // conversion that is still running keeps its file.
        var mine = stat(), named = stat()
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 || errno != EWOULDBLOCK,
              fstat(fd, &mine) == 0, lstat(partial, &named) == 0, mine.st_ino == named.st_ino else {
            close(fd)
            throw CSVConvertError.busy(partial)
        }
        guard ftruncate(fd, 0) == 0, let output = fdopen(fd, "wb") else {
            let e = errno
            close(fd)
            unlink(partial)
            throw CSVConvertError.write(partial, e)
        }
        var renamed = false
        defer {
            fclose(output)
            if !renamed { unlink(partial) }
        }

        let terminator: [UInt8] = kind.usesCRLF ? [13, 10] : [10]
        var result = CSVConvertResult()
        var reader = RowReader()
        var headerFields: Int?

        func write(_ line: [UInt8]) throws {
            if line[12..<21].allSatisfy({ $0 == 90 }) { result.masked += 1 }
            guard fwrite(line, 1, line.count, output) == line.count,
                  fwrite(terminator, 1, terminator.count, output) == terminator.count else {
                throw CSVConvertError.write(partial, errno)
            }
            result.written += 1
        }

        func handle(_ line: [UInt8], _ fields: Int, _ lineNumber: Int) throws {
            guard let expected = headerFields else {
                headerFields = fields
                // A file with no header row starts with a record.
                if looksLikeRecord(line, kind) { return try write(line) }
                guard String(decoding: line, as: UTF8.self).uppercased().contains("SSN") else {
                    throw CSVConvertError.badHeader("the first row is neither a record nor a header with an SSN column")
                }
                return
            }
            guard fields == expected, line.count == kind.lineLength else {
                result.skippedCount += 1
                if result.skipped.count < maxListedSkips {
                    result.skipped.append(.init(line: lineNumber, fields: fields, characters: line.count))
                }
                if result.written == 0 && result.skippedCount >= giveUpAfter { throw CSVConvertError.noRecords }
                return
            }
            try write(line)
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

        var st = stat()
        guard fstat(fileno(output), &st) == 0 else { throw CSVConvertError.read(partial, errno) }
        let expected = Int64(result.written) * Int64(kind.recordSize)
        guard Int64(st.st_size) == expected else {
            throw CSVConvertError.sizeMismatch(expected: expected, actual: Int64(st.st_size))
        }
        if renamex_np(partial, target, UInt32(RENAME_EXCL)) != 0 {
            let e = errno
            if e == EEXIST { throw CSVConvertError.targetExists(target) }
            guard e == ENOTSUP || e == EINVAL else { throw CSVConvertError.write(target, e) }
            // The volume (exFAT, for one) can't rename exclusively, so check and then rename.
            guard !exists(target) else { throw CSVConvertError.targetExists(target) }
            guard rename(partial, target) == 0 else { throw CSVConvertError.write(target, errno) }
        }
        renamed = true
        return result
    }

    /// A byte-level CSV parser that keeps each row's fields joined and reports the line each row starts
    /// on. Blank lines are ignored.
    struct RowReader {
        private enum State { case fieldStart, unquoted, quoted, quoteInQuoted }
        private var state = State.fieldStart
        private var line: [UInt8] = []
        private var fields = 0
        private var lineNumber = 1
        private var rowStart = 1
        private var lastWasCR = false

        mutating func feed(_ bytes: ArraySlice<UInt8>, onRow: ([UInt8], Int, Int) throws -> Void) throws {
            for c in bytes {
                let afterCR = lastWasCR
                lastWasCR = c == 13
                if c == 13 || (c == 10 && !afterCR) { lineNumber += 1 }
                switch state {
                case .quoted:
                    if c == 34 { state = .quoteInQuoted } else { line.append(c) }
                    if line.count > CSVConverter.maxRowBytes { throw CSVConvertError.rowTooLong(line: rowStart) }
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
                    if c == 10 && afterCR {
                        rowStart = lineNumber
                        continue
                    }
                    try endRow(onRow)
                default:
                    state = .unquoted
                    line.append(c)
                    if line.count > CSVConverter.maxRowBytes { throw CSVConvertError.rowTooLong(line: rowStart) }
                }
            }
        }

        mutating func finish(onRow: ([UInt8], Int, Int) throws -> Void) throws {
            if state == .quoted { throw CSVConvertError.rowTooLong(line: rowStart) }
            try endRow(onRow)
        }

        private mutating func endRow(_ onRow: ([UInt8], Int, Int) throws -> Void) throws {
            defer {
                line.removeAll(keepingCapacity: true)
                fields = 0
                state = .fieldStart
                rowStart = lineNumber
            }
            if line.isEmpty && fields == 0 && state == .fieldStart { return }
            try onRow(line, fields + 1, rowStart)
        }
    }
}
