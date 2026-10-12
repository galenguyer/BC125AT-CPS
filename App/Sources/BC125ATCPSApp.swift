import BC125ATKit
import SwiftUI

@main
struct BC125ATCPSApp: App {
    @State private var monitor = ScannerMonitor()

    var body: some Scene {
        DocumentGroup(newDocument: ScannerDocument()) { file in
            DocumentView(document: file.$document)
                .environment(monitor)
        }
        .commands {
            ScannerCommands(monitor: monitor)
        }
    }
}

/// The frontmost document window's scanner and import/export actions, for the menus.
struct DocumentActions {
    var read: @MainActor () -> Void
    var write: @MainActor () -> Void
    var canUseScanner: Bool
    var importCSV: @MainActor () -> Void
    var exportCSV: @MainActor () -> Void
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
