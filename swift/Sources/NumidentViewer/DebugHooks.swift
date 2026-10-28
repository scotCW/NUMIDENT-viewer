import AppKit
import NumidentCore

/// Environment-driven hooks for automated UI checks (no effect unless the variables are set):
///   NUMIDENT_DATA=/path            use this data folder instead of the saved one
///   NUMIDENT_SEARCH_LAST=NAME      run a last-name search on launch
///   NUMIDENT_PERSON=SSN            open the person sheet for this SSN
///   NUMIDENT_FILTER=WORDS          type WORDS into the results filter 1 s before the snapshot
///   NUMIDENT_SORT=name|-name|born|-born   sort the results table 1 s before the snapshot
///   NUMIDENT_SNAPSHOT=/out.png     save the main window to a PNG after NUMIDENT_SNAPSHOT_DELAY seconds (default 4)
///   NUMIDENT_QUIT=1                quit after the snapshot
@MainActor
enum DebugHooks {
    static weak var model: AppModel?
    static let env = ProcessInfo.processInfo.environment

    static func configure(_ m: AppModel) {
        model = m
        if let data = env["NUMIDENT_DATA"] {
            m.dataFolder = data
            m.rescan()
        }
    }

    static func schedule() {
        guard let model else { return }
        if let last = env["NUMIDENT_SEARCH_LAST"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                model.query.lastName = last
                model.startSearch()
            }
        }
        if let ssn = env["NUMIDENT_PERSON"] {
            // Wait for the data folder scan, or the lookup has no files to search.
            func open() {
                if model.health == nil || model.isScanningCatalog {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { open() }
                } else {
                    model.openPerson(ssn)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { open() }
        }
        if let out = env["NUMIDENT_SNAPSHOT"] {
            // Light appearance so text is legible in the cached bitmap.
            NSApp.appearance = NSAppearance(named: .aqua)
            let delay = Double(env["NUMIDENT_SNAPSHOT_DELAY"] ?? "") ?? 4
            DispatchQueue.main.asyncAfter(deadline: .now() + max(delay - 1, 0)) {
                if let words = env["NUMIDENT_FILTER"] { model.filterText = words }
                if let sort = env["NUMIDENT_SORT"] {
                    let order: SortOrder = sort.hasPrefix("-") ? .reverse : .forward
                    model.sortOrder = sort.hasSuffix("born")
                        ? [KeyPathComparator(\NumidentRecord.dobSortKey, order: order)]
                        : [KeyPathComparator(\NumidentRecord.nameSortKey, order: order)]
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                snapshot(to: out)
                // exit, not terminate: an open sheet can block terminate.
                if env["NUMIDENT_QUIT"] != nil { exit(0) }
            }
        }
    }

    static func snapshot(to path: String) {
        // Main window first, then any sheet (person view) as <name>-sheet1.png.
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.sheetParent == nil
            && $0.contentView != nil && $0.frame.width > 600 }) else { return }
        // The frame view includes the window background and title bar.
        let views = [window.contentView?.superview] + window.sheets.map { $0.contentView?.superview }
        for (i, v) in views.enumerated() {
            guard let v, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
            v.cacheDisplay(in: v.bounds, to: rep)
            let file = i == 0 ? path : path.replacingOccurrences(of: ".png", with: "-sheet\(i).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: file))
        }
    }
}
