import AppKit
import Foundation
import NumidentCore
import SwiftUI

enum Defaults {
    static let dataFolder = "dataFolder"
    static let concurrency = "concurrency"
    static let resultCap = "resultCap"
    static let useLastNameIndex = "useLastNameIndex"
    static let defaultFolder = "/Volumes/TranscBlura/NUMIDENT"
}

/// State of the person (SSN) detail sheet.
struct PersonRequest: Identifiable {
    let ssn: String
    var id: String { ssn }
}

@MainActor
final class AppModel: ObservableObject {
    // Dataset
    @Published var health: DatasetHealth?
    @Published var isScanningCatalog = false
    @Published var selectedPaths: Set<String> = []
    @Published var bannerExpanded = false

    // Search
    @Published var query = SearchQuery()
    @Published var isSearching = false
    @Published var progress: SearchProgress?
    @Published var results: [NumidentRecord] = []
    @Published var visibleCount = 500
    @Published var summary: SearchSummary?
    @Published var failures: [String] = []
    @Published var validationMessage: String?
    @Published var searchedFiles: [CatalogFile] = []
    @Published var selection = Set<NumidentRecord.ID>()

    // Filtering and sorting of the results already found (no new disk reads)
    @Published var filterText = "" { didSet { refreshDisplayed() } }
    @Published var sortOrder: [KeyPathComparator<NumidentRecord>] = [] { didSet { refreshDisplayed() } }
    @Published private(set) var displayed: [NumidentRecord] = []
    private var haystacks: [NumidentRecord.ID: FilterText] = [:]

    // Last-name index: only ever built when the user asks, and only used while switched on.
    @Published private(set) var lastNameIndex: LastNameIndex?
    @Published private(set) var indexBuild: IndexBuildProgress?
    @Published var indexError: String?
    private var indexBuildToken: CancelToken?

    // Person sheet
    @Published var personRequest: PersonRequest?
    @Published var person: PersonSummary?
    @Published var personLoading = false

    private var searchTask: Task<Void, Never>?
    private var searchHandle: SearchHandle?
    private var personTask: Task<Void, Never>?

    static let pageSize = 500

    var dataFolder: String {
        get { UserDefaults.standard.string(forKey: Defaults.dataFolder) ?? Defaults.defaultFolder }
        set {
            UserDefaults.standard.set(newValue, forKey: Defaults.dataFolder)
            objectWillChange.send()
        }
    }

    var concurrency: Int {
        let v = UserDefaults.standard.integer(forKey: Defaults.concurrency)
        return v == 0 ? 2 : v
    }

    var resultCap: Int {
        let v = UserDefaults.standard.integer(forKey: Defaults.resultCap)
        return v == 0 ? 10_000 : v
    }

    var useLastNameIndex: Bool {
        get { UserDefaults.standard.bool(forKey: Defaults.useLastNameIndex) }
        set {
            UserDefaults.standard.set(newValue, forKey: Defaults.useLastNameIndex)
            objectWillChange.send()
        }
    }

    var isBuildingIndex: Bool { indexBuild != nil }

    /// Selected usable files the index vouches for (unchanged since it was built).
    var indexCoverage: (covered: Int, total: Int) {
        let files = (health?.allFiles ?? []).filter(\.isUsable)
        guard let idx = lastNameIndex else { return (0, files.count) }
        return (files.filter { idx.fileNumber(for: $0) != nil }.count, files.count)
    }

    init() {
        DebugHooks.configure(self)
        if DebugHooks.env["NUMIDENT_DATA"] == nil { rescan() }
    }

    // MARK: - Dataset

    func rescan() {
        isScanningCatalog = true
        let root = dataFolder
        Task.detached(priority: .userInitiated) {
            let h = Catalog.scan(root: root)
            // Opening only reads an index the user built earlier; nothing is ever built here.
            let index = h.rootExists ? LastNameIndex.open(root: root) : nil
            await MainActor.run {
                self.lastNameIndex = index
                let previous = self.health
                self.health = h
                self.isScanningCatalog = false
                // Keep the user's deselections across rescans; select new usable files by default.
                let usable = Set(h.allFiles.filter(\.isUsable).map(\.path))
                let previouslyKnown = Set(previous?.allFiles.map(\.path) ?? [])
                let deselected = previouslyKnown.subtracting(self.selectedPaths)
                self.selectedPaths = usable.subtracting(deselected)
                if !h.isComplete { self.bannerExpanded = false }
            }
        }
    }

    func usableFiles(_ kind: DatasetKind) -> [CatalogFile] {
        health?.set(kind)?.usableFiles ?? []
    }

    func isSetEnabled(_ kind: DatasetKind) -> Bool {
        usableFiles(kind).contains { selectedPaths.contains($0.path) }
    }

    func setBinding(_ kind: DatasetKind) -> Binding<Bool> {
        Binding(
            get: { self.isSetEnabled(kind) },
            set: { on in
                let paths = self.usableFiles(kind).map(\.path)
                if on { self.selectedPaths.formUnion(paths) } else { self.selectedPaths.subtract(paths) }
            })
    }

    func fileBinding(_ f: CatalogFile) -> Binding<Bool> {
        Binding(
            get: { self.selectedPaths.contains(f.path) },
            set: { on in
                if on { self.selectedPaths.insert(f.path) } else { self.selectedPaths.remove(f.path) }
            })
    }

    var selectedFiles: [CatalogFile] {
        (health?.allFiles ?? []).filter { $0.isUsable && selectedPaths.contains($0.path) }
    }

    var selectedBytes: Int64 { selectedFiles.reduce(0) { $0 + $1.size } }

    // MARK: - Search

    func startSearch() {
        if let problem = query.validate() {
            validationMessage = problem
            return
        }
        let files = selectedFiles
        guard !files.isEmpty else {
            validationMessage = "No files selected."
            return
        }
        guard !isBuildingIndex else {
            validationMessage = "The last-name index is being built; search when it finishes or cancel the build."
            return
        }
        validationMessage = nil
        // Abandon any previous search entirely (its events are no longer wanted).
        searchHandle?.cancel()
        searchTask?.cancel()
        results = []
        haystacks = [:]
        filterText = ""
        refreshDisplayed()
        selection = []
        visibleCount = Self.pageSize
        summary = nil
        failures = []
        progress = nil
        searchedFiles = files
        isSearching = true
        let q = query
        let options = SearchOptions(concurrency: concurrency, resultCap: resultCap,
                                    lastNameIndex: useLastNameIndex ? lastNameIndex : nil)
        let handle = SearchEngine.start(q, files: files, options: options)
        searchHandle = handle
        searchTask = Task {
            for await event in handle.events {
                switch event {
                case .started(let p), .progress(let p):
                    self.progress = p
                case .matches(let m):
                    // Events arrive at most ~4×/s, so the table redraws at that rate.
                    self.results.append(contentsOf: m)
                    for r in m { self.haystacks[r.id] = FilterText(r) }
                    self.refreshDisplayed()
                case .fileFailed(let name, let message):
                    self.failures.append("\(name): \(message)")
                case .finished(let s):
                    self.summary = s
                }
            }
            self.isSearching = false
        }
    }

    /// Stops the workers; the event loop keeps running to receive the partial summary.
    func cancelSearch() {
        searchHandle?.cancel()
    }

    func loadMore() { visibleCount += Self.pageSize }

    var visibleResults: [NumidentRecord] { Array(displayed.prefix(visibleCount)) }

    var isFiltered: Bool { !filterText.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Applies the filter words (all must appear, any order, any case) and the
    /// column sort to every result found so far, not just the visible page.
    private func refreshDisplayed() {
        let terms = FilterText.terms(filterText)
        var rows = terms.isEmpty ? results : results.filter { r in
            haystacks[r.id]?.matches(terms) ?? false
        }
        if !sortOrder.isEmpty { rows.sort(using: sortOrder) }
        displayed = rows
    }

    var coverageNotes: [String] {
        Coverage.notes(health: health, searched: searchedFiles.isEmpty ? selectedFiles : searchedFiles,
                       failed: failures)
    }

    // MARK: - Person

    func openPerson(_ ssn: String) {
        personTask?.cancel()
        person = nil
        personLoading = true
        personRequest = PersonRequest(ssn: ssn)
        let files = selectedFiles
        let health = self.health
        personTask = Task {
            let (records, summary) = await SearchEngine.collect(.ssn(ssn), files: files,
                                                                options: SearchOptions(concurrency: 8, resultCap: 1_000))
            guard !Task.isCancelled else { return }
            let failed = summary?.failed.map { "\($0.file.name)" } ?? []
            let notes = Coverage.notes(health: health, searched: files, failed: failed)
            self.person = PersonSummary(ssn: ssn, records: records, coverageNotes: notes)
            self.personLoading = false
        }
    }

    func closePerson() {
        personTask?.cancel()
        personRequest = nil
        person = nil
    }

    // MARK: - Last-name index

    /// Reads every usable file once and writes LASTNAME-INDEX into the data folder. Only called from
    /// the Build button, after the user confirms.
    func buildIndex() {
        guard !isBuildingIndex, !isSearching, let h = health, h.rootExists else { return }
        let root = dataFolder
        let files = h.allFiles.filter(\.isUsable)
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        let token = CancelToken()
        indexBuildToken = token
        indexError = nil
        indexBuild = IndexBuildProgress(bytesDone: 0, bytesTotal: total, currentFile: "", elapsed: 0)
        Task.detached(priority: .userInitiated) {
            do {
                try LastNameIndexBuilder.build(root: root, files: files, cancel: token) { p in
                    Task { @MainActor in if self.indexBuild != nil { self.indexBuild = p } }
                }
                let index = LastNameIndex.open(root: root)
                await MainActor.run {
                    self.lastNameIndex = index
                    self.indexBuild = nil
                    self.indexBuildToken = nil
                    if index != nil { self.useLastNameIndex = true }
                }
            } catch {
                let message: String? = token.isCancelled ? nil : "Index build failed: \(error)"
                await MainActor.run {
                    self.indexBuild = nil
                    self.indexBuildToken = nil
                    self.indexError = message
                }
            }
        }
    }

    func cancelIndexBuild() { indexBuildToken?.cancel() }

    // MARK: - Settings

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose the NUMIDENT folder (containing NUMSS5, NUMCLM and NUMDEATH)"
        panel.directoryURL = URL(fileURLWithPath: dataFolder)
        if panel.runModal() == .OK, let url = panel.url {
            dataFolder = url.path
            rescan()
        }
    }
}

/// What the results filter matches against. A bare word matches anywhere in the
/// record (decoded fields plus the raw line, so other/signature names and raw
/// MMDDCCYY dates count); `field:word` matches only that field.
struct FilterText {
    static let fieldNames = ["first", "middle", "last", "name", "father", "mother", "place",
                             "born", "died", "ssn", "set"]

    let all: String
    let fields: [String: String]

    init(_ r: NumidentRecord) {
        var f: [String: String] = [
            "first": r.firstName, "middle": r.middleName, "last": r.lastName, "name": r.fullName,
            "father": r.fatherName, "mother": r.motherName, "place": r.birthplace,
            "born": r.dob.description,
            "died": r.deathDate.description, "ssn": r.ssn, "set": r.kind.shortTitle,
        ]
        for (k, v) in f { f[k] = v.uppercased() }
        fields = f
        all = (f.values.joined(separator: " ") + " " + r.rawLine).uppercased()
    }

    /// Splits the filter into (field, word) terms; field is nil for a bare word.
    static func terms(_ text: String) -> [(field: String?, word: String)] {
        text.split(whereSeparator: \.isWhitespace).compactMap { token in
            let t = String(token)
            if let colon = t.firstIndex(of: ":") {
                let field = t[..<colon].lowercased()
                let word = t[t.index(after: colon)...].uppercased()
                if fieldNames.contains(field) {
                    return word.isEmpty ? nil : (field, word)
                }
            }
            return (nil, t.uppercased())
        }
    }

    func matches(_ terms: [(field: String?, word: String)]) -> Bool {
        terms.allSatisfy { t in
            guard let field = t.field else { return all.contains(t.word) }
            return fields[field]?.contains(t.word) ?? false
        }
    }
}

enum Format {
    static func bytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    static func duration(_ s: Double) -> String {
        if s < 60 { return String(format: "%.0fs", s) }
        return String(format: "%dm %02ds", Int(s) / 60, Int(s) % 60)
    }
}
