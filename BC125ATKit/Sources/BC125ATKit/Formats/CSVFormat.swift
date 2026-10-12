import Foundation

/// Channel import and export as CSV (SPEC.md §5).
///
/// Export writes `Channel,Bank,Name,Frequency,Modulation,Tone,Delay,Lockout,Priority` for every
/// non-empty channel. Import matches columns by header name, so it also reads bc125py's
/// `Index,Name,Frequency (MHz),Modulation,CTCSS,Delay (sec),Lockout,Priority` exports.
public enum CSVFormat {
    public static let header = ["Channel", "Bank", "Name", "Frequency", "Modulation", "Tone", "Delay", "Lockout", "Priority"]

    public static func export(_ config: ScannerConfig) -> String {
        var rows = [header]
        for (offset, channel) in config.channels.enumerated() {
            guard let frequency = channel.frequency else { continue }
            let number = offset + 1
            rows.append([
                "\(number)", "\(Channel.bank(ofChannel: number))", channel.name, frequency.megahertzString,
                channel.modulation.rawValue, channel.tone.displayName, "\(channel.delay.rawValue)",
                channel.lockedOut ? "Yes" : "No", channel.priority ? "Yes" : "No",
            ])
        }
        return rows.map { $0.map(quote).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    public struct Import: Sendable {
        /// Channels to apply, by number. An entry with no frequency clears that channel.
        public var channels: [(number: Int, channel: Channel)]
        /// Rows that couldn't be used, with 1-based line numbers.
        public var problems: [(line: Int, message: String)]
    }

    public enum ImportError: Error, Equatable, CustomStringConvertible {
        case missingColumns([String])

        public var description: String {
            switch self {
            case .missingColumns(let names): "The CSV has no \(names.joined(separator: " or ")) column."
            }
        }
    }

    public static func importChannels(from text: String) throws(ImportError) -> Import {
        let rows = parse(text)
        guard let headerRow = rows.first else { return Import(channels: [], problems: []) }
        let columns = Dictionary(headerRow.enumerated().compactMap { offset, title in
            column(named: title).map { ($0, offset) }
        }, uniquingKeysWith: { first, _ in first })
        let missing = [Column.channel, .frequency].filter { columns[$0] == nil }
        guard missing.isEmpty else { throw .missingColumns(missing.map(\.title)) }

        var result = Import(channels: [], problems: [])
        for (offset, row) in rows.dropFirst().enumerated() {
            let line = offset + 2
            guard row.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { continue }
            func value(_ column: Column) -> String? {
                guard let index = columns[column], index < row.count else { return nil }
                let text = row[index].trimmingCharacters(in: .whitespaces)
                return text.isEmpty ? nil : text
            }
            func problem(_ message: String) { result.problems.append((line, message)) }

            guard let number = value(.channel).flatMap(Int.init), (1...ScannerConfig.channelCount).contains(number) else {
                problem("Channel number \(value(.channel)?.debugDescription ?? "is missing") isn't 1–500")
                continue
            }
            var channel = Channel(name: columns[.name].flatMap { row.indices.contains($0) ? row[$0] : nil } ?? "")
            if let text = value(.frequency) {
                // bc125py writes empty channels as 000.0000.
                if !text.allSatisfy({ $0 == "0" || $0 == "." }) {
                    guard let frequency = Frequency(parsing: text) else { problem("Frequency \(text.debugDescription) isn't a number"); continue }
                    channel.frequency = frequency
                }
            }
            if let text = value(.modulation) {
                let normalized = text.uppercased() == "FMN" ? "NFM" : text.uppercased()
                guard let modulation = Modulation(rawValue: normalized) else { problem("Modulation \(text.debugDescription) isn't AUTO, AM, FM, or NFM"); continue }
                channel.modulation = modulation
            }
            if let text = value(.tone) {
                // Human-readable first ("100" is 100.0 Hz), then bc125py's older raw codes.
                guard let tone = ToneCode(parsing: text) ?? Int(text).flatMap(ToneCode.init(code:)) else {
                    problem("Tone \(text.debugDescription) isn't a CTCSS tone or DCS code"); continue
                }
                channel.tone = tone
            }
            if let text = value(.delay) {
                guard let delay = Int(text.replacingOccurrences(of: "−", with: "-")).flatMap(Delay.init(rawValue:)) else {
                    problem("Delay \(text.debugDescription) isn't one of −10, −5, 0, 1, 2, 3, 4, 5"); continue
                }
                channel.delay = delay
            }
            if let text = value(.lockout) {
                guard let flag = flag(text, trueWords: ["locked", "lockedout", "lockout"], falseWords: ["unlocked"]) else {
                    problem("Lockout \(text.debugDescription) isn't yes or no"); continue
                }
                channel.lockedOut = flag
            }
            if let text = value(.priority) {
                guard let flag = flag(text, trueWords: [], falseWords: []) else { problem("Priority \(text.debugDescription) isn't yes or no"); continue }
                channel.priority = flag
            }
            result.channels.append((number, channel.isEmpty ? .empty : channel))
        }
        return result
    }

    // MARK: Columns

    enum Column: CaseIterable {
        case channel, name, frequency, modulation, tone, delay, lockout, priority

        var title: String { "\(self)".capitalized }

        var aliases: Set<String> {
            switch self {
            case .channel: ["channel", "index", "ch", "number", "no"]
            case .name: ["name", "alphatag", "tag", "label"]
            case .frequency: ["frequency", "frequencymhz", "freq", "freqmhz", "mhz"]
            case .modulation: ["modulation", "mod", "mode"]
            case .tone: ["tone", "ctcss", "ctcssdcs", "dcs", "tonecode", "squelchcode"]
            case .delay: ["delay", "delaysec", "dly"]
            case .lockout: ["lockout", "lockedout", "lo", "lout"]
            case .priority: ["priority", "pri"]
            }
        }
    }

    static func column(named title: String) -> Column? {
        let key = title.lowercased().filter { $0.isLetter || $0.isNumber }
        return Column.allCases.first { $0.aliases.contains(key) }
    }

    private static func flag(_ text: String, trueWords: Set<String>, falseWords: Set<String>) -> Bool? {
        let key = text.lowercased().filter(\.isLetter).isEmpty ? text.lowercased() : text.lowercased().filter(\.isLetter)
        if ["yes", "y", "true", "on", "1"].contains(key) || trueWords.contains(key) { return true }
        if ["no", "n", "false", "off", "0"].contains(key) || falseWords.contains(key) { return false }
        return nil
    }

    // MARK: RFC 4180

    static func quote(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) || field.hasPrefix(" ") || field.hasSuffix(" ")
        else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = ""
        var inQuotes = false
        var iterator = text.unicodeScalars.makeIterator()
        var pending = iterator.next()
        while let scalar = pending {
            pending = iterator.next()
            if inQuotes {
                if scalar == "\"" {
                    if pending == "\"" { field.unicodeScalars.append("\""); pending = iterator.next() } else { inQuotes = false }
                } else {
                    field.unicodeScalars.append(scalar)
                }
                continue
            }
            switch scalar {
            case "\"" where field.isEmpty: inQuotes = true
            case ",": row.append(field); field = ""
            case "\r", "\n":
                if scalar == "\r", pending == "\n" { pending = iterator.next() }
                row.append(field); rows.append(row); row = []; field = ""
            default: field.unicodeScalars.append(scalar)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        // Drop a byte-order mark on the first header cell.
        if let first = rows.first?.first, first.hasPrefix("\u{FEFF}") { rows[0][0] = String(first.dropFirst()) }
        return rows
    }
}
