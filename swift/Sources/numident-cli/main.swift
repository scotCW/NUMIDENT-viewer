import Foundation
import NumidentCore

// Command-line front end to NumidentCore: health report, search, SSN lookup, benchmark.

func usage() -> Never {
    FileHandle.standardError.write("""
    usage:
      numident-cli health <data-dir>
      numident-cli ssn <data-dir> <SSN> [--sets NUMSS5,NUMCLM,NUMDEATH]
      numident-cli search <data-dir> [--last X] [--first X] [--middle X] [--mode exact|prefix|soundex]
                   [--other-names] [--dob-from Y] [--dob-to Y] [--death-from Y] [--death-to Y]
                   [--city X] [--state XX] [--father-first X] [--father-last X]
                   [--mother-first X] [--mother-last X] [--sex male|female|unknown]
                   [--sets ...] [--concurrency N] [--limit N] [--quiet]
      numident-cli bench <data-dir> [--sets ...] [--concurrency N]

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

var query = SearchQuery()
var sets = Set(DatasetKind.allCases)
var options = SearchOptions()
var quiet = false
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
            err("searching \(p.filesTotal) files, \(mb(p.totalBytes)) (\(p.mode == .ssnLookup ? "SSN lookup" : "full scan"), concurrency \(options.concurrency))")
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
            for o in s.outcomes where !o.method.isEmpty && s.mode == .ssnLookup {
                err("  \(o.file.name): \(o.method)")
            }
            for (k, why) in s.skipped { err("  skipped \(k.rawValue): \(why)") }
        }
    }
    sem.signal()
}
sem.wait()
