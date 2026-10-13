import Foundation
import Synchronization

/// A fake BC125AT that keeps state and reproduces the behaviour measured in Phase 0
/// (SPEC.md §3): program-mode gating, `ERR`/`NG` forms, frequency snapping, one priority channel
/// per bank, the 100-entry lockout list that silently drops extras, `GLF,0` cursor reset, and
/// `CNT` ignoring out-of-range values.
public final class MockScanner: LineTransport, Sendable {
    private let engine: Mutex<Engine>

    public init(config: ScannerConfig = .init(), bandPlan: BandPlan = .bc125at) {
        engine = Mutex(Engine(config: config, bandPlan: bandPlan))
    }

    public var config: ScannerConfig {
        get { engine.withLock { $0.config } }
        set { engine.withLock { $0.config = newValue } }
    }
    public var model: String {
        get { engine.withLock { $0.model } }
        set { engine.withLock { $0.model = newValue } }
    }
    public var firmware: String {
        get { engine.withLock { $0.firmware } }
        set { engine.withLock { $0.firmware = newValue } }
    }
    /// Simulates the scanner being in a menu: `PRG` replies `PRG,NG`.
    public var refusesProgramMode: Bool {
        get { engine.withLock { $0.refusesProgramMode } }
        set { engine.withLock { $0.refusesProgramMode = newValue } }
    }
    /// Commands (by name) that get no reply, to simulate timeouts.
    public var unresponsiveCommands: Set<String> {
        get { engine.withLock { $0.unresponsiveCommands } }
        set { engine.withLock { $0.unresponsiveCommands = newValue } }
    }
    /// The raw `GLG` reply fields (after the command name), as a scanning scanner would report.
    public var glgFields: [String] {
        get { engine.withLock { $0.glgFields } }
        set { engine.withLock { $0.glgFields = newValue } }
    }
    public var inProgramMode: Bool { engine.withLock { $0.inProgramMode } }
    /// Every line received, in order.
    public var received: [String] { engine.withLock { $0.received } }

    public func writeLine(_ line: String, timeout: Duration) throws(TransportError) {
        engine.withLock { engine in
            engine.received.append(line)
            let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard !engine.unresponsiveCommands.contains(fields[0]) else { return }
            engine.replies.append(engine.reply(command: fields[0], arguments: Array(fields.dropFirst())))
        }
    }

    public func readLine(timeout: Duration) throws(TransportError) -> String {
        guard let reply = engine.withLock({ $0.replies.isEmpty ? nil : $0.replies.removeFirst() }) else { throw .timedOut }
        return reply
    }

    public func drainInput() {
        engine.withLock { $0.replies.removeAll() }
    }

    public func close() {}
}

/// The scanner's state and command handling, guarded by `MockScanner`'s mutex.
private struct Engine {
    var config: ScannerConfig
    let bandPlan: BandPlan
    var model = "BC125AT"
    var firmware = "Version 1.06.06"
    var inProgramMode = false
    var received: [String] = []
    var refusesProgramMode = false
    var unresponsiveCommands: Set<String> = []
    var replies: [String] = []
    var lockoutCursor = 0
    var glgFields = Array(repeating: "", count: 12)

    init(config: ScannerConfig, bandPlan: BandPlan) {
        self.config = config
        self.bandPlan = bandPlan
    }

    private static let programModeOnly: Set<String> = [
        "BLT", "BSV", "CLR", "KBP", "PRI", "SCG", "DCH", "CIN", "SCO", "GLF", "ULF", "LOF", "CLC", "SSG", "CSG", "CSP", "WXS", "CNT",
    ]

    mutating func reply(command: String, arguments: [String]) -> String {
        if Self.programModeOnly.contains(command), !inProgramMode { return "\(command),NG" }
        let isGet = arguments.isEmpty
        func ok() -> String { "\(command),OK" }
        func err() -> String { "\(command),ERR" }

        switch command {
        case "MDL": return "MDL,\(model)"
        case "VER": return "VER,\(firmware)"
        case "PRG":
            if refusesProgramMode { return "PRG,NG" }
            inProgramMode = true
            lockoutCursor = 0
            return ok()
        case "EPG":
            inProgramMode = false
            return ok()
        case "BLT":
            if isGet { return "BLT,\(config.settings.backlight.rawValue)" }
            guard let value = Backlight(rawValue: arguments[0]) else { return err() }
            config.settings.backlight = value
            return ok()
        case "BSV":
            if isGet { return "BSV,\(config.settings.batteryChargeHours)" }
            guard let value = Wire.int(arguments[0], in: SystemSettings.batteryChargeRange) else { return err() }
            config.settings.batteryChargeHours = value
            return ok()
        case "KBP":
            if isGet { return "KBP,\(config.settings.keyBeep.rawValue),\(Wire.flag(config.settings.keyLock))" }
            guard arguments.count == 2, let beep = Wire.int(arguments[0]).flatMap(KeyBeep.init(rawValue:)), let lock = Wire.bool(arguments[1])
            else { return err() }
            (config.settings.keyBeep, config.settings.keyLock) = (beep, lock)
            return ok()
        case "PRI":
            if isGet { return "PRI,\(config.settings.priorityMode.rawValue)" }
            guard let value = Wire.int(arguments[0]).flatMap(PriorityMode.init(rawValue:)) else { return err() }
            config.settings.priorityMode = value
            return ok()
        case "SCG", "SSG", "CSG":
            return mask(command, arguments: arguments)
        case "SCO":
            if isGet { return "SCO,\(config.search.delay.rawValue),\(Wire.flag(config.search.codeSearch))" }
            guard arguments.count == 2, let delay = Wire.int(arguments[0]).flatMap(Delay.init(rawValue:)), let code = Wire.bool(arguments[1])
            else { return err() }
            (config.search.delay, config.search.codeSearch) = (delay, code)
            return ok()
        case "CLC":
            let cc = config.closeCall
            if isGet {
                let bands = String(cc.bandsEnabled.map { $0 ? "1" : "0" })
                return "CLC,\(cc.mode.rawValue),\(Wire.flag(cc.alertBeep)),\(Wire.flag(cc.alertLight)),\(bands),\(Wire.flag(cc.lockOutHits))"
            }
            guard arguments.count == 5, let mode = Wire.int(arguments[0]).flatMap(CloseCallMode.init(rawValue:)),
                  let beep = Wire.bool(arguments[1]), let light = Wire.bool(arguments[2]),
                  arguments[3].count == 5, arguments[3].allSatisfy({ $0 == "0" || $0 == "1" }), let lockOut = Wire.bool(arguments[4])
            else { return err() }
            config.closeCall = CloseCallSettings()
            (config.closeCall.mode, config.closeCall.alertBeep, config.closeCall.alertLight) = (mode, beep, light)
            config.closeCall.bandsEnabled = arguments[3].map { $0 == "1" }
            config.closeCall.lockOutHits = lockOut
            return ok()
        case "CSP":
            guard let number = arguments.first.flatMap({ Wire.int($0, in: 1...10) }) else { return err() }
            if arguments.count == 1 {
                let range = config.search.customRanges[number - 1]
                return "CSP,\(number),\(range.lower.wireValue),\(range.upper.wireValue)"
            }
            guard arguments.count == 3, let lower = Frequency(wire: arguments[1]), let upper = Frequency(wire: arguments[2]),
                  bandPlan.contains(lower), bandPlan.contains(upper)
            else { return err() }
            config.search.customRanges[number - 1].lower = lower
            config.search.customRanges[number - 1].upper = upper
            return ok()
        case "WXS":
            if isGet { return "WXS,\(Wire.flag(config.settings.weatherAlertPriority))" }
            guard let value = Wire.bool(arguments[0]) else { return err() }
            config.settings.weatherAlertPriority = value
            return ok()
        case "CNT":
            if isGet { return "CNT,\(config.settings.contrast)" }
            guard let value = Wire.int(arguments[0]) else { return err() }
            // Measured: out-of-range values are acknowledged but ignored.
            if SystemSettings.contrastRange.contains(value) { config.settings.contrast = value }
            return ok()
        case "GLG":
            return (["GLG"] + glgFields).joined(separator: ",")
        case "VOL", "SQL":
            let current = command == "VOL" ? config.settings.volume : config.settings.squelch
            if isGet { return "\(command),\(current)" }
            guard let value = Wire.int(arguments[0], in: SystemSettings.levelRange) else { return err() }
            if command == "VOL" { config.settings.volume = value } else { config.settings.squelch = value }
            return ok()
        case "DCH":
            guard let number = arguments.first.flatMap({ Wire.int($0, in: 1...500) }) else { return err() }
            config[channel: number] = .empty
            return ok()
        case "CIN":
            return channel(arguments)
        case "GLF":
            if !isGet {
                lockoutCursor = 0
                return ok()
            }
            guard lockoutCursor < config.globalLockouts.count else { return "GLF,-1" }
            defer { lockoutCursor += 1 }
            return "GLF,\(config.globalLockouts[lockoutCursor].wireValue)"
        case "LOF", "ULF":
            guard let frequency = arguments.first.flatMap({ Frequency(wire: $0) }), bandPlan.contains(frequency) else { return err() }
            if command == "ULF" {
                config.globalLockouts.removeAll { $0 == frequency }
            } else if !config.globalLockouts.contains(frequency), config.globalLockouts.count < ScannerConfig.maxGlobalLockouts {
                // Measured: a full list still replies OK but drops the new entry.
                config.globalLockouts.append(frequency)
            }
            return ok()
        case "CLR":
            config = ScannerConfig()
            return ok()
        default:
            return "ERR"
        }
    }

    mutating func mask(_ command: String, arguments: [String]) -> String {
        func current() -> [Bool] {
            switch command {
            case "SCG": config.bankScanEnabled
            case "SSG": config.search.serviceGroupsEnabled
            default: config.search.customRanges.map(\.enabled)
            }
        }
        if arguments.isEmpty { return "\(command),\(Wire.invertedMask(current()))" }
        // Measured: all-disabled masks are accepted, despite Uniden's spec.
        guard let flags = try? Wire.enabledFlags(fromInvertedMask: arguments[0], count: 10, command: command) else { return "\(command),ERR" }
        switch command {
        case "SCG": config.bankScanEnabled = flags
        case "SSG": config.search.serviceGroupsEnabled = flags
        default: for (index, enabled) in flags.enumerated() { config.search.customRanges[index].enabled = enabled }
        }
        return "\(command),OK"
    }

    mutating func channel(_ arguments: [String]) -> String {
        guard let number = arguments.first.flatMap({ Wire.int($0, in: 1...500) }) else { return "CIN,ERR" }
        if arguments.count == 1 {
            let channel = config[channel: number]
            return ["CIN", "\(number)", channel.name, channel.frequency?.wireValue ?? "00000000", channel.modulation.rawValue,
                    "\(channel.tone.code)", "\(channel.delay.rawValue)", Wire.flag(channel.lockedOut), Wire.flag(channel.priority)]
                .joined(separator: ",")
        }
        guard arguments.count >= 8 else { return "CIN,ERR" }
        var channel = config[channel: number]
        let tail = Array(arguments.suffix(6))
        let name = arguments[1..<(arguments.count - 6)].joined(separator: ",")
        // Empty fields leave the value unchanged; every non-empty field must be valid or nothing changes.
        if !name.isEmpty {
            var trimmed = String(name.prefix(Channel.maxNameLength))
            while trimmed.hasSuffix(" ") { trimmed.removeLast() }
            channel.name = trimmed
        }
        if !tail[0].isEmpty {
            guard let frequency = Frequency(wire: tail[0]), let stored = bandPlan.storedValue(for: frequency) else { return "CIN,ERR" }
            channel.frequency = stored
        }
        if !tail[1].isEmpty {
            guard let value = Modulation(rawValue: tail[1]) else { return "CIN,ERR" }
            channel.modulation = value
        }
        if !tail[2].isEmpty {
            guard let value = Int(tail[2]).flatMap(ToneCode.init(code:)) else { return "CIN,ERR" }
            channel.tone = value
        }
        if !tail[3].isEmpty {
            guard let value = Int(tail[3]).flatMap(Delay.init(rawValue:)) else { return "CIN,ERR" }
            channel.delay = value
        }
        if !tail[4].isEmpty {
            guard let value = Wire.bool(tail[4]) else { return "CIN,ERR" }
            channel.lockedOut = value
        }
        if !tail[5].isEmpty {
            guard let value = Wire.bool(tail[5]) else { return "CIN,ERR" }
            channel.priority = value
        }
        // Measured: only one priority channel per bank; setting one clears the others.
        if channel.priority {
            for other in Channel.channels(inBank: Channel.bank(ofChannel: number)) where other != number {
                config[channel: other].priority = false
            }
        }
        config[channel: number] = channel
        return "CIN,OK"
    }
}
