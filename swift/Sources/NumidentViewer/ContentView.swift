import NumidentCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HealthBanner()
            Divider()
            HSplitView {
                SidebarView()
                    .frame(minWidth: 300, idealWidth: 340, maxWidth: 460)
                ResultsPane()
                    .frame(minWidth: 520)
            }
        }
        .sheet(item: $model.personRequest) { req in
            PersonView(ssn: req.ssn)
                .environmentObject(model)
        }
    }
}

// MARK: - Dataset health banner

struct HealthBanner: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let h = model.health {
            if h.isComplete {
                HStack {
                    Image(systemName: "checkmark.circle").foregroundColor(.green)
                    Text("\(h.headline) — \(Format.bytes(h.totalBytes)) in \(h.root)")
                    Spacer()
                    rescanButton
                }
                .font(.callout)
                .padding(.horizontal, 12).padding(.vertical, 6)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(h.headline).font(.headline)
                            ForEach(h.problemLines.prefix(model.bannerExpanded ? 0 : 3), id: \.self) { line in
                                Text(line).font(.callout)
                            }
                        }
                        Spacer()
                        if h.rootExists {
                            Button(model.bannerExpanded ? "Hide details" : "Details") {
                                model.bannerExpanded.toggle()
                            }
                        }
                        rescanButton
                    }
                    if model.bannerExpanded && h.rootExists {
                        HealthTable(health: h)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.orange.opacity(0.15))
            }
        } else {
            HStack {
                ProgressView().controlSize(.small)
                Text("Checking data folder…")
                Spacer()
            }
            .padding(8)
        }
    }

    private var rescanButton: some View {
        Button {
            model.rescan()
        } label: {
            if model.isScanningCatalog { ProgressView().controlSize(.small) } else { Text("Rescan") }
        }
        .disabled(model.isScanningCatalog)
    }
}

struct HealthTable: View {
    let health: DatasetHealth

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            GridRow {
                Text("Set").bold()
                Text("Present").bold()
                Text("Missing").bold()
                Text("Size").bold()
                Text("Suspect files").bold()
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(health.sets) { s in
                GridRow {
                    Text(s.kind.rawValue).font(.body.monospaced())
                    Text("\(s.presentCount) / \(s.expectedCount)")
                    Text(s.missingNumbers.isEmpty ? "—" : formatRanges(s.missingNumbers)
                         + (s.estimatedMissingBytes > 0 ? " (~\(Format.bytes(s.estimatedMissingBytes)))" : ""))
                        .foregroundColor(s.missingNumbers.isEmpty ? .secondary : .red)
                    Text(Format.bytes(s.totalBytes))
                    Text(s.suspectFiles.isEmpty ? "—" : s.suspectFiles
                        .map { "\($0.name): \($0.problems.map(\.description).joined(separator: ", "))" }
                        .joined(separator: "\n"))
                        .foregroundColor(s.suspectFiles.isEmpty ? .secondary : .orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.callout)
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
        .cornerRadius(6)
    }
}

// MARK: - Sidebar: dataset selection + search form

struct SidebarView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    DatasetSelection()
                    IndexPanel()
                    SearchForm()
                }
                .padding(12)
                // Pin content to the pane width so wide controls never get clipped.
                .frame(width: geo.size.width)
            }
        }
    }
}

struct DatasetSelection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        GroupBox("Search these record sets") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(DatasetKind.allCases) { kind in
                    let set = model.health?.set(kind)
                    let usable = model.usableFiles(kind)
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle(isOn: model.setBinding(kind)) {
                            HStack {
                                Text("\(kind.rawValue)").font(.body.monospaced())
                                Text(kind.title).foregroundColor(.secondary)
                                Spacer()
                                Text("\(set?.presentCount ?? 0)/20").foregroundColor(
                                    (set?.missingNumbers.isEmpty ?? false) ? .secondary : .orange)
                            }
                        }
                        .disabled(usable.isEmpty)
                        .help(usable.isEmpty ? (set?.summary ?? "Not available") : kind.title)
                        if !usable.isEmpty {
                            DisclosureGroup("Files") {
                                FileList(kind: kind)
                            }
                            .font(.caption)
                            .padding(.leading, 18)
                        }
                    }
                }
                Divider()
                Text("\(model.selectedFiles.count) files selected · \(Format.bytes(model.selectedBytes))")
                    .font(.caption).foregroundColor(.secondary)
            }
            .padding(4)
        }
    }
}

/// The optional last-name index: built only when the user asks, used only while switched on.
struct IndexPanel: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmBuild = false

    var body: some View {
        GroupBox("Last-name index") {
            VStack(alignment: .leading, spacing: 6) {
                if let p = model.indexBuild {
                    ProgressView(value: p.fraction)
                    HStack {
                        Text(String(format: "%.0f%%", p.fraction * 100)).monospacedDigit()
                        if !p.currentFile.isEmpty { Text(p.currentFile).font(.caption.monospaced()) }
                        if let eta = p.etaSeconds { Text("· \(Format.duration(eta)) left") }
                        Spacer()
                        Button("Cancel") { model.cancelIndexBuild() }
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                } else if let idx = model.lastNameIndex {
                    Toggle("Use for last-name searches", isOn: Binding(
                        get: { model.useLastNameIndex }, set: { model.useLastNameIndex = $0 }))
                    let cov = model.indexCoverage
                    Text("Built \(idx.manifest.built.formatted(date: .abbreviated, time: .shortened)) · "
                        + "\(idx.surnameCount.formatted()) surnames · covers \(cov.covered) of \(cov.total) files")
                        .font(.caption).foregroundColor(.secondary)
                    if cov.covered < cov.total {
                        Label("\(cov.total - cov.covered) files were added or changed since; searches read them in full. "
                              + "Rebuild to include them.", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundColor(.orange)
                    }
                    Button("Rebuild index…") { confirmBuild = true }
                        .disabled(model.isSearching)
                } else {
                    Text("Not built. Last-name searches read every file.")
                        .font(.caption).foregroundColor(.secondary)
                    Button("Build index…") { confirmBuild = true }
                        .disabled(model.isSearching || !(model.health?.rootExists ?? false))
                }
                if let e = model.indexError {
                    Label(e, systemImage: "xmark.octagon").font(.caption).foregroundColor(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        .confirmationDialog("Build the last-name index?", isPresented: $confirmBuild) {
            Button(model.lastNameIndex == nil ? "Build" : "Rebuild") { model.buildIndex() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This reads every file once (about as long as one full search) and writes about 0.5 GB to "
                + "\(LastNameIndex.folderName) in the data folder. Searching is unavailable until it finishes. "
                + "Afterwards, searches with a last name read only matching records.")
        }
    }
}

struct FileList: View {
    @EnvironmentObject var model: AppModel
    let kind: DatasetKind

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Button("All") { model.setBinding(kind).wrappedValue = true }
                Button("None") { model.setBinding(kind).wrappedValue = false }
            }
            .buttonStyle(.link)
            ForEach(model.health?.set(kind)?.files ?? []) { f in
                Toggle(isOn: model.fileBinding(f)) {
                    HStack {
                        Text(f.name).font(.caption.monospaced())
                        Spacer()
                        Text(Format.bytes(f.size)).foregroundColor(.secondary)
                        if f.isSuspect {
                            Image(systemName: "exclamationmark.triangle").foregroundColor(.orange)
                                .help(f.problems.map(\.description).joined(separator: "\n"))
                        }
                    }
                }
                .disabled(!f.isUsable)
            }
            if let missing = model.health?.set(kind)?.missingNumbers, !missing.isEmpty {
                Text("Missing: \(formatRanges(missing))").foregroundColor(.red)
            }
        }
    }
}

struct SearchForm: View {
    @EnvironmentObject var model: AppModel

    private func row<V: View>(_ label: String, @ViewBuilder _ field: () -> V) -> some View {
        GridRow {
            Text(label).foregroundColor(.secondary).gridColumnAlignment(.trailing)
            field()
        }
    }

    private func header(_ title: String) -> some View {
        GridRow {
            Color.clear.frame(width: 1, height: 1)
            Text(title).font(.caption.bold()).foregroundColor(.secondary).padding(.top, 4)
        }
    }

    private func yearBinding(_ kp: WritableKeyPath<SearchQuery, Int?>) -> Binding<String> {
        Binding(
            get: { model.query[keyPath: kp].map(String.init) ?? "" },
            set: { model.query[keyPath: kp] = Int($0.filter(\.isNumber)) })
    }

    var body: some View {
        GroupBox("Search") {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                row("SSN") { TextField("", text: $model.query.ssn, prompt: Text("9 digits — instant lookup")) }
                header("Name")
                row("Last") { TextField("", text: $model.query.lastName) }
                row("First") { TextField("", text: $model.query.firstName) }
                row("Middle") { TextField("", text: $model.query.middleName) }
                row("Match") {
                    Picker("", selection: $model.query.nameMatch) {
                        ForEach(NameMatch.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                }
                row("") { Toggle("Other & signature names (SS-5)", isOn: $model.query.includeOtherNames) }
                header("Years")
                row("Born") {
                    HStack {
                        TextField("", text: yearBinding(\.dobYearFrom), prompt: Text("from"))
                        TextField("", text: yearBinding(\.dobYearTo), prompt: Text("to"))
                    }
                }
                row("Died") {
                    HStack {
                        TextField("", text: yearBinding(\.deathYearFrom), prompt: Text("from"))
                        TextField("", text: yearBinding(\.deathYearTo), prompt: Text("to"))
                    }
                }
                header("Birthplace")
                row("City") { TextField("", text: $model.query.pobCity, prompt: Text("starts with")) }
                row("State") { TextField("", text: $model.query.pobState, prompt: Text("2-letter code")) }
                header("Parents")
                row("Father") {
                    HStack {
                        TextField("", text: $model.query.fatherFirst, prompt: Text("first"))
                        TextField("", text: $model.query.fatherLast, prompt: Text("last"))
                    }
                }
                row("Mother") {
                    HStack {
                        TextField("", text: $model.query.motherFirst, prompt: Text("first"))
                        TextField("", text: $model.query.motherLast, prompt: Text("maiden"))
                    }
                }
                row("Sex") {
                    Picker("", selection: $model.query.sex) {
                        Text("Any").tag(SexFilter.any)
                        Text("Male").tag(SexFilter.male)
                        Text("Female").tag(SexFilter.female)
                        Text("Unknown").tag(SexFilter.unknown)
                    }
                    .labelsHidden()
                }
            }
            .textFieldStyle(.roundedBorder)
            .padding(4)
            .onSubmit { model.startSearch() }

            ForEach(model.query.skippedReasons.sorted(by: { $0.key < $1.key }), id: \.key) { k, why in
                Label("\(k.rawValue) skipped: \(why)", systemImage: "info.circle")
                    .font(.caption).foregroundColor(.secondary)
            }
            if let msg = model.validationMessage {
                Text(msg).foregroundColor(.red).font(.callout)
            }
            HStack {
                Button("Clear") { model.query = SearchQuery() }
                Spacer()
                if model.isSearching {
                    Button("Cancel", role: .cancel) { model.cancelSearch() }
                        .keyboardShortcut(.escape, modifiers: [])
                }
                Button("Search") { model.startSearch() }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isSearching)
            }
            .padding(.top, 6)
        }
    }
}

// MARK: - Results

struct ResultsPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if model.isSearching || model.summary != nil {
                ProgressPanel()
                Divider()
            }
            ResultsFilterBar()
            Divider()
            ResultsTable()
            Divider()
            HStack {
                if model.results.isEmpty {
                    Text(model.isSearching ? "Searching…" : (model.summary == nil ? "Enter a search on the left." : "No matches."))
                } else if model.isFiltered {
                    Text("Showing \(min(model.visibleCount, model.displayed.count)) of \(model.displayed.count) filtered "
                        + "(\(model.results.count) matches in all)")
                } else {
                    Text("Showing \(min(model.visibleCount, model.results.count)) of \(model.results.count) matches")
                }
                Spacer()
                if model.displayed.count > model.visibleCount {
                    Button("Load \(AppModel.pageSize) more") { model.loadMore() }
                }
                Button("Open person") {
                    if let id = model.selection.first, let r = model.results.first(where: { $0.id == id }) {
                        model.openPerson(r.ssn)
                    }
                }
                .disabled(model.selection.isEmpty)
            }
            .font(.callout)
            .padding(8)
        }
    }
}

struct ProgressPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let p = model.progress {
                HStack {
                    Text(model.isSearching ? (p.mode == .ssnLookup ? "SSN lookup" : p.mode == .indexLookup ? "Index lookup" : "Scanning") : "Finished")
                        .font(.headline)
                    Spacer()
                    if model.isSearching {
                        Button("Cancel") { model.cancelSearch() }
                    }
                }
                ProgressView(value: p.fraction) {
                    HStack {
                        Text(String(format: "%.1f%%", p.fraction * 100)).monospacedDigit()
                        Text("\(Format.bytes(p.doneBytes)) of \(Format.bytes(p.totalBytes))")
                        Text("· \(p.filesDone)/\(p.filesTotal) files")
                        if p.bytesPerSecond > 0 && model.isSearching {
                            Text(String(format: "· %.0f MB/s", p.bytesPerSecond / 1e6)).monospacedDigit()
                        }
                        if let eta = p.etaSeconds, model.isSearching { Text("· \(Format.duration(eta)) left") }
                        Spacer()
                        Text("\(p.matchCount) matches").bold()
                    }
                    .font(.callout)
                }
                HStack(spacing: 16) {
                    ForEach(DatasetKind.allCases) { k in
                        if let sp = p.perSet[k] {
                            VStack(alignment: .leading, spacing: 2) {
                                ProgressView(value: sp.fraction)
                                Text("\(k.rawValue) \(Int(sp.fraction * 100))%").font(.caption)
                            }
                        }
                    }
                }
                if model.isSearching && !p.currentFiles.isEmpty {
                    Text("Reading: " + p.currentFiles.joined(separator: ", "))
                        .font(.caption.monospaced()).foregroundColor(.secondary).lineLimit(1)
                }
            }
            if let s = model.summary {
                SummaryText(summary: s)
            }
            ForEach(model.failures, id: \.self) { f in
                Label(f, systemImage: "xmark.octagon").foregroundColor(.red).font(.callout)
            }
            ForEach(model.coverageNotes, id: \.self) { n in
                Label(n, systemImage: "info.circle").font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(10)
    }
}

struct SummaryText: View {
    let summary: SearchSummary

    var body: some View {
        let s = summary
        var text = "\(s.matchCount) matches · \(Format.bytes(s.bytesRead)) read in \(Format.duration(s.elapsed))"
        if s.mode == .fullScan && s.elapsed > 0 { text += String(format: " (%.0f MB/s)", s.bytesPerSecond / 1e6) }
        if s.cancelled {
            let done = s.outcomes.filter { $0.state == .done }.count
            text += String(format: " — cancelled at %.0f%%; %d of %d files finished", s.totalBytes > 0
                ? Double(s.bytesRead) / Double(s.totalBytes) * 100 : 0, done, s.outcomes.count)
        }
        if s.hitCap { text += " — stopped at the result limit; refine the search or raise the limit in Settings" }
        return Text(text).font(.callout).foregroundColor(s.cancelled || s.hitCap ? .orange : .primary)
    }
}

struct ResultsTable: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Table(model.visibleResults, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("Set", value: \.setSortKey) { r in Text(r.kind.shortTitle) }.width(min: 40, ideal: 50, max: 60)
            TableColumn("SSN", value: \.ssn) { r in Text(r.ssn).font(.body.monospaced()) }.width(min: 80, ideal: 90)
            TableColumn("Name", value: \.nameSortKey) { r in Text(r.fullName) }.width(min: 140, ideal: 220)
            TableColumn("Born", value: \.dobSortKey) { r in Text(r.dob.description).monospacedDigit() }
                .width(min: 80, ideal: 90)
            TableColumn("Sex", value: \.sex) { r in Text(r.sex) }.width(min: 40, ideal: 55)
            TableColumn("Birthplace", value: \.birthplace) { r in Text(r.birthplace) }.width(min: 80, ideal: 140)
            TableColumn("Event", value: \.eventSortKey) { r in Text(eventLabel(r)) }.width(min: 110, ideal: 150)
            TableColumn("File", value: \.fileSortKey) { r in
                Text(r.fileName).font(.caption.monospaced()).foregroundColor(.secondary)
            }
            .width(min: 90, ideal: 130)
        }
        .contextMenu(forSelectionType: NumidentRecord.ID.self) { ids in
            if let id = ids.first, let r = model.results.first(where: { $0.id == id }) {
                Button("Open person \(r.ssn)") { model.openPerson(r.ssn) }
                Button("Copy SSN") { Pasteboard.copy(r.ssn) }
                Button("Copy citation (Gramps)") { Pasteboard.copy(r.grampsCitation) }
                Button("Copy file name") { Pasteboard.copy(r.fileName) }
                Button("Copy raw line") { Pasteboard.copy(r.rawLine) }
            }
        } primaryAction: { ids in
            if let id = ids.first, let r = model.results.first(where: { $0.id == id }) {
                model.openPerson(r.ssn)
            }
        }
    }

    private func eventLabel(_ r: NumidentRecord) -> String {
        switch r.kind {
        case .ss5: return "SS-5 \(r.cycleDate)"
        case .claim: return "Claim \(r.date("claimDate"))"
        case .death: return "Died \(r.deathDate)"
        }
    }
}

/// Filters the results already found; ⌘F focuses it, Esc clears it.
struct ResultsFilterBar: View {
    @EnvironmentObject var model: AppModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundColor(model.isFiltered ? .accentColor : .secondary)
            TextField("Filter results (⌘F): joe 1917 · first:joe · father:henry · place:boston", text: $model.filterText)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onExitCommand { model.filterText = ""; focused = false }
                .help("All words must appear. A plain word matches any field, including parents and other names. "
                    + "Prefix a word to match one field: first: middle: last: name: father: mother: place: "
                    + "born: died: ssn: set:")
            if model.isFiltered {
                Text("\(model.displayed.count) of \(model.results.count)")
                    .font(.callout).monospacedDigit().foregroundColor(.secondary)
                Button { model.filterText = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .help("Clear filter")
            }
            // Invisible target for ⌘F.
            Button("") { focused = true }
                .keyboardShortcut("f", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

/// Sort keys for the results table. Names sort by last, first, middle;
/// dates by their known parts, with unknown parts first.
extension NumidentRecord {
    var setSortKey: String { kind.shortTitle }
    var nameSortKey: String { "\(lastName) \(firstName) \(middleName)" }
    var dobSortKey: Int { dob.sortKey }
    var eventSortKey: Int { eventDate.sortKey }
    var fileSortKey: String { "\(fileName) \(String(format: "%012lld", offset))" }
}
