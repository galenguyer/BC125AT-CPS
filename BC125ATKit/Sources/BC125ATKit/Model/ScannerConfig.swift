import Foundation

/// Everything the app reads from, and writes to, a BC125AT (SPEC.md §4).
public struct ScannerConfig: Hashable, Sendable {
    public static let channelCount = 500
    public static let bankCount = 10
    public static let maxGlobalLockouts = 100

    /// Always exactly 500; channel number = index + 1.
    public var channels: [Channel]
    /// Indexed by bank − 1.
    public var bankScanEnabled: [Bool]
    /// App-only labels for banks; never sent to the scanner. Indexed by bank − 1.
    public var bankNames: [String]
    public var settings: SystemSettings
    public var search: SearchSettings
    public var closeCall: CloseCallSettings
    /// Sorted and unique.
    public var globalLockouts: [Frequency]
    public var metadata: Metadata

    public struct Metadata: Hashable, Codable, Sendable {
        public var model: String?
        public var firmware: String?
        public var readAt: Date?
        public var notes: String

        public init(model: String? = nil, firmware: String? = nil, readAt: Date? = nil, notes: String = "") {
            self.model = model
            self.firmware = firmware
            self.readAt = readAt
            self.notes = notes
        }
    }

    public init(
        channels: [Channel] = Array(repeating: .empty, count: channelCount),
        bankScanEnabled: [Bool] = Array(repeating: true, count: bankCount),
        bankNames: [String] = Array(repeating: "", count: bankCount),
        settings: SystemSettings = .init(),
        search: SearchSettings = .init(),
        closeCall: CloseCallSettings = .init(),
        globalLockouts: [Frequency] = [],
        metadata: Metadata = .init()
    ) {
        self.channels = channels
        self.bankScanEnabled = bankScanEnabled
        self.bankNames = bankNames
        self.settings = settings
        self.search = search
        self.closeCall = closeCall
        self.globalLockouts = globalLockouts
        self.metadata = metadata
    }

    /// Channel by number, 1–500.
    public subscript(channel number: Int) -> Channel {
        get { channels[number - 1] }
        set { channels[number - 1] = newValue }
    }

    public var usedChannelCount: Int { channels.count { !$0.isEmpty } }

    /// The channel plan to predict stored frequencies with, for this configuration's band plan.
    public var channelPlan: BandPlan { settings.bandPlan == .canada ? .canada : .usa }

    public func usedChannelCount(inBank bank: Int) -> Int {
        Channel.channels(inBank: bank).count { !self[channel: $0].isEmpty }
    }
}
