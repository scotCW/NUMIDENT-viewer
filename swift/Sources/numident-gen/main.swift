import Foundation
import NumidentCore

// Generates fake NUMIDENT-format data for testing and benchmarking.
//
//   numident-gen <out-dir> [--persons N | --target-gb G] [--seed S]
//                [--missing NUMCLM:2-11] [--truncate NUMDEATH:3] [--fixture]

func usage() -> Never {
    FileHandle.standardError.write("""
    usage: numident-gen <out-dir> [--persons N | --target-gb G] [--seed S]
                        [--missing SET:A-B[,C]] [--truncate SET:N[,M]] [--fixture]
      --fixture   5,000 persons, NUMCLM 02–11 missing, NUMDEATH03 truncated

    """.data(using: .utf8)!)
    exit(2)
}

/// `usage()` typed as any value, for use after `??`.
func bad<T>() -> T { usage() }

func parseNumbers(_ s: String) -> Set<Int> {
    var out = Set<Int>()
    for part in s.split(separator: ",") {
        let ab = part.split(separator: "-").compactMap { Int($0) }
        if ab.count == 2 { out.formUnion(ab[0]...ab[1]) } else if ab.count == 1 { out.insert(ab[0]) }
    }
    return out
}

func parseSetSpec(_ s: String) -> (DatasetKind, Set<Int>)? {
    let p = s.split(separator: ":", maxSplits: 1).map(String.init)
    guard p.count == 2, let k = DatasetKind(rawValue: p[0].uppercased()) else { return nil }
    return (k, parseNumbers(p[1]))
}

var args = Array(CommandLine.arguments.dropFirst())
guard let out = args.first, !out.hasPrefix("-") else { usage() }
args.removeFirst()
var config = SyntheticDataset.Config()
while !args.isEmpty {
    let a = args.removeFirst()
    func value() -> String { args.isEmpty ? bad() : args.removeFirst() }
    switch a {
    case "--persons": config.persons = Int(value()) ?? bad()
    // ~1,000 bytes of records per person on average.
    case "--target-gb": config.persons = Int((Double(value()) ?? bad()) * 1_000_000_000 / 1_000)
    case "--seed": config.seed = UInt64(value()) ?? bad()
    case "--missing": if let (k, n) = parseSetSpec(value()) { config.missing[k, default: []].formUnion(n) } else { usage() }
    case "--truncate": if let (k, n) = parseSetSpec(value()) { config.truncate[k, default: []].formUnion(n) } else { usage() }
    case "--fixture": config = .fixture()
    default: usage()
    }
}

let t0 = Date()
do {
    let stats = try SyntheticDataset.generate(at: out, config: config)
    let secs = Date().timeIntervalSince(t0)
    print(String(format: "wrote %.1f MB in %.1fs to %@", Double(stats.bytes) / 1e6, secs, out))
    for k in DatasetKind.allCases { print("  \(k.rawValue): \(stats.lines[k] ?? 0) records") }
    if let s = stats.sampleSSNs.dropFirst(stats.sampleSSNs.count / 2).first { print("  sample SSN: \(s)") }
} catch {
    FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
    exit(1)
}
