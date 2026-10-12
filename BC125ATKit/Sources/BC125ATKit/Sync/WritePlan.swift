import Foundation

extension ScannerConfig {
    /// What the scanner will actually hold after this configuration is written (SPEC.md §3):
    /// frequencies snapped to the band plan, names cut to 16 characters with trailing spaces
    /// removed, and empty channels in the scanner's empty state. App-only fields are unchanged.
    public func storedOnScanner(bandPlan: BandPlan = .bc125at) -> ScannerConfig {
        var result = self
        for index in result.channels.indices {
            var channel = result.channels[index]
            guard let frequency = channel.frequency else {
                result.channels[index] = .empty
                continue
            }
            channel.frequency = bandPlan.storedValue(for: frequency) ?? frequency
            var name = String(channel.name.prefix(Channel.maxNameLength))
            while name.hasSuffix(" ") { name.removeLast() }
            channel.name = name
            result.channels[index] = channel
        }
        result.globalLockouts = Array(Set(globalLockouts)).sorted()
        return result
    }
}

/// The commands that turn the scanner's current configuration into a target one (SPEC.md §7).
public struct WritePlan: Sendable {
    public enum Section: String, CaseIterable, Sendable {
        case settings = "Settings"
        case banks = "Banks"
        case search = "Search & Close Call"
        case channels = "Channels"
        case globalLockouts = "Global Lockouts"
    }

    public struct Step: Identifiable, Sendable {
        public var id: Int
        public var section: Section
        /// What is changing: `Channel 12`, `Backlight`.
        public var title: String
        /// `Keypress → Always On`.
        public var detail: String
        public var command: String
    }

    /// Where the configuration as stored on the scanner differs from the document as written
    /// (frequency snapping, name trimming), so the document can be updated to match.
    public struct Adjustment: Sendable, Hashable {
        public var title: String
        public var detail: String
    }

    public let steps: [Step]
    /// The configuration the scanner should hold afterwards.
    public let target: ScannerConfig
    public let adjustments: [Adjustment]

    public var isEmpty: Bool { steps.isEmpty }

    public func steps(in section: Section) -> [Step] { steps.filter { $0.section == section } }

    public init(from current: ScannerConfig, to document: ScannerConfig, bandPlan: BandPlan = .bc125at) {
        let target = document.storedOnScanner(bandPlan: bandPlan)
        self.target = target
        var steps: [Step] = []
        func add(_ section: Section, _ title: String, _ detail: String, _ command: String) {
            steps.append(Step(id: steps.count, section: section, title: title, detail: detail, command: command))
        }
        func change<T: Equatable>(_ old: T, _ new: T, _ describe: (T) -> String) -> String? {
            old == new ? nil : "\(describe(old)) → \(describe(new))"
        }

        // Settings
        let (s0, s1) = (current.settings, target.settings)
        if let d = change(s0.backlight, s1.backlight, \.displayName) { add(.settings, "Backlight", d, "BLT,\(s1.backlight.rawValue)") }
        if let d = change(s0.batteryChargeHours, s1.batteryChargeHours, { "\($0) h" }) { add(.settings, "Battery charge time", d, "BSV,\(s1.batteryChargeHours)") }
        if s0.keyBeep != s1.keyBeep || s0.keyLock != s1.keyLock {
            add(.settings, "Key beep and lock", "\(s0.keyBeep.displayName), lock \(onOff(s0.keyLock)) → \(s1.keyBeep.displayName), lock \(onOff(s1.keyLock))",
                "KBP,\(s1.keyBeep.rawValue),\(Wire.flag(s1.keyLock))")
        }
        if let d = change(s0.priorityMode, s1.priorityMode, \.displayName) { add(.settings, "Priority mode", d, "PRI,\(s1.priorityMode.rawValue)") }
        if let d = change(s0.contrast, s1.contrast, { "\($0)" }) { add(.settings, "Contrast", d, "CNT,\(s1.contrast)") }
        if let d = change(s0.weatherAlertPriority, s1.weatherAlertPriority, onOff) { add(.settings, "Weather alert priority", d, "WXS,\(Wire.flag(s1.weatherAlertPriority))") }
        if let d = change(s0.volume, s1.volume, { "\($0)" }) { add(.settings, "Volume", d, "VOL,\(s1.volume)") }
        if let d = change(s0.squelch, s1.squelch, { "\($0)" }) { add(.settings, "Squelch", d, "SQL,\(s1.squelch)") }

        // Banks
        if let d = change(current.bankScanEnabled, target.bankScanEnabled, Self.describeBanks) {
            add(.banks, "Banks scanned", d, "SCG,\(Wire.invertedMask(target.bankScanEnabled))")
        }

        // Search and Close Call
        let (r0, r1) = (current.search, target.search)
        if r0.delay != r1.delay || r0.codeSearch != r1.codeSearch {
            add(.search, "Search delay and code search", "\(r0.delay.displayName), \(onOff(r0.codeSearch)) → \(r1.delay.displayName), \(onOff(r1.codeSearch))",
                "SCO,\(r1.delay.rawValue),\(Wire.flag(r1.codeSearch))")
        }
        if let d = change(r0.serviceGroupsEnabled, r1.serviceGroupsEnabled, { Self.describeEnabled($0, names: ServiceSearchGroup.allCases.map(\.displayName)) }) {
            add(.search, "Service search groups", d, "SSG,\(Wire.invertedMask(r1.serviceGroupsEnabled))")
        }
        if let d = change(r0.customRanges.map(\.enabled), r1.customRanges.map(\.enabled), { Self.describeEnabled($0, names: (1...10).map { "\($0)" }) }) {
            add(.search, "Custom search ranges enabled", d, "CSG,\(Wire.invertedMask(r1.customRanges.map(\.enabled)))")
        }
        for index in 0..<10 {
            let (a, b) = (r0.customRanges[index], r1.customRanges[index])
            if a.lower != b.lower || a.upper != b.upper {
                add(.search, "Custom search range \(index + 1)", "\(a.lower)–\(a.upper) → \(b.lower)–\(b.upper) MHz",
                    "CSP,\(index + 1),\(b.lower.wireValue),\(b.upper.wireValue)")
            }
        }
        let (c0, c1) = (current.closeCall, target.closeCall)
        if c0 != c1 {
            let bands = String(c1.bandsEnabled.map { $0 ? "1" : "0" })
            add(.search, "Close Call", Self.describeCloseCall(c0) + " → " + Self.describeCloseCall(c1),
                "CLC,\(c1.mode.rawValue),\(Wire.flag(c1.alertBeep)),\(Wire.flag(c1.alertLight)),\(bands),\(Wire.flag(c1.lockOutHits))")
        }

        // Channels. Setting a priority channel clears the bank's others, so priority channels go last.
        let changed = (1...ScannerConfig.channelCount).filter { current[channel: $0] != target[channel: $0] }
        for number in changed.sorted(by: { (target[channel: $0].priority ? 1 : 0, $0) < (target[channel: $1].priority ? 1 : 0, $1) }) {
            add(.channels, "Channel \(number)", Self.describeChange(current[channel: number], target[channel: number]),
                Wire.command(writing: target[channel: number], to: number))
        }

        // Global lockouts: removals first, so there's room for additions.
        let (l0, l1) = (Set(current.globalLockouts), Set(target.globalLockouts))
        for frequency in l0.subtracting(l1).sorted() { add(.globalLockouts, "Remove lockout", "\(frequency) MHz", "ULF,\(frequency.wireValue)") }
        for frequency in l1.subtracting(l0).sorted() { add(.globalLockouts, "Add lockout", "\(frequency) MHz", "LOF,\(frequency.wireValue)") }

        self.steps = steps

        var adjustments: [Adjustment] = []
        for number in 1...ScannerConfig.channelCount {
            let (a, b) = (document[channel: number], target[channel: number])
            if let f = a.frequency, let g = b.frequency, f != g {
                adjustments.append(Adjustment(title: "Channel \(number)", detail: "\(f) MHz will be stored as \(g) MHz"))
            }
            if !a.isEmpty, a.name != b.name {
                adjustments.append(Adjustment(title: "Channel \(number)", detail: "Name \(a.name.debugDescription) will be stored as \(b.name.debugDescription)"))
            }
        }
        self.adjustments = adjustments
    }

    // MARK: Descriptions

    static func describeChange(_ old: Channel, _ new: Channel) -> String {
        if new.isEmpty { return "Clear (was \(describe(old)))" }
        if old.isEmpty { return describe(new) }
        var parts: [String] = []
        if old.name != new.name { parts.append("name \(old.name.debugDescription) → \(new.name.debugDescription)") }
        if old.frequency != new.frequency { parts.append("\(old.frequency?.description ?? "") → \(new.frequency?.description ?? "") MHz") }
        if old.modulation != new.modulation { parts.append("\(old.modulation.displayName) → \(new.modulation.displayName)") }
        if old.tone != new.tone { parts.append("tone \(old.tone.displayName) → \(new.tone.displayName)") }
        if old.delay != new.delay { parts.append("delay \(old.delay.displayName) → \(new.delay.displayName)") }
        if old.lockedOut != new.lockedOut { parts.append(new.lockedOut ? "lock out" : "unlock") }
        if old.priority != new.priority { parts.append(new.priority ? "priority on" : "priority off") }
        return parts.joined(separator: ", ")
    }

    static func describe(_ channel: Channel) -> String {
        guard let frequency = channel.frequency else { return "empty" }
        var text = channel.name.isEmpty ? "" : "\(channel.name) "
        text += "\(frequency) MHz \(channel.modulation.displayName)"
        if channel.tone != .none { text += ", \(channel.tone.displayName)" }
        if channel.lockedOut { text += ", locked out" }
        if channel.priority { text += ", priority" }
        return text
    }

    static func describeBanks(_ enabled: [Bool]) -> String {
        let banks = enabled.indices.filter { enabled[$0] }.map { "\($0 + 1)" }
        return banks.isEmpty ? "none" : banks.joined(separator: ", ")
    }

    static func describeEnabled(_ enabled: [Bool], names: [String]) -> String {
        let on = enabled.indices.filter { enabled[$0] }.map { names[$0] }
        if on.count == enabled.count { return "all" }
        return on.isEmpty ? "none" : on.joined(separator: ", ")
    }

    static func describeCloseCall(_ cc: CloseCallSettings) -> String {
        let bands = describeEnabled(cc.bandsEnabled, names: CloseCallBand.allCases.map(\.displayName))
        return "\(cc.mode.displayName) (beep \(onOff(cc.alertBeep)), light \(onOff(cc.alertLight)), bands \(bands), lockout \(onOff(cc.lockOutHits)))"
    }
}

private func onOff(_ value: Bool) -> String { value ? "on" : "off" }
