import Foundation

public enum Modulation: String, CaseIterable, Codable, Sendable {
    case auto = "AUTO"
    case am = "AM"
    case fm = "FM"
    case nfm = "NFM"

    public var displayName: String { self == .auto ? "Auto" : rawValue }
}

/// How long the scanner stays on a channel after a transmission ends. Negative values are
/// Uniden's "minus delay" modes.
public enum Delay: Int, CaseIterable, Codable, Sendable {
    case minus10 = -10
    case minus5 = -5
    case zero = 0
    case one = 1
    case two = 2
    case three = 3
    case four = 4
    case five = 5

    public var displayName: String { rawValue < 0 ? "−\(-rawValue) s" : "\(rawValue) s" }
}

/// One of the scanner's 500 memory channels (SPEC.md §3.1). Its position comes from the array
/// it lives in (`ScannerConfig.channels`), not from a stored index.
public struct Channel: Hashable, Sendable {
    public static let maxNameLength = 16

    public var name: String
    /// `nil` for an empty channel.
    public var frequency: Frequency?
    public var modulation: Modulation
    public var tone: ToneCode
    public var delay: Delay
    public var lockedOut: Bool
    public var priority: Bool

    public init(
        name: String = "",
        frequency: Frequency? = nil,
        modulation: Modulation = .auto,
        tone: ToneCode = .none,
        delay: Delay = .two,
        lockedOut: Bool = false,
        priority: Bool = false
    ) {
        self.name = name
        self.frequency = frequency
        self.modulation = modulation
        self.tone = tone
        self.delay = delay
        self.lockedOut = lockedOut
        self.priority = priority
    }

    /// An empty channel exactly as the scanner reports it: `CIN,n,,00000000,AUTO,0,2,1,0`.
    /// Note that it is locked out.
    public static let empty = Channel(lockedOut: true)

    public var isEmpty: Bool { frequency == nil }

    /// Bank 1–10 for a channel number 1–500.
    public static func bank(ofChannel number: Int) -> Int { (number - 1) / 50 + 1 }

    /// Channel numbers 1–500 in a bank 1–10.
    public static func channels(inBank bank: Int) -> ClosedRange<Int> { (bank - 1) * 50 + 1...bank * 50 }
}

extension Channel: Codable {
    enum CodingKeys: String, CodingKey {
        case name, frequency, modulation, tone, delay, lockedOut, priority
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Channel()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? defaults.name
        frequency = try container.decodeIfPresent(Frequency.self, forKey: .frequency)
        modulation = try container.decodeIfPresent(Modulation.self, forKey: .modulation) ?? defaults.modulation
        tone = try container.decodeIfPresent(ToneCode.self, forKey: .tone) ?? defaults.tone
        delay = try container.decodeIfPresent(Delay.self, forKey: .delay) ?? defaults.delay
        lockedOut = try container.decodeIfPresent(Bool.self, forKey: .lockedOut) ?? defaults.lockedOut
        priority = try container.decodeIfPresent(Bool.self, forKey: .priority) ?? defaults.priority
    }
}
