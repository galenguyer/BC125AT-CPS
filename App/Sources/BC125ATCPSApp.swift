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

/// The frontmost document window's "Read from Scanner" action.
struct ReadFromScannerAction {
    var perform: @MainActor () -> Void
    var isEnabled: Bool
}

extension FocusedValues {
    @Entry var readFromScanner: ReadFromScannerAction?
}

struct ScannerCommands: Commands {
    var monitor: ScannerMonitor
    @FocusedValue(\.readFromScanner) private var readFromScanner
    @State private var releaseError: String?

    var body: some Commands {
        CommandMenu("Scanner") {
            Button("Read from Scanner…") { readFromScanner?.perform() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(readFromScanner?.isEnabled != true)
            Divider()
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
