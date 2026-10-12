import Foundation

/// Channels on the pasteboard as tab-separated text (SPEC.md §8.2), which Numbers and Excel
/// paste as cells and copy back the same way.
public enum ChannelClipboard {
    public static let header = ["Name", "Frequency", "Modulation", "Tone", "Delay", "Lockout", "Priority"]

    /// A header row, then one row per channel. Empty channels become blank rows so their slots
    /// survive a round trip.
    public static func text(for channels: [Channel]) -> String {
        let rows = [header] + channels.map { channel -> [String] in
            guard let frequency = channel.frequency else { return Array(repeating: "", count: header.count) }
            return [channel.name, frequency.megahertzString, channel.modulation.rawValue, channel.tone.displayName,
                    "\(channel.delay.rawValue)", channel.lockedOut ? "Yes" : "No", channel.priority ? "Yes" : "No"]
        }
        return rows.map { $0.map(clean).joined(separator: "\t") }.joined(separator: "\n") + "\n"
    }

    /// Channels from pasted text, or `nil` if any row can't be understood.
    ///
    /// With a header row, columns are matched by name, as for CSV import. Without one, rows are
    /// read in `header` order, except that a single column of frequencies is read as frequencies.
    public static func channels(from text: String) -> [Channel]? {
        var rows = CSVFormat.parse(text, delimiter: "\t")
        guard !rows.isEmpty else { return nil }
        var columns = CSVFormat.columns(fromHeader: rows[0])
        if columns[.frequency] != nil {
            rows.removeFirst()
        } else if rows.allSatisfy({ $0.count == 1 }), rows.allSatisfy({ Frequency(parsing: $0[0]) != nil || $0[0].isEmpty }) {
            columns = [.frequency: 0]
        } else {
            let order: [CSVFormat.Column] = [.name, .frequency, .modulation, .tone, .delay, .lockout, .priority]
            columns = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        }
        var channels: [Channel] = []
        for row in rows {
            if row.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                channels.append(.empty)
                continue
            }
            guard case .success(var channel) = CSVFormat.channel(from: row, columns: columns) else { return nil }
            // A pasted row without a lockout column is a new, active channel.
            if columns[.lockout] == nil, !channel.isEmpty { channel.lockedOut = false }
            channels.append(channel)
        }
        return channels.isEmpty ? nil : channels
    }

    private static func clean(_ field: String) -> String {
        field.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
    }
}
