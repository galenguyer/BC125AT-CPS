import Foundation

public struct ScannerIdentity: Hashable, Sendable {
    public var model: String
    public var firmware: String
}

public struct ReadProgress: Sendable {
    public var completed: Int
    public var total: Int

    public init(completed: Int, total: Int) {
        self.completed = completed
        self.total = total
    }

    public var fraction: Double { total == 0 ? 0 : Double(completed) / Double(total) }
}

public struct WriteReport: Sendable {
    public struct Failure: Sendable, Identifiable {
        public var id: Int { step.id }
        public var step: WritePlan.Step
        public var reason: String
    }

    /// Steps the scanner acknowledged with `OK`.
    public var written: Int
    /// Steps the scanner rejected (`ERR`/`NG`).
    public var failures: [Failure]
    /// Differences still present when the scanner was read back after writing, described as the
    /// steps that would fix them. Empty when the scanner holds exactly the plan's target.
    public var mismatches: [WritePlan.Step]
    /// The scanner's configuration as read back after writing.
    public var scannerConfig: ScannerConfig
    /// Channels whose frequency the scanner stored differently than predicted (possible where the
    /// plan was only sampled or spot-checked, SPEC.md §3.5). These aren't failures: the scanner snapped the value to
    /// its own plan, and `acceptedConfig` has what it stored.
    public var storedDifferently: [WritePlan.Adjustment] = []
    /// The plan's target with the scanner's stored frequencies, for updating the document.
    public var acceptedConfig: ScannerConfig

    public var succeeded: Bool { failures.isEmpty && mismatches.isEmpty }
}

public enum SessionError: Error, Equatable, CustomStringConvertible {
    case unsupportedModel(String)
    /// `PRG,NG`: the scanner is in a menu, Direct Entry, or Quick Save.
    case programModeRefused

    public var description: String {
        switch self {
        case .unsupportedModel(let model): "This scanner reports itself as \(model.debugDescription), not a BC125AT"
        case .programModeRefused: "The scanner refused program mode. Exit any menu on the scanner, then try again."
        }
    }
}

/// Owns the connection to one scanner and runs one operation at a time (SPEC.md §6.1).
///
/// Commands block for a few milliseconds each, so the actor runs on its own serial queue rather
/// than tying up threads in Swift's cooperative pool.
public actor ScannerSession {
    private let queue = DispatchSerialQueue(label: "net.k9fgt.bc125at.session")
    private let connection: ScannerConnection

    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    public init(transport: sending any LineTransport) {
        connection = ScannerConnection(transport: transport)
    }

    /// Opens the scanner at `locationID` over USB, or the first one found.
    public static func open(locationID: UInt32? = nil) throws(TransportError) -> ScannerSession {
        ScannerSession(transport: try USBTransport(locationID: locationID))
    }

    public func close() {
        connection.transport.close()
    }

    public func identify() throws -> ScannerIdentity {
        ScannerIdentity(
            model: try connection.execute("MDL").joined(separator: ","),
            firmware: try connection.execute("VER").joined(separator: ",")
        )
    }

    // MARK: Live (outside program mode, while the scanner keeps scanning)

    /// `GLG`: what the scanner is tuned to right now (SPEC.md §3.7).
    public func liveStatus() throws -> LiveStatus {
        LiveStatus(glg: try connection.execute("GLG"))
    }

    /// `VOL` and `SQL`, read together.
    public func levels() throws -> (volume: Int, squelch: Int) {
        func level(_ command: String) throws -> Int {
            let fields = try connection.execute(command)
            guard let value = fields.first.flatMap({ Wire.int($0, in: SystemSettings.levelRange) }) else {
                throw Wire.FormatError(command: command, fields: fields)
            }
            return value
        }
        return (try level("VOL"), try level("SQL"))
    }

    /// Sets the volume (0–15) immediately, as the scanner's own control would.
    public func setVolume(_ level: Int) throws {
        _ = try connection.execute("VOL,\(min(max(level, 0), 15))")
    }

    /// Sets the squelch (0 = open – 15) immediately.
    public func setSquelch(_ level: Int) throws {
        _ = try connection.execute("SQL,\(min(max(level, 0), 15))")
    }

    /// Sends `EPG` to recover a scanner left in program mode (SPEC.md §7).
    public func releaseProgramMode() throws {
        try connection.exitProgramMode()
    }

    /// Reads the scanner's whole configuration. Always leaves program mode, including on error or
    /// cancellation. The scanner is left in Scan Hold afterwards.
    public func readConfiguration(progress: @Sendable (ReadProgress) -> Void = { _ in }) throws -> ScannerConfig {
        let identity = try enterProgramMode()
        defer { try? connection.exitProgramMode() }
        var completed = 0
        let total = Self.readSteps
        return try readAll(identity: identity) {
            try Task.checkCancellation()
            completed += 1
            progress(ReadProgress(completed: completed, total: total))
        }
    }

    /// Writes `plan`, then reads the whole scanner back to check it (SPEC.md §7). Commands the
    /// scanner rejects are reported and skipped; transport errors and cancellation stop the write.
    /// Always leaves program mode.
    public func write(_ plan: WritePlan, progress: @Sendable (ReadProgress) -> Void = { _ in }) throws -> WriteReport {
        let identity = try enterProgramMode()
        defer { try? connection.exitProgramMode() }
        let total = plan.steps.count + Self.readSteps
        var completed = 0
        func step() throws {
            try Task.checkCancellation()
            completed += 1
            progress(ReadProgress(completed: completed, total: total))
        }

        var written = 0
        var failures: [WriteReport.Failure] = []
        for planned in plan.steps {
            do {
                let reply = try connection.execute(planned.command)
                if reply == ["OK"] {
                    written += 1
                } else {
                    failures.append(.init(step: planned, reason: "Unexpected reply \(reply.joined(separator: ","))"))
                }
            } catch .rejected {
                failures.append(.init(step: planned, reason: "The scanner rejected the value (ERR)"))
            } catch .notAllowed {
                failures.append(.init(step: planned, reason: "The scanner refused the command (NG)"))
            }
            try step()
        }

        let actual = try readAll(identity: identity, step: step)
        // A channel that matches except for its frequency was snapped by the scanner to its own
        // channel plan: accept what it stored and report it, rather than calling it a failure.
        var accepted = plan.target
        var storedDifferently: [WritePlan.Adjustment] = []
        for number in 1...ScannerConfig.channelCount {
            var expected = accepted[channel: number]
            let stored = actual[channel: number]
            guard let sent = expected.frequency, let kept = stored.frequency, sent != kept else { continue }
            expected.frequency = kept
            guard expected == stored else { continue }
            accepted[channel: number] = expected
            storedDifferently.append(.init(title: "Channel \(number)", detail: "\(sent) MHz was stored as \(kept) MHz"))
        }
        // The target is already as stored, so compare without snapping it again.
        let remaining = WritePlan(from: actual, to: accepted, bandPlan: .rangesOnly)
        return WriteReport(written: written, failures: failures, mismatches: remaining.steps, scannerConfig: actual,
                           storedDifferently: storedDifferently, acceptedConfig: accepted)
    }

    private static let readSteps = settingsCommands + 10 + ScannerConfig.channelCount + 1

    private func enterProgramMode() throws -> ScannerIdentity {
        let identity = try identify()
        guard identity.model == "BC125AT" else { throw SessionError.unsupportedModel(identity.model) }
        do {
            try connection.enterProgramMode()
        } catch .notAllowed {
            throw SessionError.programModeRefused
        }
        return identity
    }

    /// Reads every section; the caller handles program mode.
    private func readAll(identity: ScannerIdentity, step: () throws -> Void) throws -> ScannerConfig {
        var config = ScannerConfig()
        config.metadata = .init(model: identity.model, firmware: identity.firmware, readAt: .now)
        try readSettings(into: &config, step: step)
        for index in 0..<10 {
            config.search.customRanges[index] = try readCustomRange(index + 1, enabled: config.search.customRanges[index].enabled)
            try step()
        }
        for number in 1...ScannerConfig.channelCount {
            let (reported, channel) = try Wire.channel(fromCIN: try connection.execute("CIN,\(number)"))
            guard reported == number else {
                throw Wire.FormatError(command: "CIN", fields: ["\(reported)", "expected \(number)"])
            }
            config[channel: number] = channel
            try step()
        }
        config.globalLockouts = try readGlobalLockouts()
        try step()
        return config
    }

    // MARK: Sections

    private static let settingsCommands = 14

    private func readSettings(into config: inout ScannerConfig, step: () throws -> Void) throws {
        func fields(_ command: String, count: Int) throws -> [String] {
            let fields = try connection.execute(command)
            guard fields.count >= count else { throw Wire.FormatError(command: command, fields: fields) }
            try step()
            return fields
        }
        func parse<T>(_ command: String, _ fields: [String], _ value: T?) throws -> T {
            guard let value else { throw Wire.FormatError(command: command, fields: fields) }
            return value
        }

        var f = try fields("BLT", count: 1)
        config.settings.backlight = try parse("BLT", f, Backlight(rawValue: f[0]))
        f = try fields("BSV", count: 1)
        config.settings.batteryChargeHours = try parse("BSV", f, Wire.int(f[0]))
        f = try fields("KBP", count: 2)
        config.settings.keyBeep = try parse("KBP", f, Wire.int(f[0]).flatMap(KeyBeep.init(rawValue:)))
        config.settings.keyLock = try parse("KBP", f, Wire.bool(f[1]))
        f = try fields("BPL", count: 1)
        config.settings.bandPlan = try parse("BPL", f, Wire.int(f[0]).flatMap(BandPlanRegion.init(rawValue:)))
        f = try fields("PRI", count: 1)
        config.settings.priorityMode = try parse("PRI", f, Wire.int(f[0]).flatMap(PriorityMode.init(rawValue:)))
        f = try fields("SCG", count: 1)
        config.bankScanEnabled = try Wire.enabledFlags(fromInvertedMask: f[0], count: 10, command: "SCG")
        f = try fields("SCO", count: 2)
        config.search.delay = try parse("SCO", f, Wire.int(f[0]).flatMap(Delay.init(rawValue:)))
        config.search.codeSearch = try parse("SCO", f, Wire.bool(f[1]))
        f = try fields("CLC", count: 5)
        config.closeCall.mode = try parse("CLC", f, Wire.int(f[0]).flatMap(CloseCallMode.init(rawValue:)))
        config.closeCall.alertBeep = try parse("CLC", f, Wire.bool(f[1]))
        config.closeCall.alertLight = try parse("CLC", f, Wire.bool(f[2]))
        // Unlike the other masks, Close Call bands use 1 = on.
        guard f[3].count == 5, f[3].allSatisfy({ $0 == "0" || $0 == "1" }) else { throw Wire.FormatError(command: "CLC", fields: f) }
        config.closeCall.bandsEnabled = f[3].map { $0 == "1" }
        config.closeCall.scanHits = try parse("CLC", f, Wire.bool(f[4]))
        f = try fields("SSG", count: 1)
        config.search.serviceGroupsEnabled = try Wire.enabledFlags(fromInvertedMask: f[0], count: 10, command: "SSG")
        f = try fields("CSG", count: 1)
        let rangesEnabled = try Wire.enabledFlags(fromInvertedMask: f[0], count: 10, command: "CSG")
        for (index, enabled) in rangesEnabled.enumerated() { config.search.customRanges[index].enabled = enabled }
        f = try fields("WXS", count: 1)
        config.settings.weatherAlertPriority = try parse("WXS", f, Wire.bool(f[0]))
        f = try fields("CNT", count: 1)
        config.settings.contrast = try parse("CNT", f, Wire.int(f[0]))
        f = try fields("VOL", count: 1)
        config.settings.volume = try parse("VOL", f, Wire.int(f[0]))
        f = try fields("SQL", count: 1)
        config.settings.squelch = try parse("SQL", f, Wire.int(f[0]))
    }

    private func readCustomRange(_ number: Int, enabled: Bool) throws -> CustomSearchRange {
        let f = try connection.execute("CSP,\(number)")
        guard f.count >= 3, Int(f[0]) == number, let lower = Frequency(wire: f[1]), let upper = Frequency(wire: f[2]) else {
            throw Wire.FormatError(command: "CSP", fields: f)
        }
        return CustomSearchRange(lower: lower, upper: upper, enabled: enabled)
    }

    /// `GLF,0` resets the cursor (SPEC.md §3.3); then `GLF` repeats until `-1`.
    private func readGlobalLockouts() throws -> [Frequency] {
        try connection.execute("GLF,0")
        var lockouts: [Frequency] = []
        while lockouts.count <= ScannerConfig.maxGlobalLockouts {
            try Task.checkCancellation()
            let f = try connection.execute("GLF")
            guard let value = f.first else { throw Wire.FormatError(command: "GLF", fields: f) }
            if value == "-1" { break }
            guard let frequency = Frequency(wire: value) else { throw Wire.FormatError(command: "GLF", fields: f) }
            lockouts.append(frequency)
        }
        return Array(Set(lockouts)).sorted()
    }
}
