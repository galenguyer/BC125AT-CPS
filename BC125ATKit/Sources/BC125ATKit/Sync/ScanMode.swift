import Foundation

/// What the scanner is doing when the app isn't using it, so a read or write can put it back
/// afterwards (SPEC.md §3.8). Program mode always ends in Scan Hold on channel 1, so without this
/// the user would have to press Scan, or find their channel again.
public enum ScanMode: Hashable, Sendable {
    case scanning
    /// Scan Hold on a memory channel.
    case hold(channel: Int)
}

/// Keys pressed remotely with `KEY,<key>,P` (SPEC.md §3.8). Not in Uniden's BC125AT command list,
/// but the scanner accepts it outside program mode, as Uniden's other scanners do.
enum ScannerKey: String {
    /// Resumes scanning from hold, and does nothing while scanning.
    case scan = "S"
    /// A toggle: holds while scanning, resumes scanning while held.
    case hold = "H"
}

extension ScannerSession {
    /// How long the scanner must stay on one channel to count as held, and how long when a
    /// signal is open, since scanning also stops on a transmission and for the delay after it.
    static let holdWindow = Duration.milliseconds(1000)
    static let holdWindowWhileReceiving = Duration.milliseconds(3500)

    /// Watches `GLG` to tell scanning from hold: the channel changes several times a second while
    /// scanning, and stays put in hold. `nil` when the scanner isn't on a memory channel (a menu,
    /// search, Close Call Only, weather) or doesn't answer; those modes aren't restored.
    public func scanMode() async throws -> ScanMode? {
        let clock = ContinuousClock()
        let start = clock.now
        var first: Int?
        var window = Self.holdWindow
        while true {
            try Task.checkCancellation()
            guard let status = try? liveStatus(), let channel = status.channel else { return nil }
            if let first, channel != first { return .scanning }
            first = first ?? channel
            if status.receiving { window = Self.holdWindowWhileReceiving }
            if clock.now - start >= window { return .hold(channel: channel) }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Resumes scanning, as pressing Scan does.
    public func scan() throws {
        try press(.scan)
    }

    /// Puts the scanner in hold on `channel`, from scanning or from hold on any channel, and
    /// checks it got there. Number keys while scanning turn banks on and off, so this first
    /// presses Scan (which only ever leads to scanning), then Hold, and only then the digits and
    /// Hold again. Returns false if the scanner ends up elsewhere, for example on an empty channel.
    @discardableResult
    public func hold(on channel: Int) async throws -> Bool {
        precondition((1...ScannerConfig.channelCount).contains(channel))
        try press(.scan)
        try press(.hold)
        for digit in String(channel) { try press(String(digit)) }
        try press(.hold)
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(150))
            if (try? liveStatus())?.channel == channel { return true }
        }
        return false
    }

    /// Puts the scanner back in `mode` after program mode. Returns false if it couldn't.
    @discardableResult
    public func restore(_ mode: ScanMode) async throws -> Bool {
        switch mode {
        case .scanning:
            try scan()
            return true
        case .hold(let channel):
            return try await hold(on: channel)
        }
    }

    private func press(_ key: ScannerKey) throws {
        try press(key.rawValue)
    }

    private func press(_ key: String) throws {
        let reply = try connection.execute("KEY,\(key),P")
        guard reply == ["OK"] else { throw ScannerError.unexpectedResponse(command: "KEY", response: reply.joined(separator: ",")) }
    }
}
