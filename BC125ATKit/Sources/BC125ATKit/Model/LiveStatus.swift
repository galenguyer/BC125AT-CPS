import Foundation

/// What the scanner is tuned to right now, from `GLG` (SPEC.md §3.7). `GLG` isn't in Uniden's
/// BC125AT command list, but the scanner answers it outside program mode, using the same layout
/// as Uniden's other scanners:
///
/// `GLG,[FRQ],[MOD],[ATT],[CTCSS/DCS],[NAME1],[NAME2],[NAME3],[SQL],[MUT],[SYS_TAG],[CHAN_TAG],[NAC]`
///
/// On the BC125AT, NAME3 is the channel name, CHAN_TAG the channel number, SQL is 1 while a
/// signal holds squelch open, and the other name and tag fields are empty.
public struct LiveStatus: Hashable, Sendable {
    /// `nil` when the scanner reports no frequency (in a menu, or between modes).
    public var frequency: Frequency?
    public var modulation: Modulation?
    public var tone: ToneCode?
    public var name: String
    /// The memory channel, when the scanner is on one (not while searching or on Close Call).
    public var channel: Int?
    /// A signal is holding squelch open.
    public var receiving: Bool
    public var muted: Bool

    public init(frequency: Frequency? = nil, modulation: Modulation? = nil, tone: ToneCode? = nil, name: String = "",
                channel: Int? = nil, receiving: Bool = false, muted: Bool = false) {
        self.frequency = frequency
        self.modulation = modulation
        self.tone = tone
        self.name = name
        self.channel = channel
        self.receiving = receiving
        self.muted = muted
    }

    /// Parses `GLG`'s fields (without the command name). Missing or empty fields become `nil`.
    public init(glg fields: [String]) {
        func field(_ index: Int) -> String { index < fields.count ? fields[index].trimmingCharacters(in: .whitespaces) : "" }
        frequency = Frequency(wire: field(0)).flatMap { $0.hundredHz > 0 ? $0 : nil }
        modulation = Modulation(rawValue: field(1).uppercased())
        tone = Int(field(3)).flatMap(ToneCode.init(code:))
        name = [field(6), field(5), field(4)].first { !$0.isEmpty } ?? ""
        receiving = field(7) == "1"
        muted = field(8) == "1"
        channel = Int(field(10)).flatMap { (1...ScannerConfig.channelCount).contains($0) ? $0 : nil }
    }

    /// Whether this reply, following `previous`, looks like a priority check rather than the
    /// scanner moving (SPEC.md §3.7): the same memory channel, a different frequency, and no signal.
    /// With priority mode on, the scanner samples the bank's priority channel every 2 seconds even in
    /// hold, and a `GLG` that lands on it reports that channel's frequency under the held channel's
    /// number and name, for one poll. A real change on the channel looks the same at first, so callers
    /// ignore such a reply for one poll only.
    public func looksLikePriorityCheck(after previous: LiveStatus?) -> Bool {
        guard let previous, let channel, channel == previous.channel else { return false }
        return frequency != previous.frequency && !receiving
    }
}
