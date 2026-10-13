import BC125ATKit
import Foundation
import Observation

/// Watches what the scanner is receiving and controls its volume and squelch while it scans
/// (SPEC.md §8.6). Shared by all windows; owned by `ScannerMonitor`.
///
/// Opening the scanner over USB is exclusive, so this holds the connection only while polling.
/// Reading, writing and Release Scanner call `pause` first, which stops polling and closes the
/// connection, then `resume` when they're done.
@MainActor
@Observable
final class LiveMonitor {
    enum State: Equatable {
        case noScanner
        case connecting
        case live
        /// Paused for a read or write; the text says which.
        case paused(String)
        /// Turned off with the bar's pause button.
        case off
        /// Couldn't talk to the scanner (for example, another program has it open). Retries.
        case unavailable(String)
    }

    private(set) var state: State = .noScanner
    /// The latest `GLG` reply.
    private(set) var status: LiveStatus?
    /// True when the channel shown is worth showing: a signal is open, or the scanner has stayed
    /// on it (hold, or the delay after a transmission) rather than passing through while scanning.
    private(set) var settled = false
    /// The most recent transmission and when it was last heard, so a short one isn't lost when
    /// scanning resumes.
    private(set) var lastHeard: (status: LiveStatus, at: Date)?
    private(set) var volume: Int?
    private(set) var squelch: Int?

    var enabled = UserDefaults.standard.object(forKey: "liveEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "liveEnabled")
            if enabled { start() } else { Task { await stop(as: .off) } }
        }
    }

    @ObservationIgnored private var device: USBScannerDevice?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var session: ScannerSession?
    @ObservationIgnored private var pauses = 0
    @ObservationIgnored private var pendingVolume: Int?
    @ObservationIgnored private var pendingSquelch: Int?
    @ObservationIgnored private var lastLevelChange = Date.distantPast
    @ObservationIgnored private var lastMove = Date.distantPast

    /// How often to ask the scanner what it's doing.
    private static let interval = Duration.milliseconds(200)
    /// How long the scanner must stay on a channel to count as settled.
    private static let settleTime = 0.6

    // MARK: Control

    func deviceChanged(_ device: USBScannerDevice?) {
        guard device?.locationID != self.device?.locationID else { return }
        self.device = device
        Task {
            await stop(as: device == nil ? .noScanner : .connecting)
            start()
        }
    }

    func setVolume(_ level: Int) {
        volume = level
        pendingVolume = level
        lastLevelChange = .now
    }

    func setSquelch(_ level: Int) {
        squelch = level
        pendingSquelch = level
        lastLevelChange = .now
    }

    /// Stops polling and releases the scanner until `resume()`. Calls can nest.
    func pause(_ reason: String) async {
        pauses += 1
        await stop(as: .paused(reason))
    }

    func resume() {
        pauses = max(0, pauses - 1)
        start()
    }

    /// Runs `work` with the scanner to itself: pauses polling, opens a session, and closes it
    /// before polling resumes. Every read, write and release goes through here.
    func withScanner<T>(_ reason: String, device: USBScannerDevice,
                        _ work: (ScannerSession) async throws -> T) async throws -> T {
        await pause(reason)
        defer { resume() }
        let session = try ScannerSession.open(locationID: device.locationID)
        do {
            let result = try await work(session)
            await session.close()
            return result
        } catch {
            await session.close()
            throw error
        }
    }

    // MARK: Polling

    private func start() {
        guard task == nil, pauses == 0 else { return }
        guard enabled else { state = .off; return }
        guard let device else { state = .noScanner; return }
        state = .connecting
        task = Task { await run(device) }
    }

    private func stop(as newState: State) async {
        let running = task
        task = nil
        running?.cancel()
        await running?.value
        await closeSession()
        state = newState
        status = nil
        settled = false
    }

    private func closeSession() async {
        guard let session else { return }
        self.session = nil
        await session.close()
    }

    private func run(_ device: USBScannerDevice) async {
        var polls = 0
        while !Task.isCancelled {
            do {
                if session == nil { session = try ScannerSession.open(locationID: device.locationID) }
                guard let session else { break }
                if let level = pendingVolume {
                    pendingVolume = nil
                    try await session.setVolume(level)
                }
                if let level = pendingSquelch {
                    pendingSquelch = nil
                    try await session.setSquelch(level)
                }
                apply(try await session.liveStatus())
                // Pick up changes made on the scanner itself, but not while a slider is moving.
                if polls % 10 == 0, Date.now.timeIntervalSince(lastLevelChange) > 2 {
                    (volume, squelch) = try await session.levels()
                }
                polls += 1
                state = .live
                try await Task.sleep(for: Self.interval)
            } catch is CancellationError {
                break
            } catch {
                guard !Task.isCancelled else { break }
                await closeSession()
                status = nil
                state = .unavailable(Self.message(for: error))
                try? await Task.sleep(for: .seconds(2))
            }
        }
        await closeSession()
    }

    private func apply(_ new: LiveStatus) {
        if new.channel != status?.channel || new.frequency != status?.frequency { lastMove = .now }
        status = new
        settled = new.frequency != nil && (new.receiving || Date.now.timeIntervalSince(lastMove) > Self.settleTime)
        if new.receiving, new.frequency != nil { lastHeard = (new, .now) }
    }

    private static func message(for error: any Error) -> String {
        if let error = error as? TransportError, case .openFailed = error { return "The scanner is in use by another program" }
        return "Can't reach the scanner: \(ScannerReader.message(for: error))"
    }
}
