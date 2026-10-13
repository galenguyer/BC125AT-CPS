import AppKit
import BC125ATKit
import Observation

/// "Write to Scanner" for one document window (SPEC.md §7): read the scanner, show the changes,
/// back the scanner up, write, then read it back to verify.
@MainActor
@Observable
final class ScannerWriter {
    enum State {
        case idle
        case checking(ReadProgress)
        case upToDate
        case review(WritePlan, scanner: ScannerConfig)
        /// Compare with Scanner: the differences, with nothing to write.
        case compared(WritePlan)
        case writing(ReadProgress, WritePlan)
        case finished(WriteReport, WritePlan, backup: URL?)
        case failed(String)
    }

    private(set) var state: State = .idle
    @ObservationIgnored private var task: Task<Void, Never>?

    var isBusy: Bool {
        switch state {
        case .checking, .writing: true
        default: false
        }
    }

    /// Reads the scanner and works out what writing `document` would change. With `compareOnly`,
    /// the result is shown without the option to write. `live` is paused while reading.
    func prepare(document: ScannerConfig, device: USBScannerDevice, live: LiveMonitor, compareOnly: Bool = false) {
        guard !isBusy else { return }
        state = .checking(ReadProgress(completed: 0, total: 1))
        task = Task {
            do {
                let scanner = try await live.withScanner("Paused while checking the scanner", device: device) { session in
                    try await session.readConfiguration { progress in
                        guard progress.completed % 10 == 0 else { return }
                        Task { @MainActor in if case .checking = self.state { self.state = .checking(progress) } }
                    }
                }
                let plan = WritePlan(from: scanner, to: document)
                state = plan.isEmpty ? .upToDate : compareOnly ? .compared(plan) : .review(plan, scanner: scanner)
            } catch is CancellationError {
                state = .idle
            } catch {
                state = .failed(ScannerReader.message(for: error))
            }
        }
    }

    /// Writes the plan being reviewed. Backs up the scanner's current contents first; if the
    /// backup can't be saved, nothing is written. `apply` gets the result so the document can be
    /// updated to what the scanner actually stored.
    func write(device: USBScannerDevice, live: LiveMonitor, apply: @escaping @MainActor (WriteReport, WritePlan) -> Void) {
        guard case .review(let plan, let scanner) = state else { return }
        let backup: URL
        do {
            backup = try BackupStore.save(scanner)
        } catch {
            state = .failed("Couldn't save a backup of the scanner, so nothing was written. \(error.localizedDescription)")
            return
        }
        state = .writing(ReadProgress(completed: 0, total: 1), plan)
        task = Task {
            do {
                let report = try await live.withScanner("Paused while writing to the scanner", device: device) { session in
                    try await session.write(plan) { progress in
                        guard progress.completed % 5 == 0 else { return }
                        Task { @MainActor in if case .writing(_, let plan) = self.state { self.state = .writing(progress, plan) } }
                    }
                }
                apply(report, plan)
                state = .finished(report, plan, backup: backup)
            } catch is CancellationError {
                state = .failed("Writing was cancelled partway through, so the scanner may be partly updated. Read from the scanner to see what it holds now. Its previous contents are in the backup \(backup.lastPathComponent).")
            } catch {
                state = .failed("\(ScannerReader.message(for: error))\n\nThe scanner may be partly updated. Its previous contents are in the backup \(backup.lastPathComponent).")
            }
        }
    }

    func cancel() {
        task?.cancel()
        if case .review = state { state = .idle }
    }

    func dismiss() {
        task = nil
        state = .idle
    }
}

/// Copies of the scanner's contents taken before each write (SPEC.md §7), kept in Application
/// Support. The newest `keep` are kept (50 unless changed in Settings).
enum BackupStore {
    static let retentionKey = "backupRetention"
    static let defaultRetention = 50

    static var keep: Int {
        let stored = UserDefaults.standard.integer(forKey: retentionKey)
        return stored > 0 ? stored : defaultRetention
    }

    static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "BC125AT CPS/Backups", directoryHint: .isDirectory)
    }

    static func save(_ config: ScannerConfig) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = directory.appending(path: "Scanner backup \(formatter.string(from: .now)).bc125at")
        try NativeFormat.encode(config).write(to: url, options: .atomic)
        prune()
        return url
    }

    static func reveal(_ url: URL? = nil) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let url {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(directory)
        }
    }

    private static func prune() {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let backups = files.filter { $0.pathExtension == "bc125at" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return a > b
        }
        for old in backups.dropFirst(keep) { try? fileManager.removeItem(at: old) }
    }
}
