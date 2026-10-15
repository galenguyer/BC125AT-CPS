import Foundation

/// Files from Uniden's BC125AT programming software, `.bc125at_ss` (SPEC.md §5.3).
///
/// Tab-separated text with CRLF line endings, one record per line: `Misc`, `Priority`, `WxPri`,
/// 10 × `Service`, 10 × `Custom`, `CloseCall`, `CloseCallBands`, `GeneralSearch`, then for each
/// bank a `Conventional` line followed by its 50 `C-Freq` channel lines. The mapping was checked
/// field by field against a real scanner after Uniden's software wrote three different files.
///
/// Quirks:
/// - `Conventional`, `Service` and `Custom` On/Off are the scanner's raw mask digits, so **On
///   means disabled**. `CloseCallBands` On/Off are the right way round.
/// - Frequencies are in hertz; the scanner works in 100 Hz.
/// - The files have no global lockouts.
public enum UnidenFormat {
    public static let fileExtension = "bc125at_ss"

    public enum ImportError: Error, Equatable, CustomStringConvertible {
        case notAUnidenFile
        case invalid(line: Int, message: String)

        public var description: String {
            switch self {
            case .notAUnidenFile: "This isn't a file from Uniden's BC125AT software."
            case .invalid(let line, let message): "Line \(line) of the file can't be read: \(message)"
            }
        }
    }

    // MARK: Import

    /// Reads a whole configuration. Global lockouts come back empty, since the format has none.
    /// Any value the format isn't known to use stops the import rather than being guessed.
    public static func decode(_ data: Data) throws(ImportError) -> ScannerConfig {
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: Unicode.ASCII.self)
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var config = ScannerConfig()
        var sawMisc = false

        for (index, line) in lines.enumerated() where !line.isEmpty {
            let number = index + 1
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            var reader = FieldReader(fields: fields, line: number)
            do {
                switch fields[0] {
                case "Misc":
                    sawMisc = true
                    config.settings.backlight = try reader.value(backlightNames, "backlight")
                    config.settings.keyBeep = try reader.value(["Auto": .auto, "Off": .off], "key beep")
                    config.settings.keyLock = try reader.onOff("key lock")
                    config.settings.contrast = try reader.integer("contrast")
                    config.settings.batteryChargeHours = try reader.integer("battery charge time")
                    config.settings.volume = try reader.integer("volume")
                    config.settings.squelch = try reader.integer("squelch")
                    config.settings.bandPlan = try reader.value(["USA": .usa, "Canada": .canada], "band plan")
                case "Priority":
                    config.settings.priorityMode = try reader.value(priorityNames, "priority mode")
                case "WxPri":
                    config.settings.weatherAlertPriority = try reader.onOff("weather priority")
                case "Service":
                    let group = try reader.index(in: 1...ServiceSearchGroup.allCases.count, "service group")
                    _ = try reader.text("name")
                    config.search.serviceGroupsEnabled[group - 1] = try !reader.onOff("service group")
                case "Custom":
                    let range = try reader.index(in: 1...config.search.customRanges.count, "custom range")
                    _ = try reader.text("name")
                    let lower = try reader.frequency("lower frequency")
                    let upper = try reader.frequency("upper frequency")
                    let disabled = try reader.onOff("custom range")
                    config.search.customRanges[range - 1] = CustomSearchRange(lower: lower, upper: upper, enabled: !disabled)
                case "CloseCall":
                    config.closeCall.mode = try reader.value(closeCallModeNames, "Close Call mode")
                    config.closeCall.alertBeep = try reader.onOff("alert beep")
                    config.closeCall.alertLight = try reader.onOff("alert light")
                    config.closeCall.scanHits = try reader.onOff("Close Call scan hits")
                case "CloseCallBands":
                    config.closeCall.bandsEnabled = try CloseCallBand.allCases.map { band in try reader.onOff(band.displayName) }
                case "GeneralSearch":
                    config.search.delay = try reader.delay()
                    config.search.codeSearch = try reader.onOff("code search")
                case "Conventional":
                    let bank = try reader.index(in: 1...ScannerConfig.bankCount, "bank")
                    let name = try reader.text("bank name")
                    config.bankNames[bank - 1] = name == defaultBankName(bank) ? "" : name
                    config.bankScanEnabled[bank - 1] = try !reader.onOff("bank scan")
                case "C-Freq":
                    let channel = try reader.index(in: 1...ScannerConfig.channelCount, "channel")
                    config[channel: channel] = try reader.channel()
                default:
                    throw ImportError.invalid(line: number, message: "unknown record “\(fields[0])”")
                }
                try reader.finish()
            } catch let error as ImportError {
                throw error
            } catch {
                throw .invalid(line: number, message: "\(error)")
            }
        }
        guard sawMisc else { throw .notAUnidenFile }
        return config
    }

    // MARK: Export

    /// Writes a file Uniden's software can open. Bank names that are empty become Uniden's
    /// defaults ("Bank 1"); custom search ranges get Uniden's default names.
    public static func encode(_ config: ScannerConfig) -> Data {
        var lines: [String] = []
        // A tab or line break inside a name would split the record, so those become spaces.
        func add(_ fields: Any...) {
            lines.append(fields.map { "\($0)".replacing(/[\t\r\n]/, with: " ") }.joined(separator: "\t"))
        }
        func onOff(_ on: Bool) -> String { on ? "On" : "Off" }

        let settings = config.settings
        add("Misc", name(settings.backlight, in: backlightNames), name(settings.keyBeep, in: ["Auto": .auto, "Off": .off]),
            onOff(settings.keyLock), settings.contrast, settings.batteryChargeHours, settings.volume, settings.squelch,
            settings.bandPlan.displayName)
        add("Priority", name(settings.priorityMode, in: priorityNames))
        add("WxPri", onOff(settings.weatherAlertPriority))
        for group in ServiceSearchGroup.allCases {
            add("Service", group.rawValue + 1, serviceNames[group.rawValue], onOff(!config.search.serviceGroupsEnabled[group.rawValue]))
        }
        for (index, range) in config.search.customRanges.enumerated() {
            add("Custom", index + 1, "Search Bnak\(index + 1)", range.lower.hertz, range.upper.hertz, onOff(!range.enabled))
        }
        let closeCall = config.closeCall
        add("CloseCall", name(closeCall.mode, in: closeCallModeNames), onOff(closeCall.alertBeep), onOff(closeCall.alertLight), onOff(closeCall.scanHits))
        lines.append((["CloseCallBands"] + closeCall.bandsEnabled.map(onOff)).joined(separator: "\t"))
        add("GeneralSearch", config.search.delay.rawValue, onOff(config.search.codeSearch))
        for bank in 1...ScannerConfig.bankCount {
            let name = config.bankNames[bank - 1]
            add("Conventional", bank, name.isEmpty ? defaultBankName(bank) : name, onOff(!config.bankScanEnabled[bank - 1]))
            for number in Channel.channels(inBank: bank) {
                let channel = config[channel: number]
                if channel.isEmpty {
                    add("C-Freq", number, "", 0, "Auto", "Off", "On", 2, "Off")
                } else {
                    add("C-Freq", number, channel.name, channel.frequency?.hertz ?? 0, channel.modulation.displayName,
                        channel.tone.unidenName, onOff(channel.lockedOut), channel.delay.rawValue, onOff(channel.priority))
                }
            }
        }
        return Data(lines.map { $0 + "\r\n" }.joined().utf8)
    }

    // MARK: Names used in the files

    private static let backlightNames: [String: Backlight] = [
        "On": .alwaysOn, "Off": .alwaysOff, "K+S": .keypressAndSquelch,
        // Not yet seen in a file from Uniden's software; named like "K+S".
        "Key": .keypress, "Squelch": .squelch,
    ]
    private static let priorityNames: [String: PriorityMode] = ["Off": .off, "On": .on, "Plus": .plusOn, "DND": .doNotDisturb]
    private static let closeCallModeNames: [String: CloseCallMode] = [
        "Off": .off, "Pri": .priority, "DND": .doNotDisturb,
        // Not yet seen in a file from Uniden's software; named like the others.
        "Only": .closeCallOnly,
    ]
    private static let serviceNames = ["Police", "Fire/Emergency", "HAM Radio", "Marine", "Railroad", "Civil Air",
                                       "Military Air", "CB Radio", "FRS/GMRS/MURS", "Racing"]

    private static func defaultBankName(_ bank: Int) -> String { "Bank \(bank)" }

    private static func name<Value: Equatable>(_ value: Value, in names: [String: Value]) -> String {
        names.first { $0.value == value }!.key
    }

    // MARK: Field reader

    private struct FieldReader {
        var fields: [String]
        var line: Int
        var position = 1

        private func fail(_ message: String) -> ImportError { .invalid(line: line, message: message) }

        mutating func text(_ what: String) throws(ImportError) -> String {
            guard position < fields.count else { throw fail("the \(what) is missing") }
            defer { position += 1 }
            return fields[position]
        }

        mutating func value<Value>(_ names: [String: Value], _ what: String) throws(ImportError) -> Value {
            let text = try text(what)
            guard let value = names[text] else { throw fail("“\(text)” isn't a known \(what)") }
            return value
        }

        mutating func onOff(_ what: String) throws(ImportError) -> Bool {
            try value(["On": true, "Off": false], what)
        }

        mutating func integer(_ what: String) throws(ImportError) -> Int {
            let text = try text(what)
            guard let value = Int(text) else { throw fail("“\(text)” isn't a number (\(what))") }
            return value
        }

        mutating func index(in range: ClosedRange<Int>, _ what: String) throws(ImportError) -> Int {
            let value = try integer(what)
            guard range.contains(value) else { throw fail("\(what) \(value) is out of range") }
            return value
        }

        mutating func frequency(_ what: String) throws(ImportError) -> Frequency {
            let hertz = try integer(what)
            guard hertz >= 0, hertz % 100 == 0 else { throw fail("\(hertz) Hz isn't a whole number of 100 Hz steps (\(what))") }
            return Frequency(hertz: hertz)
        }

        mutating func delay() throws(ImportError) -> Delay {
            let seconds = try integer("delay")
            guard let delay = Delay(rawValue: seconds) else { throw fail("\(seconds) isn't a scanner delay") }
            return delay
        }

        mutating func channel() throws(ImportError) -> Channel {
            let name = try text("name")
            let frequency = try frequency("frequency")
            let modulationText = try text("modulation")
            guard let modulation = Modulation(rawValue: modulationText.uppercased()) else {
                throw fail("“\(modulationText)” isn't a known modulation")
            }
            let toneText = try text("tone")
            guard let tone = ToneCode(unidenName: toneText) else { throw fail("“\(toneText)” isn't a known tone") }
            let lockedOut = try onOff("lockout")
            let delay = try delay()
            let priority = try onOff("priority")
            // Frequency 0 is an empty channel, whatever else the line says.
            guard frequency.hundredHz > 0 else { return .empty }
            return Channel(name: name, frequency: frequency, modulation: modulation, tone: tone,
                           delay: delay, lockedOut: lockedOut, priority: priority)
        }

        func finish() throws(ImportError) {
            guard position >= fields.count else { throw fail("it has \(fields.count - position) more fields than expected") }
        }
    }
}
