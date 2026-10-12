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

/// `BLT`, `BSV`, `KBP`, `PRI`, `CNT`, `WXS`, `VOL`, `SQL`.
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

    public init() {}

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

    public var displayName: String {
        switch self {
        case .off: "Off"
        case .priority: "Priority"
        case .doNotDisturb: "Do Not Disturb"
        }
    }
}

/// The five Close Call bands, in `CLC` digit order.
public enum CloseCallBand: Int, CaseIterable, Codable, Sendable {
    case vhfLow, air, vhfHigh1, vhfHigh2, uhf

    public var displayName: String {
        switch self {
        case .vhfLow: "VHF Low"
        case .air: "Air"
        case .vhfHigh1: "VHF High 1"
        case .vhfHigh2: "VHF High 2"
        case .uhf: "UHF"
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
    /// Lock out Close Call hits while scanning.
    public var lockOutHits = false

    public init() {}
}
