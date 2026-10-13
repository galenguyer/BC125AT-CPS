import BC125ATKit
import SwiftUI

@main
struct BC125ATCPSApp: App {
    @State private var monitor = ScannerMonitor()

    init() {
        // Open a new, empty document at launch instead of the Open panel: reading from the
        // scanner is the usual first step, and an empty document skips the "replace?" question.
        UserDefaults.standard.register(defaults: ["NSShowAppCentricOpenPanelInsteadOfUntitledFile": false])
        TitlebarDoubleClick.install()
    }

    var body: some Scene {
        DocumentGroup(newDocument: ScannerDocument()) { file in
            DocumentView(document: file.$document)
                .environment(monitor)
        }
        .commands {
            ScannerCommands(monitor: monitor)
        }
        Settings {
            AppSettingsView()
        }
    }
}

/// App preferences (⌘,).
struct AppSettingsView: View {
    @AppStorage(BackupStore.retentionKey) private var retention = BackupStore.defaultRetention

    var body: some View {
        Form {
            Section {
                Stepper("Keep the newest \(retention) backups", value: $retention, in: 10...500, step: 10)
                Button("Show Backups in Finder") { BackupStore.reveal() }
            } header: {
                Text("Backups")
            } footer: {
                Text("Before every write, the scanner's current contents are saved as a .bc125at file you can open and write back.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The frontmost document window's scanner and import/export actions, for the menus.
struct DocumentActions {
    var read: @MainActor () -> Void
    var write: @MainActor () -> Void
    var canUseScanner: Bool
    var importCSV: @MainActor () -> Void
    var exportCSV: @MainActor () -> Void
    var importUniden: @MainActor () -> Void
    var exportUniden: @MainActor () -> Void
}

extension FocusedValues {
    @Entry var documentActions: DocumentActions?
}

struct ScannerCommands: Commands {
    var monitor: ScannerMonitor
    @FocusedValue(\.documentActions) private var actions

    var body: some Commands {
        CommandGroup(replacing: .importExport) {
            Button("Import Channels from CSV…") { actions?.importCSV() }
                .disabled(actions == nil)
            Button("Export Channels as CSV…") { actions?.exportCSV() }
                .disabled(actions == nil)
            Divider()
            Button("Import Uniden File…") { actions?.importUniden() }
                .disabled(actions == nil)
                .help("Replace this document with a .bc125at_ss file from Uniden's BC125AT software")
            Button("Export as Uniden File…") { actions?.exportUniden() }
                .disabled(actions == nil)
                .help("Save a .bc125at_ss file that Uniden's BC125AT software can open")
        }
        CommandMenu("Scanner") {
            Button("Read from Scanner…") { actions?.read() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(actions?.canUseScanner != true)
            Button("Write to Scanner…") { actions?.write() }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(actions?.canUseScanner != true)
            Divider()
            Button("Show Backups in Finder") { BackupStore.reveal() }
            Button("Release Scanner") { release() }
                .disabled(monitor.selectedDevice == nil)
                .help("Take the scanner out of program mode if it was left stuck there")
        }
    }

    /// Sends `EPG` to recover a scanner left in program mode (SPEC.md §7).
    private func release() {
        guard let device = monitor.selectedDevice else { return }
        Task {
            do {
                let session = try ScannerSession.open(locationID: device.locationID)
                try await session.releaseProgramMode()
                await session.close()
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }
}
