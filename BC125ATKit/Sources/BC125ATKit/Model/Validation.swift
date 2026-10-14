import Foundation

public struct ValidationIssue: Hashable, Sendable, Identifiable {
    public enum Severity: Int, Comparable, Sendable {
        /// Advisory; writing is still allowed.
        case warning
        /// Blocks writing to the scanner.
        case error

        public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public enum Location: Hashable, Sendable {
        case channel(Int)
        case bank(Int)
        case settings
        case search
        case closeCall
        case globalLockouts
    }

    public var severity: Severity
    public var location: Location
    public var message: String

    public var id: Self { self }
}

extension ScannerConfig {
    /// Every problem in the configuration, in channel order then section order (SPEC.md §3, §4).
    /// Checks frequencies against `bandPlan`, or this configuration's `channelPlan` if nil.
    /// `duplicateFrequencies` turns the duplicate-frequency warnings on or off.
    public func validate(bandPlan: BandPlan? = nil, duplicateFrequencies: Bool = true) -> [ValidationIssue] {
        let bandPlan = bandPlan ?? channelPlan
        var issues: [ValidationIssue] = []
        func add(_ severity: ValidationIssue.Severity, _ location: ValidationIssue.Location, _ message: String) {
            issues.append(ValidationIssue(severity: severity, location: location, message: message))
        }

        // Duplicate frequencies are allowed (the same channel in several banks is common), but
        // flagged on each copy, as Uniden's software does. Compared as stored, so two values that
        // snap to the same channel count as duplicates.
        var channelsByFrequency: [Frequency: [Int]] = [:]
        var duplicates: [Int: String] = [:]
        for (offset, channel) in channels.enumerated() {
            guard let frequency = channel.frequency else { continue }
            channelsByFrequency[bandPlan.storedValue(for: frequency) ?? frequency, default: []].append(offset + 1)
        }
        for (frequency, numbers) in channelsByFrequency where duplicateFrequencies && numbers.count > 1 {
            for number in numbers {
                let others = numbers.filter { $0 != number }
                var list = others.prefix(4).map { other in
                    let name = self[channel: other].name
                    return name.isEmpty ? "channel \(other)" : "channel \(other) “\(name)”"
                }
                if others.count > 4 { list.append("\(others.count - 4) more") }
                let joined = list.count < 2 ? list.joined() : list.dropLast().joined(separator: ", ") + " and " + list.last!
                duplicates[number] = "\(frequency) MHz is also on \(joined)"
            }
        }

        for (offset, channel) in channels.enumerated() where !channel.isEmpty || !channel.name.isEmpty {
            for issue in channel.validate(bandPlan: bandPlan) {
                add(issue.severity, .channel(offset + 1), issue.message)
            }
            // The Canada plan hasn't been measured. Being off the USA plan is only a hint.
            if settings.bandPlan == .canada, let frequency = channel.frequency,
               let usa = BandPlan.bc125at.storedValue(for: frequency), usa != frequency {
                add(.warning, .channel(offset + 1), "\(frequency) MHz isn't on the USA channel plan, so it may not be on the Canada plan either. The scanner may store a nearby frequency; you'll see what it stored after writing")
            }
            if let duplicate = duplicates[offset + 1] {
                add(.warning, .channel(offset + 1), duplicate)
            }
        }

        // The scanner keeps only one priority channel per bank; setting another clears the first.
        for bank in 1...Self.bankCount {
            let priority = Channel.channels(inBank: bank).filter { !self[channel: $0].isEmpty && self[channel: $0].priority }
            if priority.count > 1 {
                for number in priority {
                    add(.error, .channel(number), "Bank \(bank) has \(priority.count) priority channels (\(priority.map(String.init).joined(separator: ", "))); the scanner allows one")
                }
            }
        }
        if !bankScanEnabled.contains(true) {
            add(.warning, .bank(1), "Every bank is disabled, so Scan mode has nothing to scan")
        }

        if !SystemSettings.contrastRange.contains(settings.contrast) {
            add(.error, .settings, "Contrast must be 1–15 (the scanner ignores other values)")
        }
        if !SystemSettings.batteryChargeRange.contains(settings.batteryChargeHours) {
            add(.error, .settings, "Battery charge time must be 1–16 hours")
        }
        if !SystemSettings.levelRange.contains(settings.volume) {
            add(.error, .settings, "Volume must be 0–15")
        }
        if !SystemSettings.levelRange.contains(settings.squelch) {
            add(.error, .settings, "Squelch must be 0–15")
        }
        if settings.bandPlan == .canada {
            add(.warning, .settings, "The band plan is Canada, which BC125AT CPS can't check frequencies against. Frequencies are written as entered, and any the scanner stores differently are shown after writing")
        }

        if !search.serviceGroupsEnabled.contains(true) {
            add(.warning, .search, "Every service search group is disabled")
        }
        if !search.customRanges.contains(where: \.enabled) {
            add(.warning, .search, "Every custom search range is disabled")
        }
        for (offset, range) in search.customRanges.enumerated() {
            let label = "Custom search range \(offset + 1)"
            if !bandPlan.contains(range.lower) { add(.error, .search, "\(label): lower limit \(range.lower) MHz is outside the scanner's bands") }
            if !bandPlan.contains(range.upper) { add(.error, .search, "\(label): upper limit \(range.upper) MHz is outside the scanner's bands") }
            if range.lower > range.upper { add(.error, .search, "\(label): lower limit is above the upper limit") }
        }

        if globalLockouts.count > Self.maxGlobalLockouts {
            add(.error, .globalLockouts, "\(globalLockouts.count) global lockouts; the scanner holds \(Self.maxGlobalLockouts) and silently drops the rest")
        }
        for frequency in globalLockouts where !bandPlan.contains(frequency) {
            add(.error, .globalLockouts, "Lockout \(frequency) MHz is outside the scanner's bands")
        }
        return issues
    }
}

extension Channel {
    /// Problems with this channel on its own (bank-level rules are in `ScannerConfig.validate`).
    public func validate(bandPlan: BandPlan = .bc125at) -> [(severity: ValidationIssue.Severity, message: String)] {
        var issues: [(ValidationIssue.Severity, String)] = []
        if name.count > Self.maxNameLength {
            issues.append((.error, "Name is \(name.count) characters; the scanner keeps \(Self.maxNameLength)"))
        }
        if name.contains(",") {
            issues.append((.error, "Names can't contain commas"))
        }
        if name.unicodeScalars.contains(where: { !(0x20...0x7E).contains($0.value) }) {
            issues.append((.error, "Names can only use plain ASCII characters"))
        }
        if name.hasSuffix(" ") {
            issues.append((.warning, "Trailing spaces in the name will be removed by the scanner"))
        }
        if frequency == nil, !name.isEmpty {
            issues.append((.warning, "Has a name but no frequency, so it won't be written to the scanner"))
        }
        if let frequency {
            if let stored = bandPlan.storedValue(for: frequency) {
                if stored != frequency {
                    issues.append((.warning, "\(frequency) MHz isn't on the scanner's channel plan; it will be stored as \(stored) MHz"))
                }
            } else {
                issues.append((.error, "\(frequency) MHz is outside the scanner's bands (25–54, 108–174, 225–380, 400–512 MHz)"))
            }
        }
        return issues
    }
}
