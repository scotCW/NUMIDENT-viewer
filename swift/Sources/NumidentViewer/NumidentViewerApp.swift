import AppKit
import NumidentCore
import SwiftUI

@main
struct NumidentViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("NUMIDENT Viewer") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About NUMIDENT Viewer") { AboutPanel.show() }
            }
            CommandGroup(after: .newItem) {
                Button("Rescan Data Folder") { model.rescan() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (swift run) rather than from the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DebugHooks.schedule()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

enum AboutPanel {
    static let repository = "https://github.com/scotCW/NUMIDENT-viewer"

    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits()])
    }

    private static func credits() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 8
        // labelColor keeps the text readable in dark mode.
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        let text = NSMutableAttributedString(
            string: "Searches the National Archives' public-use NUMIDENT files directly from their text files, with no import or database.\n",
            attributes: body)
        var link = body
        link[.link] = URL(string: repository)
        text.append(NSAttributedString(string: "github.com/scotCW/NUMIDENT-viewer\n", attributes: link))
        text.append(NSAttributedString(
            string: "The code is licensed under the Unlicense.\nNot affiliated with or endorsed by SSA or NARA.",
            attributes: body))
        return text
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(Defaults.concurrency) private var concurrency = 2
    @AppStorage(Defaults.resultCap) private var resultCap = 10_000

    var body: some View {
        Form {
            Section("Data folder") {
                HStack {
                    Text(model.dataFolder).font(.body.monospaced()).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { model.chooseFolder() }
                }
                HStack {
                    Button("Use default (\(Defaults.defaultFolder))") {
                        model.dataFolder = Defaults.defaultFolder
                        model.rescan()
                    }
                    Button("Rescan") { model.rescan() }
                }
            }
            Section("Performance") {
                Stepper("Files read at once: \(concurrency)", value: $concurrency, in: 1...4)
                Text("Use 1 for a spinning hard disk (parallel reads make the head seek). Use 2–4 for an SSD; 2 is usually enough to keep a USB 3 or Thunderbolt drive busy.")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Picker("Stop after", selection: $resultCap) {
                    Text("1,000 matches").tag(1_000)
                    Text("10,000 matches").tag(10_000)
                    Text("100,000 matches").tag(100_000)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
