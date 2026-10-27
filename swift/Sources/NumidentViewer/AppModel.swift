import AppKit
import Foundation
import NumidentCore
import SwiftUI

enum Defaults {
    static let dataFolder = "dataFolder"
    static let concurrency = "concurrency"
    static let resultCap = "resultCap"
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
            await MainActor.run {
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
        validationMessage = nil
        // Abandon any previous search entirely (its events are no longer wanted).
        searchHandle?.cancel()
        searchTask?.cancel()
        results = []
        selection = []
        visibleCount = Self.pageSize
        summary = nil
        failures = []
        progress = nil
        searchedFiles = files
        isSearching = true
        let q = query
        let options = SearchOptions(concurrency: concurrency, resultCap: resultCap)
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

    var visibleResults: [NumidentRecord] { Array(results.prefix(visibleCount)) }

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

enum Format {
    static func bytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    static func duration(_ s: Double) -> String {
        if s < 60 { return String(format: "%.0fs", s) }
        return String(format: "%dm %02ds", Int(s) / 60, Int(s) % 60)
    }
}
