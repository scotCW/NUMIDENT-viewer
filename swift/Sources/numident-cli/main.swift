import Foundation
import NumidentCore

// Command-line front end to NumidentCore: health report, search, SSN lookup, benchmark, last-name index.

func usage() -> Never {
    FileHandle.standardError.write("""
    usage:
      numident-cli health <data-dir>
      numident-cli ssn <data-dir> <SSN> [--sets NUMSS5,NUMCLM,NUMDEATH]
      numident-cli search <data-dir> [--last X] [--first X] [--middle X] [--mode exact|prefix|soundex]
                   [--other-names] [--dob-from Y] [--dob-to Y] [--death-from Y] [--death-to Y]
                   [--city X] [--state XX] [--father-first X] [--father-last X]
                   [--mother-first X] [--mother-last X] [--sex male|female|unknown]
                   [--sets ...] [--concurrency N] [--limit N] [--quiet] [--no-index]
      numident-cli bench <data-dir> [--sets ...] [--concurrency N]
      numident-cli index <data-dir>        build (or rebuild) <data-dir>/LASTNAME-INDEX
      numident-cli index-info <data-dir>   show what the last-name index covers
      numident-cli convert <csv|-> <out.txt> --set NUMSS5|NUMCLM|NUMDEATH [--report FILE]
                   rebuild a fixed-width file from a CSV; never overwrites <out.txt>

    """.data(using: .utf8)!)
    exit(2)
}

/// `usage()` typed as any value, for use after `??`.
func bad<T>() -> T { usage() }

func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

func mb(_ b: Int64) -> String { String(format: "%.1f MB", Double(b) / 1e6) }

var args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else { usage() }
let command = args.removeFirst()
let root = args.removeFirst()

if command == "convert" {
    guard !args.isEmpty else { usage() }
    let target = args.removeFirst()
    var kind: DatasetKind?
    var reportPath: String?
    while !args.isEmpty {
        let a = args.removeFirst()
        func v() -> String { args.isEmpty ? bad() : args.removeFirst() }
        switch a {
        case "--set": kind = DatasetKind(rawValue: v().uppercased()) ?? bad()
        case "--report": reportPath = v()
        default: usage()
        }
    }
    guard let kind else { usage() }
    do {
        let r = try CSVConverter.convert(source: root, target: target, kind: kind)
        let name = (target as NSString).lastPathComponent
        var report = "\(name): \(r.written) records written (\(r.masked) masked), \(r.skipped.count) malformed rows skipped\n"
        for s in r.skipped { report += "  row \(s.row): \(s.fields) fields, \(s.characters) characters\n" }
        print(report, terminator: "")
        if let reportPath {
            let existing = FileManager.default.contents(atPath: reportPath) ?? Data()
            try (existing + Data(report.utf8)).write(to: URL(fileURLWithPath: reportPath), options: .atomic)
        }
        exit(0)
    } catch {
        err("convert failed: \(error)")
        exit(1)
    }
}

var query = SearchQuery()
var sets = Set(DatasetKind.allCases)
var options = SearchOptions()
var quiet = false
var useIndex = true
if command == "ssn" {
    guard !args.isEmpty else { usage() }
    query.ssn = args.removeFirst()
}
while !args.isEmpty {
    let a = args.removeFirst()
    func v() -> String { args.isEmpty ? bad() : args.removeFirst() }
    switch a {
    case "--last": query.lastName = v()
    case "--first": query.firstName = v()
    case "--middle": query.middleName = v()
    case "--mode": query.nameMatch = NameMatch(rawValue: v()) ?? bad()
    case "--other-names": query.includeOtherNames = true
    case "--dob-from": query.dobYearFrom = Int(v())
    case "--dob-to": query.dobYearTo = Int(v())
    case "--death-from": query.deathYearFrom = Int(v())
    case "--death-to": query.deathYearTo = Int(v())
    case "--city": query.pobCity = v()
    case "--state": query.pobState = v()
    case "--father-first": query.fatherFirst = v()
    case "--father-last": query.fatherLast = v()
    case "--mother-first": query.motherFirst = v()
    case "--mother-last": query.motherLast = v()
    case "--sex": query.sex = SexFilter(rawValue: v()) ?? bad()
    case "--sets": sets = Set(v().split(separator: ",").compactMap { DatasetKind(rawValue: $0.uppercased()) })
    case "--concurrency": options.concurrency = Int(v()) ?? 2
    case "--limit": options.resultCap = Int(v()) ?? 10_000
    case "--quiet": quiet = true
    case "--no-index": useIndex = false
    default: usage()
    }
}

let health = Catalog.scan(root: root)

if command == "health" {
    print(health.headline)
    for s in health.sets {
        print("  \(s.summary)  [\(mb(s.totalBytes))]")
        for f in s.files where f.isSuspect {
            print("    ! \(f.name): " + f.problems.map(\.description).joined(separator: ", "))
        }
        if !s.extraFiles.isEmpty { print("    ignored: " + s.extraFiles.joined(separator: ", ")) }
    }
    exit(health.rootExists ? 0 : 1)
}

let files = health.allFiles.filter { sets.contains($0.kind) && $0.isUsable }

if command == "index-info" {
    guard let index = LastNameIndex.open(root: root) else { print("no last-name index in \(root)"); exit(1) }
    let m = index.manifest
    let covered = files.filter { index.fileNumber(for: $0) != nil }
    print("built \(m.built), \(m.surnames) surnames, \(m.postings) entries, \(m.recordsIndexed) records")
    print("covers \(covered.count) of \(files.count) usable files")
    for f in files where index.fileNumber(for: f) == nil { print("  not covered: \(f.name)") }
    exit(0)
}

if command == "index" {
    let all = health.allFiles.filter(\.isUsable)
    err("building last-name index over \(all.count) files, \(mb(all.reduce(0) { $0 + $1.size }))")
    var lastPrint = Date.distantPast
    let start = Date()
    do {
        let m = try LastNameIndexBuilder.build(root: root, files: all, cancel: CancelToken()) { p in
            guard Date().timeIntervalSince(lastPrint) >= 2 else { return }
            lastPrint = Date()
            let eta = p.etaSeconds.map { String(format: " ETA %.0fs", $0) } ?? ""
            err(String(format: "  %5.1f%%  %@ / %@%@  [%@]", p.fraction * 100, mb(p.bytesDone), mb(p.bytesTotal), eta,
                       p.currentFile))
        }
        let dir = (root as NSString).appendingPathComponent(LastNameIndex.folderName)
        let size = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).reduce(Int64(0)) { sum, name in
            let a = try? FileManager.default.attributesOfItem(atPath: (dir as NSString).appendingPathComponent(name))
            return sum + ((a?[.size] as? Int64) ?? 0)
        }
        print(String(format: "built in %.0fs: %d surnames, %lld entries, %lld records, %@ on disk",
                     Date().timeIntervalSince(start), m.surnames, m.postings, m.recordsIndexed, mb(size)))
        exit(0)
    } catch {
        err("index build failed: \(error)")
        exit(1)
    }
}
if useIndex, let index = LastNameIndex.open(root: root) {
    options.lastNameIndex = index
}
if command == "bench" {
    // A last name no record has: forces a full scan of every byte with the real matcher.
    query = SearchQuery()
    query.lastName = "ZZZZNOSUCHNAME"
    quiet = true
} else if command != "search" && command != "ssn" {
    usage()
}
if let problem = query.validate() { err(problem); exit(2) }
for note in Coverage.notes(health: health, searched: files) { err("note: \(note)") }

let sem = DispatchSemaphore(value: 0)
Task {
    var lastPrint = Date.distantPast
    for await event in SearchEngine.search(query, files: files, options: options) {
        switch event {
        case .started(let p):
            let how = p.mode == .ssnLookup ? "SSN lookup" : p.mode == .indexLookup ? "last-name index" : "full scan"
            err("searching \(p.filesTotal) files, \(mb(p.totalBytes)) (\(how), concurrency \(options.concurrency))")
        case .progress(let p):
            if Date().timeIntervalSince(lastPrint) >= 1 {
                lastPrint = Date()
                let eta = p.etaSeconds.map { String(format: " ETA %.0fs", $0) } ?? ""
                err(String(format: "  %5.1f%%  %@ / %@  %.0f MB/s%@  matches %d  [%@]",
                           p.fraction * 100, mb(p.doneBytes), mb(p.totalBytes), p.bytesPerSecond / 1e6, eta,
                           p.matchCount, p.currentFiles.joined(separator: ", ")))
            }
        case .matches(let rs):
            if !quiet {
                for r in rs {
                    print("\(r.kind.rawValue)\t\(r.ssn)\t\(r.fullName)\tDOB \(r.dob)\t\(r.birthplace)\t\(r.eventDate)\t\(r.fileName)@\(r.offset)")
                }
            }
        case .fileFailed(let f, let m):
            err("  ! \(f): \(m)")
        case .finished(let s):
            err(String(format: "done: %d matches, %@ read in %.2fs = %.0f MB/s%@%@",
                       s.matchCount, mb(s.bytesRead), s.elapsed, s.bytesPerSecond / 1e6,
                       s.cancelled ? " (cancelled)" : "", s.hitCap ? " (result cap reached)" : ""))
            for o in s.outcomes where !o.method.isEmpty && (s.mode != .fullScan || o.method.hasPrefix("last-name")) {
                err("  \(o.file.name): \(o.method)")
            }
            for (k, why) in s.skipped { err("  skipped \(k.rawValue): \(why)") }
        }
    }
    sem.signal()
}
sem.wait()
