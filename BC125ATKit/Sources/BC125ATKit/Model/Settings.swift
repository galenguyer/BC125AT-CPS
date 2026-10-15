import Foundation

public enum Backlight: String, CaseIterable, Codable, Sendable {
    case alwaysOn = "AO"
    case alwaysOff = "AF"
    case keypress = "KY"
    case squelch = "SQ"
    case keypressAndSquelch = "KS"

    public var displayName: String {
        switch self {
        case .alwaysOn: "Always On"
        case .alwaysOff: "Always Off"
        case .keypress: "Keypress"
        case .squelch: "Squelch"
        case .keypressAndSquelch: "Keypress + Squelch"
        }
    }
}

public enum KeyBeep: Int, CaseIterable, Codable, Sendable {
    case auto = 0
    case off = 99

    public var displayName: String { self == .auto ? "Auto" : "Off" }
}

public enum PriorityMode: Int, CaseIterable, Codable, Sendable {
    case off = 0
    case on = 1
    case plusOn = 2
    case doNotDisturb = 3

    public var displayName: String {
        switch self {
        case .off: "Off"
        case .on: "On"
        case .plusOn: "Plus On"
        case .doNotDisturb: "Do Not Disturb"
        }
    }
}

/// The scanner's two band plans (`BPL`), which use different channel steps in some ranges.
public enum BandPlanRegion: Int, CaseIterable, Codable, Sendable {
    case usa = 0
    case canada = 1

    public var displayName: String { self == .usa ? "USA" : "Canada" }
}

/// `BLT`, `BSV`, `KBP`, `BPL`, `PRI`, `CNT`, `WXS`, `VOL`, `SQL`.
public struct SystemSettings: Hashable, Codable, Sendable {
    public var backlight: Backlight = .keypress
    public var keyBeep: KeyBeep = .auto
    public var keyLock = false
    /// 1–15.
    public var contrast = 8
    /// 1–16 hours.
    public var batteryChargeHours = 9
    public var priorityMode: PriorityMode = .off
    public var weatherAlertPriority = false
    /// 0–15.
    public var volume = 8
    /// 0 (open) – 15 (closed).
    public var squelch = 2
    public var bandPlan: BandPlanRegion = .usa

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case backlight, keyBeep, keyLock, contrast, batteryChargeHours, priorityMode, weatherAlertPriority, volume, squelch, bandPlan
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        backlight = try c.decode(Backlight.self, forKey: .backlight)
        keyBeep = try c.decode(KeyBeep.self, forKey: .keyBeep)
        keyLock = try c.decode(Bool.self, forKey: .keyLock)
        contrast = try c.decode(Int.self, forKey: .contrast)
        batteryChargeHours = try c.decode(Int.self, forKey: .batteryChargeHours)
        priorityMode = try c.decode(PriorityMode.self, forKey: .priorityMode)
        weatherAlertPriority = try c.decode(Bool.self, forKey: .weatherAlertPriority)
        volume = try c.decode(Int.self, forKey: .volume)
        squelch = try c.decode(Int.self, forKey: .squelch)
        // The app's backups from before `BPL` was read don't have it; the scanner was on USA then.
        bandPlan = try c.decodeIfPresent(BandPlanRegion.self, forKey: .bandPlan) ?? .usa
    }

    public static let contrastRange = 1...15
    public static let batteryChargeRange = 1...16
    public static let levelRange = 0...15
}

/// The ten service search groups, in `SSG` digit order.
public enum ServiceSearchGroup: Int, CaseIterable, Codable, Sendable {
    case police, fireEmergency, ham, marine, railroad, civilAir, militaryAir, cb, frsGmrsMurs, racing

    public var displayName: String {
        switch self {
        case .police: "Police"
        case .fireEmergency: "Fire/Emergency"
        case .ham: "Ham Radio"
        case .marine: "Marine"
        case .railroad: "Railroad"
        case .civilAir: "Civil Air"
        case .militaryAir: "Military Air"
        case .cb: "CB Radio"
        case .frsGmrsMurs: "FRS/GMRS/MURS"
        case .racing: "Racing"
        }
    }
}

public struct CustomSearchRange: Hashable, Codable, Sendable {
    public var lower: Frequency
    public var upper: Frequency
    public var enabled: Bool

    public init(lower: Frequency, upper: Frequency, enabled: Bool = true) {
        self.lower = lower
        self.upper = upper
        self.enabled = enabled
    }

    /// The factory ranges (SPEC.md §3.6), confirmed against a real scanner.
    public static let factoryDefaults: [CustomSearchRange] = [
        (250_000, 279_950), (280_000, 296_950), (297_000, 499_950), (500_000, 540_000), (1_080_000, 1_369_916),
        (1_370_000, 1_439_950), (1_440_000, 1_479_950), (2_250_000, 3_800_000), (4_000_000, 4_499_937), (4_500_000, 4_699_937),
    ].map { CustomSearchRange(lower: Frequency(hundredHz: $0.0), upper: Frequency(hundredHz: $0.1)) }
}

/// `SCO`, `SSG`, `CSG`, `CSP`.
public struct SearchSettings: Hashable, Codable, Sendable {
    public var delay: Delay = .two
    /// Search for CTCSS/DCS tones during search and Close Call.
    public var codeSearch = false
    /// Indexed by `ServiceSearchGroup.rawValue`.
    public var serviceGroupsEnabled = Array(repeating: true, count: 10)
    public var customRanges = CustomSearchRange.factoryDefaults

    public init() {}
}

public enum CloseCallMode: Int, CaseIterable, Codable, Sendable {
    case off = 0
    case priority = 1
    case doNotDisturb = 2
    /// Searches the Close Call bands continuously instead of scanning, until Scan or Srch is pressed.
    case closeCallOnly = 3

    public var displayName: String {
        switch self {
        case .off: "Off"
        case .priority: "Priority"
        case .doNotDisturb: "Do Not Disturb"
        case .closeCallOnly: "Close Call Only"
        }
    }
}

/// The five Close Call bands, in `CLC` digit order, named as in the scanner's menu.
public enum CloseCallBand: Int, CaseIterable, Codable, Sendable {
    case vhfLow, civilAir, vhfHigh, militaryAir, uhf

    public var displayName: String {
        switch self {
        case .vhfLow: "VHF Low"
        case .civilAir: "Civil Air"
        case .vhfHigh: "VHF High"
        case .militaryAir: "Military Air"
        case .uhf: "UHF"
        }
    }

    /// The range the owner's manual gives for the band.
    public var rangeDescription: String {
        switch self {
        case .vhfLow: "25–54 MHz"
        case .civilAir: "108–137 MHz"
        case .vhfHigh: "137–174 MHz"
        case .militaryAir: "225–320 MHz"
        case .uhf: "320–512 MHz"
        }
    }
}

/// `CLC`.
public struct CloseCallSettings: Hashable, Codable, Sendable {
    public var mode: CloseCallMode = .off
    public var alertBeep = true
    public var alertLight = true
    /// Indexed by `CloseCallBand.rawValue`.
    public var bandsEnabled = Array(repeating: true, count: 5)
    /// Scan the Close Call Hits bank (the last 10 hits) along with the channels. `CLC` calls
    /// this "lockout for CC hits with scan", with `0` = locked out, so `1` means on.
    public var scanHits = false

    public init() {}

    // Saved under its old name, which had the meaning backwards; the stored value is unchanged.
    private enum CodingKeys: String, CodingKey {
        case mode, alertBeep, alertLight, bandsEnabled
        case scanHits = "lockOutHits"
    }
}
