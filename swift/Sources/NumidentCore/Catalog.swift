import Foundation

public enum FileProblem: Sendable, Hashable, CustomStringConvertible {
    case empty
    case unreadable(String)
    /// The last line is not newline-terminated: likely an interrupted copy.
    case truncated
    /// Much smaller than the other files in the same set.
    case small(percentOfMedian: Int)
    case badFormat(String)
    /// File size is not a whole number of records: something was cut off or appended.
    case partialRecord(recordSize: Int, extraBytes: Int64)

    public var description: String {
        switch self {
        case .empty: return "empty file"
        case .unreadable(let e): return "unreadable (\(e))"
        case .truncated: return "last line incomplete (truncated copy?)"
        case .small(let p): return "only \(p)% of the typical file size"
        case .badFormat(let e): return "unexpected format (\(e))"
        case .partialRecord(let r, let x): return "size is not a whole number of \(r)-byte records (\(x) extra bytes)"
        }
    }

    /// Problems that make the file impossible to search at all.
    public var isFatal: Bool {
        switch self {
        case .empty, .unreadable: return true
        default: return false
        }
    }
}

public struct CatalogFile: Sendable, Hashable, Identifiable {
    public let kind: DatasetKind
    public let number: Int
    public let path: String
    public let size: Int64
    public var problems: [FileProblem]

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
    public var isUsable: Bool { !problems.contains(where: \.isFatal) }
    public var isSuspect: Bool { !problems.isEmpty }

    public init(kind: DatasetKind, number: Int, path: String, size: Int64, problems: [FileProblem] = []) {
        self.kind = kind
        self.number = number
        self.path = path
        self.size = size
        self.problems = problems
    }
}

public struct SetHealth: Sendable, Identifiable {
    public let kind: DatasetKind
    public let folder: String?
    public let files: [CatalogFile]
    public let missingNumbers: [Int]
    public let extraFiles: [String]

    public var id: DatasetKind { kind }
    public var expectedCount: Int { DatasetKind.expectedFileNumbers.count }
    public var presentCount: Int { files.count }
    public var usableFiles: [CatalogFile] { files.filter(\.isUsable) }
    public var suspectFiles: [CatalogFile] { files.filter(\.isSuspect) }
    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
    public var isComplete: Bool { missingNumbers.isEmpty && suspectFiles.isEmpty }
    public var isAvailable: Bool { !usableFiles.isEmpty }

    /// Approximate bytes missing, estimated from the median present file.
    public var estimatedMissingBytes: Int64 {
        let sizes = files.map(\.size).sorted()
        guard !sizes.isEmpty else { return 0 }
        return sizes[sizes.count / 2] * Int64(missingNumbers.count)
    }

    /// e.g. "NUMCLM: 10 of 20 files present (missing 02–11)"
    public var summary: String {
        if folder == nil { return "\(kind.rawValue): folder not found" }
        var s = "\(kind.rawValue): \(presentCount) of \(expectedCount) files present"
        if !missingNumbers.isEmpty { s += " (missing \(formatRanges(missingNumbers)))" }
        let suspects = suspectFiles
        if !suspects.isEmpty {
            s += "; \(suspects.count) suspect: " + suspects.map { "\($0.name) – \($0.problems.map(\.description).joined(separator: ", "))" }
                .joined(separator: "; ")
        }
        return s
    }
}

public struct DatasetHealth: Sendable {
    public let root: String
    public let rootExists: Bool
    /// Set when the root lives on a /Volumes/<name> that is not mounted.
    public let unmountedVolume: String?
    public let sets: [SetHealth]
    public let scannedAt: Date

    public var isComplete: Bool { rootExists && sets.allSatisfy(\.isComplete) }
    public func set(_ k: DatasetKind) -> SetHealth? { sets.first { $0.kind == k } }
    public var allFiles: [CatalogFile] { sets.flatMap(\.files) }
    public var totalBytes: Int64 { sets.reduce(0) { $0 + $1.totalBytes } }

    public var headline: String {
        if !rootExists {
            if let v = unmountedVolume { return "Data folder not found — volume “\(v)” is not mounted (\(root))" }
            return "Data folder not found: \(root)"
        }
        if isComplete { return "All \(allFiles.count) files present" }
        return "Incomplete dataset — searches will not cover everything"
    }

    public var problemLines: [String] {
        guard rootExists else { return [headline] }
        return sets.filter { !$0.isComplete }.map(\.summary)
    }
}

/// Renders [2,3,4,5,9] as "02–05, 09".
public func formatRanges(_ numbers: [Int]) -> String {
    let n = numbers.sorted()
    var parts: [String] = []
    var i = 0
    while i < n.count {
        var j = i
        while j + 1 < n.count && n[j + 1] == n[j] + 1 { j += 1 }
        let a = String(format: "%02d", n[i]), b = String(format: "%02d", n[j])
        parts.append(i == j ? a : "\(a)–\(b)")
        i = j + 1
    }
    return parts.joined(separator: ", ")
}

public enum Catalog {
    /// Discovers and validates the dataset under `root`. Does blocking I/O; call off the main thread.
    public static func scan(root: String) -> DatasetHealth {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: root, isDirectory: &isDir) && isDir.boolValue
        var unmounted: String?
        if !exists {
            let comps = (root as NSString).pathComponents
            if comps.count >= 3, comps[1] == "Volumes", !fm.fileExists(atPath: "/Volumes/\(comps[2])") {
                unmounted = comps[2]
            }
            let sets = DatasetKind.allCases.map {
                SetHealth(kind: $0, folder: nil, files: [], missingNumbers: DatasetKind.expectedFileNumbers, extraFiles: [])
            }
            return DatasetHealth(root: root, rootExists: false, unmountedVolume: unmounted, sets: sets, scannedAt: Date())
        }

        let topEntries = (try? fm.contentsOfDirectory(atPath: root)) ?? []
        var sets: [SetHealth] = []
        for kind in DatasetKind.allCases {
            // Prefer <root>/<SET>/, any case; fall back to files directly in root.
            let folderName = topEntries.first { $0.caseInsensitiveCompare(kind.rawValue) == .orderedSame }
            let folder = folderName.map { (root as NSString).appendingPathComponent($0) }
            let dir = folder ?? root
            let entries = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
            var found: [Int: CatalogFile] = [:]
            var extras: [String] = []
            // Skip dotfiles, including macOS AppleDouble "._*" files and .DS_Store on exFAT volumes.
            for name in entries.sorted() where !name.hasPrefix(".") {
                guard let n = fileNumber(name, kind: kind) else {
                    if folder != nil { extras.append(name) }
                    continue
                }
                let path = (dir as NSString).appendingPathComponent(name)
                guard found[n] == nil else { extras.append(name); continue }
                found[n] = inspect(path: path, kind: kind, number: n)
            }
            if folder == nil && found.isEmpty {
                sets.append(SetHealth(kind: kind, folder: nil, files: [], missingNumbers: DatasetKind.expectedFileNumbers,
                                      extraFiles: []))
                continue
            }
            var files = found.values.sorted { $0.number < $1.number }
            markSmall(&files)
            let missing = DatasetKind.expectedFileNumbers.filter { found[$0] == nil }
            sets.append(SetHealth(kind: kind, folder: dir, files: files, missingNumbers: missing, extraFiles: extras))
        }
        return DatasetHealth(root: root, rootExists: true, unmountedVolume: nil, sets: sets, scannedAt: Date())
    }

    /// Matches `<SET>NN_PU.txt`, case-insensitively.
    static func fileNumber(_ name: String, kind: DatasetKind) -> Int? {
        let u = name.uppercased()
        let prefix = kind.rawValue
        guard u.hasPrefix(prefix), u.hasSuffix("_PU.TXT") else { return nil }
        let mid = u.dropFirst(prefix.count).dropLast("_PU.TXT".count)
        guard mid.count == 2, let n = Int(mid), DatasetKind.expectedFileNumbers.contains(n) else { return nil }
        return n
    }

    static func inspect(path: String, kind: DatasetKind, number: Int) -> CatalogFile {
        var problems: [FileProblem] = []
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let fd = open(path, O_RDONLY)
        if fd < 0 {
            problems.append(.unreadable(String(cString: strerror(errno))))
            return CatalogFile(kind: kind, number: number, path: path, size: size, problems: problems)
        }
        defer { close(fd) }
        if size == 0 {
            problems.append(.empty)
            return CatalogFile(kind: kind, number: number, path: path, size: size, problems: problems)
        }
        // Last byte must be a newline.
        var last: UInt8 = 0
        if pread(fd, &last, 1, off_t(size - 1)) != 1 {
            problems.append(.unreadable(String(cString: strerror(errno))))
        } else if last != 10 {
            problems.append(.truncated)
        }
        let extra = size % Int64(kind.recordSize)
        if extra != 0 { problems.append(.partialRecord(recordSize: kind.recordSize, extraBytes: extra)) }
        // First line: SSN in columns 13–21 and a plausible length.
        var head = [UInt8](repeating: 0, count: 4096)
        let n = head.withUnsafeMutableBytes { pread(fd, $0.baseAddress, 4096, 0) }
        if n < 0 {
            problems.append(.unreadable(String(cString: strerror(errno))))
        } else if n > 0 {
            let slice = head[0..<n]
            let end = slice.firstIndex(of: 10) ?? n
            var lineEnd = end
            if lineEnd > 0 && head[lineEnd - 1] == 13 { lineEnd -= 1 }
            let ssn = head.count >= 21 ? head[12..<21] : []
            if end == n && n == 4096 {
                problems.append(.badFormat("no line break in first 4 KB"))
            } else if lineEnd != kind.lineLength {
                problems.append(.badFormat("first line is \(lineEnd) characters, expected \(kind.lineLength)"))
            } else if !ssn.allSatisfy({ ($0 >= 48 && $0 <= 57) || $0 == 90 }) {
                problems.append(.badFormat("columns 13–21 are not an SSN"))
            }
        }
        return CatalogFile(kind: kind, number: number, path: path, size: size, problems: problems)
    }

    /// Flags files under 50% of the median size of their set (needs 3+ files).
    static func markSmall(_ files: inout [CatalogFile]) {
        let sizes = files.filter { $0.size > 0 }.map(\.size).sorted()
        guard sizes.count >= 3 else { return }
        let median = sizes[sizes.count / 2]
        guard median > 0 else { return }
        for i in files.indices where files[i].size > 0 && files[i].size * 2 < median {
            files[i].problems.append(.small(percentOfMedian: Int(files[i].size * 100 / median)))
        }
    }
}
