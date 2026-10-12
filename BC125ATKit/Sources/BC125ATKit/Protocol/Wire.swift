import Foundation

/// Conversions between model types and command fields (SPEC.md §3). Parsing takes the fields
/// after the command name, as returned by `ScannerConnection.execute`.
public enum Wire {
    public struct FormatError: Error, Equatable, CustomStringConvertible {
        public var command: String
        public var fields: [String]

        public var description: String { "Can't understand reply \(([command] + fields).joined(separator: ",").debugDescription)" }
    }

    // MARK: Channels

    /// Parses `CIN` reply fields: the index from the left, the six fixed fields from the right,
    /// and whatever lies between is the name (so a comma in a name can't shift fields).
    public static func channel(fromCIN fields: [String]) throws(FormatError) -> (number: Int, channel: Channel) {
        let error = FormatError(command: "CIN", fields: fields)
        guard fields.count >= 8, let number = Int(fields[0]) else { throw error }
        let tail = Array(fields.suffix(6))
        guard let frequency = Frequency(wire: tail[0]),
              let modulation = Modulation(rawValue: tail[1]),
              let tone = Int(tail[2]).flatMap(ToneCode.init(code:)),
              let delay = Int(tail[3]).flatMap(Delay.init(rawValue:)),
              let lockedOut = bool(tail[4]),
              let priority = bool(tail[5])
        else { throw error }
        let channel = Channel(
            name: fields[1..<(fields.count - 6)].joined(separator: ","),
            frequency: frequency.hundredHz == 0 ? nil : frequency,
            modulation: modulation,
            tone: tone,
            delay: delay,
            lockedOut: lockedOut,
            priority: priority
        )
        return (number, channel)
    }

    /// The command that writes `channel` to slot `number`: `DCH` for an empty channel, otherwise a
    /// full `CIN` set. A blank name is sent as a single space, because an empty field means
    /// "leave unchanged" (SPEC.md §3).
    public static func command(writing channel: Channel, to number: Int) -> String {
        guard let frequency = channel.frequency else { return "DCH,\(number)" }
        let name = channel.name.isEmpty ? " " : channel.name
        return ["CIN", "\(number)", name, frequency.wireValue, channel.modulation.rawValue, "\(channel.tone.code)",
                "\(channel.delay.rawValue)", flag(channel.lockedOut), flag(channel.priority)].joined(separator: ",")
    }

    // MARK: Masks

    /// `SCG`/`SSG`/`CSG` digits: `0` = enabled.
    public static func enabledFlags(fromInvertedMask mask: String, count: Int, command: String) throws(FormatError) -> [Bool] {
        guard mask.count == count, mask.allSatisfy({ $0 == "0" || $0 == "1" }) else { throw FormatError(command: command, fields: [mask]) }
        return mask.map { $0 == "0" }
    }

    public static func invertedMask(_ enabled: [Bool]) -> String {
        String(enabled.map { $0 ? "0" : "1" })
    }

    // MARK: Settings

    static func bool(_ field: String) -> Bool? {
        switch field {
        case "0": false
        case "1": true
        default: nil
        }
    }

    static func flag(_ value: Bool) -> String { value ? "1" : "0" }

    static func int(_ field: String, in range: ClosedRange<Int>? = nil) -> Int? {
        guard let value = Int(field) else { return nil }
        if let range, !range.contains(value) { return nil }
        return value
    }
}
