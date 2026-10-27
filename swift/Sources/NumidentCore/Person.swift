import Foundation

/// A value seen in one or more records, with where it came from.
public struct SourcedValue: Sendable, Identifiable, Hashable {
    public let value: String
    public var sources: [String]
    public var id: String { value }
}

public struct TimelineEvent: Sendable, Identifiable {
    public let date: PartialDate
    public let kind: DatasetKind
    public let title: String
    public let detail: String
    public let recordID: String
    public var id: String { "\(recordID)|\(title)|\(date.raw)" }
}

/// Everything known about one SSN, merged across SS-5, claim and death records.
public struct PersonSummary: Sendable {
    public let ssn: String
    public let records: [NumidentRecord]
    public let names: [SourcedValue]
    public let birthDates: [SourcedValue]
    public let sexes: [SourcedValue]
    public let birthplaces: [SourcedValue]
    public let fathers: [SourcedValue]
    public let mothers: [SourcedValue]
    public let deathDates: [SourcedValue]
    public let timeline: [TimelineEvent]
    public let conflicts: [String]
    public let coverageNotes: [String]

    public init(ssn: String, records: [NumidentRecord], coverageNotes: [String] = []) {
        self.ssn = ssn
        let recs = records.sorted { ($0.kind, $0.eventDate.sortKey) < ($1.kind, $1.eventDate.sortKey) }
        self.records = recs

        var names = Collector(), dobs = Collector(), sexes = Collector(), pobs = Collector()
        var fathers = Collector(), mothers = Collector(), dods = Collector()
        var dobDates: [PartialDate] = [], dodDates: [PartialDate] = []
        var timeline: [TimelineEvent] = []

        for r in recs {
            let src = Self.label(r)
            switch r.kind {
            case .ss5, .claim:
                names.add(r.fullName, src)
                if r.kind == .ss5 {
                    let other = [r.value("oFirst"), r.value("oMiddle"), r.value("oLast"), r.value("oSuffix")]
                        .filter { !$0.isEmpty }.joined(separator: " ")
                    names.add(other, src + " (other name)")
                    let sig = [r.value("sFirst"), r.value("sMiddle"), r.value("sLast"), r.value("sSuffix")]
                        .filter { !$0.isEmpty }.joined(separator: " ")
                    names.add(sig, src + " (signature)")
                }
                if !r.dob.isEmpty { dobs.add(r.dob.description, src); dobDates.append(r.dob) }
                if r.kind == .ss5 {
                    let prior = r.date("priorDob")
                    if !prior.isEmpty { dobs.add(prior.description, src + " (prior DOB)") }
                }
                sexes.add(r.sexCode == "0" ? "" : r.sex, src)
                pobs.add(r.birthplace, src)
                fathers.add(r.fatherName, src)
                mothers.add(r.motherName, src)
                if r.kind == .ss5 {
                    let entry = Codes.entry.describe(r.entryCode) ?? r.entryCode
                    let form = Codes.form.describe(r.value("form")).map { ", form: \($0)" } ?? ""
                    timeline.append(TimelineEvent(date: r.cycleDate, kind: .ss5, title: "SS-5 posted",
                                                  detail: "\(entry)\(form) — \(r.fullName)", recordID: r.id))
                } else {
                    let type = r.entryCode == "D" ? "Death claim" : (r.entryCode == "L" ? "Life claim" : "Claim")
                    let claimDate = r.date("claimDate")
                    timeline.append(TimelineEvent(date: claimDate.isEmpty ? r.cycleDate : claimDate, kind: .claim,
                                                  title: "\(type) filed",
                                                  detail: "\(r.fullName); office: \(r.value("doAddress"))", recordID: r.id))
                    let onset = r.date("onsetDate")
                    if !onset.isEmpty {
                        timeline.append(TimelineEvent(date: onset, kind: .claim, title: "Date of onset",
                                                      detail: type, recordID: r.id))
                    }
                    let dod = r.date("dodClaim")
                    if !dod.isEmpty {
                        dods.add(dod.description, src)
                        dodDates.append(dod)
                        timeline.append(TimelineEvent(date: dod, kind: .claim, title: "Death (from claim)",
                                                      detail: type, recordID: r.id))
                    }
                }
            case .death:
                for p in r.deathPostings {
                    let psrc = "\(src) posting \(p.number)"
                    names.add(p.name, psrc)
                    if !p.dob.isEmpty { dobs.add(p.dob.description, psrc); dobDates.append(p.dob) }
                    sexes.add(p.sex == "0" || p.sex.isEmpty ? "" : (Codes.sex.describe(p.sex) ?? p.sex), psrc)
                    if !p.dod.isEmpty {
                        dods.add(p.dod.description, psrc)
                        dodDates.append(p.dod)
                    }
                    var detail: [String] = []
                    if let s = Codes.sourceOfDeath.describe(p.source) { detail.append("source: \(s)") }
                    if let s = Codes.proofOfDeath.describe(p.proof) { detail.append("proof: \(s)") }
                    if !p.zipResidence.isEmpty { detail.append("ZIP \(p.zipResidence)") }
                    if !p.posted.isEmpty { detail.append("posted \(p.posted)") }
                    timeline.append(TimelineEvent(date: p.dod.isEmpty ? p.posted : p.dod, kind: .death,
                                                  title: "Death (posting \(p.number))",
                                                  detail: detail.joined(separator: "; "), recordID: r.id))
                }
            }
        }

        self.names = names.values
        self.birthDates = dobs.values
        self.sexes = sexes.values
        self.birthplaces = pobs.values
        self.fathers = fathers.values
        self.mothers = mothers.values
        self.deathDates = dods.values
        self.timeline = timeline.sorted { $0.date.sortKey < $1.date.sortKey }

        var conflicts: [String] = []
        if Self.hasIncompatible(dobDates) {
            conflicts.append("Records disagree on date of birth: " + dobs.values.map(\.value).joined(separator: " vs "))
        }
        if Self.hasIncompatible(dodDates) {
            conflicts.append("Records disagree on date of death: " + dods.values.map(\.value).joined(separator: " vs "))
        }
        if sexes.values.count > 1 {
            conflicts.append("Records disagree on sex: " + sexes.values.map(\.value).joined(separator: " vs "))
        }
        if pobs.values.count > 1 {
            conflicts.append("Different birthplaces recorded: " + pobs.values.map(\.value).joined(separator: " vs "))
        }
        if fathers.values.count > 1 {
            conflicts.append("Different father's names: " + fathers.values.map(\.value).joined(separator: " vs "))
        }
        if mothers.values.count > 1 {
            conflicts.append("Different mother's names: " + mothers.values.map(\.value).joined(separator: " vs "))
        }
        self.conflicts = conflicts
        self.coverageNotes = coverageNotes
    }

    /// Field keys whose values differ between this record and others of the person (for highlighting).
    public static func label(_ r: NumidentRecord) -> String {
        let d = r.kind == .ss5 ? r.cycleDate : r.eventDate
        return "\(r.kind.shortTitle) \(d.isEmpty ? "" : d.description) [\(r.fileName)]"
            .replacingOccurrences(of: "  ", with: " ")
    }

    static func hasIncompatible(_ dates: [PartialDate]) -> Bool {
        for i in dates.indices {
            for j in dates.indices where j > i && !dates[i].isCompatible(with: dates[j]) { return true }
        }
        return false
    }

    struct Collector {
        private var order: [String] = []
        private var map: [String: [String]] = [:]
        mutating func add(_ v: String, _ src: String) {
            let k = v.trimmingCharacters(in: .whitespaces)
            guard !k.isEmpty else { return }
            if map[k] == nil { order.append(k) }
            map[k, default: []].append(src)
        }
        var values: [SourcedValue] { order.map { SourcedValue(value: $0, sources: map[$0] ?? []) } }
    }
}

public enum Coverage {
    /// Notes explaining what a search could not see: deselected sets, missing or failed files.
    public static func notes(health: DatasetHealth?, searched: [CatalogFile], failed: [String] = []) -> [String] {
        var notes: [String] = []
        let searchedPaths = Set(searched.map(\.path))
        for kind in DatasetKind.allCases {
            guard let set = health?.set(kind) else { continue }
            let inSet = searched.filter { $0.kind == kind }
            if inSet.isEmpty {
                if set.isAvailable {
                    notes.append("\(kind.rawValue) was not searched (deselected) — no \(kind.title.lowercased()) would be found.")
                } else {
                    notes.append("\(kind.rawValue) is not available — \(set.summary).")
                }
                continue
            }
            var gaps: [String] = []
            if !set.missingNumbers.isEmpty {
                gaps.append("\(set.missingNumbers.count) of 20 files missing (\(formatRanges(set.missingNumbers)))")
            }
            let excluded = set.files.filter { !searchedPaths.contains($0.path) }
            if !excluded.isEmpty {
                gaps.append("\(excluded.count) file(s) not searched: " + excluded.map(\.name).joined(separator: ", "))
            }
            let suspect = inSet.filter(\.isSuspect)
            if !suspect.isEmpty { gaps.append("suspect: " + suspect.map(\.name).joined(separator: ", ")) }
            if !gaps.isEmpty {
                notes.append("\(kind.rawValue): " + gaps.joined(separator: "; ")
                             + " — a missing \(kind.shortTitle.lowercased()) record is not conclusive.")
            }
        }
        if !failed.isEmpty { notes.append("Read errors in: " + failed.joined(separator: ", ")) }
        return notes
    }
}
