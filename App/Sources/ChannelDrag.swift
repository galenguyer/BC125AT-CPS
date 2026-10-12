import BC125ATKit
import CoreTransferable
import UniformTypeIdentifiers

extension UTType {
    static let bc125atChannelDrag = UTType(exportedAs: "net.k9fgt.bc125at.channel-drag")
}

/// One dragged channel. Within a window, a drop moves channels by number; a drop into another
/// document's window copies the channel data instead, since the numbers mean nothing there.
struct ChannelDrag: Codable, Transferable {
    var number: Int
    var channel: Channel
    /// The document window the drag started in.
    var source: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .bc125atChannelDrag)
    }
}

extension ScannerConfig {
    /// Applies a drop of `items` onto channel `target`: a move if they came from this window,
    /// otherwise a copy into consecutive slots. Returns the channel numbers now holding them.
    @discardableResult
    mutating func drop(_ items: [ChannelDrag], at target: Int, window: UUID) -> [Int] {
        if items.allSatisfy({ $0.source == window }) {
            return moveChannels(items.map(\.number), to: target)
        }
        let channels = items.sorted { $0.number < $1.number }.map(\.channel)
        let slots = Array(target..<min(target + channels.count, Self.channelCount + 1))
        for (slot, channel) in zip(slots, channels) { self[channel: slot] = channel }
        return slots
    }
}
