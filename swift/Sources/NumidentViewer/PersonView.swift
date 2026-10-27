import NumidentCore
import SwiftUI

struct PersonView: View {
    @EnvironmentObject var model: AppModel
    let ssn: String

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("SSN \(ssn)").font(.title2.monospaced())
                if let p = model.person, let name = p.names.first?.value {
                    Text(name).font(.title2)
                }
                Spacer()
                Button("Close") { model.closePerson() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            if model.personLoading {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Looking up \(ssn) in \(model.selectedFiles.count) files…")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let p = model.person {
                PersonDetail(person: p)
            }
        }
        .frame(minWidth: 900, idealWidth: 1000, minHeight: 650, idealHeight: 760)
    }
}

struct PersonDetail: View {
    let person: PersonSummary
    @State private var expanded: Set<String> = []

    private func expandedBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { expanded.contains(id) || DebugHooks.env["NUMIDENT_EXPAND"] != nil },
                set: { if $0 { expanded.insert(id) } else { expanded.remove(id) } })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !person.coverageNotes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(person.coverageNotes, id: \.self) { n in
                            Label(n, systemImage: "exclamationmark.triangle").foregroundColor(.orange)
                        }
                    }
                    .font(.callout)
                }
                if person.records.isEmpty {
                    Text("No records found for this SSN in the searched files.").foregroundColor(.secondary)
                }
                if !person.conflicts.isEmpty {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(person.conflicts, id: \.self) { c in
                                Label(c, systemImage: "arrow.triangle.branch").foregroundColor(.red)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Text("Conflicts between records").bold()
                    }
                }
                Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 8) {
                    FactRow(label: "Names", values: person.names)
                    FactRow(label: "Born", values: person.birthDates, conflict: person.birthDates.count > 1)
                    FactRow(label: "Sex", values: person.sexes, conflict: person.sexes.count > 1)
                    FactRow(label: "Birthplace", values: person.birthplaces, conflict: person.birthplaces.count > 1)
                    FactRow(label: "Father", values: person.fathers, conflict: person.fathers.count > 1)
                    FactRow(label: "Mother", values: person.mothers, conflict: person.mothers.count > 1)
                    FactRow(label: "Died", values: person.deathDates, conflict: person.deathDates.count > 1)
                }
                GroupBox("Timeline") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(person.timeline) { e in
                            HStack(alignment: .firstTextBaseline) {
                                Text(e.date.description.isEmpty ? "unknown" : e.date.description)
                                    .font(.body.monospaced()).frame(width: 100, alignment: .leading)
                                Text(e.kind.shortTitle).foregroundColor(color(e.kind)).frame(width: 50, alignment: .leading)
                                Text(e.title).bold()
                                Text(e.detail).foregroundColor(.secondary)
                                Spacer()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Records (\(person.records.count))") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(person.records) { r in
                            DisclosureGroup(isExpanded: expandedBinding(r.id)) {
                                RecordDetail(record: r)
                            } label: {
                                HStack {
                                    Text(r.kind.rawValue).font(.body.monospaced()).foregroundColor(color(r.kind))
                                    Text(PersonSummary.label(r))
                                    Text(r.fullName).foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(14)
        }
    }

    private func color(_ k: DatasetKind) -> Color {
        switch k {
        case .ss5: return .blue
        case .claim: return .purple
        case .death: return .brown
        }
    }
}

struct FactRow: View {
    let label: String
    let values: [SourcedValue]
    var conflict = false

    var body: some View {
        GridRow {
            Text(label).bold().frame(width: 90, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                if values.isEmpty { Text("—").foregroundColor(.secondary) }
                ForEach(values) { v in
                    HStack(alignment: .firstTextBaseline) {
                        Text(v.value)
                            .foregroundColor(conflict ? .red : .primary)
                            .textSelection(.enabled)
                        Text(v.sources.joined(separator: "; ")).font(.caption).foregroundColor(.secondary)
                    }
                }
            }
        }
    }
}

/// Every field of one record plus the raw line with alternating field highlights.
struct RecordDetail: View {
    let record: NumidentRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(record.fileName) · byte offset \(record.offset)").font(.caption).foregroundColor(.secondary)
            RawLineView(record: record)
            let fields = Layouts.fields(for: record.kind).filter { !record.value($0).isEmpty }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                ForEach(fields) { f in
                    GridRow {
                        Text("\(f.start)–\(f.end)").font(.caption.monospaced()).foregroundColor(.secondary)
                        Text(f.group).font(.caption).foregroundColor(.secondary)
                        Text(f.label)
                        Text(record.display(f)).font(.body.monospaced()).textSelection(.enabled)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct RawLineView: View {
    let record: NumidentRecord

    var body: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                Text(ruler).foregroundColor(.secondary)
                Text(highlighted).textSelection(.enabled)
            }
            .font(.system(size: 11, design: .monospaced))
            .padding(6)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .cornerRadius(4)
    }

    private var ruler: String {
        let n = max(record.bytes.count, 10)
        return String((1...n).map { i in
            i % 10 == 0 ? Character(String((i / 10) % 10)) : (i % 5 == 0 ? "+" : "·")
        })
    }

    /// Fields alternate between two tints so their boundaries are visible.
    private var highlighted: AttributedString {
        let text = record.rawLine
        var s = AttributedString(text)
        let fields = Layouts.fields(for: record.kind).sorted { $0.start < $1.start }
        let chars = Array(s.characters.indices)
        for (i, f) in fields.enumerated() {
            let lo = f.start - 1, hi = min(f.end, chars.count)
            guard lo < hi, hi <= chars.count else { continue }
            let range = chars[lo]..<(hi == chars.count ? s.endIndex : chars[hi])
            s[range].backgroundColor = i % 2 == 0 ? Color.accentColor.opacity(0.18) : Color.orange.opacity(0.18)
        }
        return s
    }
}
