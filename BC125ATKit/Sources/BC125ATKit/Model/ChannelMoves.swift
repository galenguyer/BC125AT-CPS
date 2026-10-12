import Foundation

extension ScannerConfig {
    /// Moves the channels in `sources` into consecutive slots starting at `start`, in channel
    /// order (SPEC.md §8.2). Channels already in those slots aren't lost: they move, in order, into
    /// the slots the moved channels left. Slots past 500 are dropped from the move.
    /// Returns the channel numbers the moved channels ended up in.
    @discardableResult
    public mutating func moveChannels(_ sources: some Collection<Int>, to start: Int) -> [Int] {
        let moving = Array(Set(sources)).sorted().filter { (1...Self.channelCount).contains($0) }
        let targets = Array(start..<min(start + moving.count, Self.channelCount + 1))
        let moved = Array(moving.prefix(targets.count))
        guard !moved.isEmpty, moved != targets else { return targets }
        apply(moving: moved, into: targets)
        return targets
    }

    /// Moves channels into the first empty slots of `bank`. Returns the slots used, or `nil` (and
    /// changes nothing) if the bank doesn't have enough room.
    @discardableResult
    public mutating func moveChannels(_ sources: some Collection<Int>, intoBank bank: Int) -> [Int]? {
        let moving = Array(Set(sources)).sorted().filter { (1...Self.channelCount).contains($0) }
        let alreadyThere = moving.filter { Channel.bank(ofChannel: $0) == bank }
        let toMove = moving.filter { Channel.bank(ofChannel: $0) != bank }
        let free = Channel.channels(inBank: bank).filter { self[channel: $0].isEmpty }
        guard free.count >= toMove.count else { return nil }
        let targets = Array(free.prefix(toMove.count))
        apply(moving: toMove, into: targets)
        return (alreadyThere + targets).sorted()
    }

    private mutating func apply(moving sources: [Int], into targets: [Int]) {
        let movingChannels = sources.map { self[channel: $0] }
        let sourceSet = Set(sources), targetSet = Set(targets)
        let displaced = targets.filter { !sourceSet.contains($0) }.map { self[channel: $0] }
        let freed = sources.filter { !targetSet.contains($0) }
        for (slot, channel) in zip(targets, movingChannels) { self[channel: slot] = channel }
        for (slot, channel) in zip(freed, displaced) { self[channel: slot] = channel }
    }
}
