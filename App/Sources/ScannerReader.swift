import BC125ATKit
import Observation

/// Runs "Read from Scanner" for one document window and reports its progress (SPEC.md §7).
@MainActor
@Observable
final class ScannerReader {
    enum State {
        case idle
        case reading(ReadProgress)
        case finished(ScannerConfig)
        case failed(String)
    }

    private(set) var state: State = .idle
    @ObservationIgnored private var task: Task<Void, Never>?

    var isReading: Bool {
        if case .reading = state { true } else { false }
    }

    /// Reads the whole configuration, then calls `apply` with it on success.
    func read(from device: USBScannerDevice, apply: @escaping @MainActor (ScannerConfig) -> Void) {
        guard !isReading else { return }
        state = .reading(ReadProgress(completed: 0, total: 1))
        task = Task {
            do {
                let session = try ScannerSession.open(locationID: device.locationID)
                defer { Task { await session.close() } }
                let config = try await session.readConfiguration { progress in
                    // Every 10th step is plenty for a progress bar and keeps main-actor hops down.
                    guard progress.completed % 10 == 0 || progress.completed == progress.total else { return }
                    Task { @MainActor in
                        if self.isReading { self.state = .reading(progress) }
                    }
                }
                apply(config)
                state = .finished(config)
            } catch is CancellationError {
                state = .idle
            } catch {
                state = .failed(Self.message(for: error))
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    func dismiss() {
        task = nil
        state = .idle
    }

    static func message(for error: any Error) -> String {
        switch error {
        case let error as SessionError: error.description
        case let error as TransportError:
            switch error {
            case .openFailed: "\(error.description). If another program is talking to the scanner, quit it and try again."
            default: error.description
            }
        case let error as ScannerError: error.description
        case let error as Wire.FormatError: "\(error.description). The scanner may be running firmware this app doesn't know."
        default: error.localizedDescription
        }
    }
}
