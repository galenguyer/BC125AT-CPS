import Foundation

/// Frequencies from a RadioReference CSV export (SPEC.md §5.2).
///
/// RadioReference's county, agency and category pages export
/// `Frequency Output,Frequency Input,FCC Callsign,Agency/Category,Description,Alpha Tag,PL Output Tone,PL Input Tone,Mode,Class Station Code,Tag`.
/// Every row is kept, so the user can see what was left out and why: a row is usable when its
/// mode is analog AM, FM or FMN and its output frequency is in the scanner's bands.
public enum RadioReferenceFormat {
    public struct Entry: Hashable, Sendable, Identifiable {
        /// The 1-based line number in the file.
        public var line: Int
        public var frequencyText: String
        public var mode: String
        public var alphaTag: String
        public var description: String
        /// The Agency/Category column (county exports only).
        public var category: String
        /// RadioReference's service tag, such as `Fire Dispatch` or `Ham`.
        public var tag: String
        public var toneText: String
        /// The channel to import, or `nil` if the scanner can't use this row.
        public var channel: Channel?
        /// Why the row can't be used, when `channel` is `nil`.
        public var skipReason: String?
        /// Something about a usable row that didn't carry over, such as an unsupported tone.
        public var note: String?

        public var id: Int { line }
        public var isUsable: Bool { channel != nil }
    }

    public enum ImportError: Error, Equatable, CustomStringConvertible {
        case empty
        case missingColumns([String])

        public var description: String {
            switch self {
            case .empty: "The file is empty."
            case .missingColumns(let names):
                "This doesn't look like a RadioReference export: it has no \(names.joined(separator: " or ")) column."
            }
        }
    }

    /// The modulations RadioReference uses for analog voice, and the scanner's equivalents.
    /// RadioReference's `FM` is wideband (25 kHz) and `FMN` narrowband (12.5 kHz).
    static let modulations: [String: Modulation] = ["AM": .am, "FM": .fm, "FMN": .nfm, "NFM": .nfm]

    /// Reads every row of an export. `bandPlan` decides which frequencies are in range.
    public static func entries(from text: String, bandPlan: BandPlan = .usa) throws(ImportError) -> [Entry] {
        let rows = CSVFormat.parse(text)
        guard let header = rows.first else { throw .empty }
        let columns = Dictionary(header.enumerated().compactMap { offset, title in column(named: title).map { ($0, offset) } },
                                 uniquingKeysWith: { first, _ in first })
        let missing = [Column.frequency, .mode].filter { columns[$0] == nil }
        guard missing.isEmpty else { throw .missingColumns(missing.map(\.title)) }

        var entries: [Entry] = []
        for (offset, row) in rows.dropFirst().enumerated() {
            guard row.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { continue }
            func value(_ column: Column) -> String {
                guard let index = columns[column], index < row.count else { return "" }
                return row[index].trimmingCharacters(in: .whitespaces)
            }
            var entry = Entry(
                line: offset + 2, frequencyText: value(.frequency), mode: value(.mode), alphaTag: value(.alphaTag),
                description: value(.description), category: value(.category), tag: value(.tag), toneText: value(.tone)
            )
            build(&entry, bandPlan: bandPlan)
            entries.append(entry)
        }
        return entries
    }

    private static func build(_ entry: inout Entry, bandPlan: BandPlan) {
        guard let frequency = Frequency(parsing: entry.frequencyText) else {
            entry.skipReason = entry.frequencyText.isEmpty ? "No frequency" : "Frequency \(entry.frequencyText.debugDescription) isn't a number"
            return
        }
        guard let modulation = modulations[entry.mode.uppercased()] else {
            entry.skipReason = reason(forMode: entry.mode)
            return
        }
        guard bandPlan.contains(frequency) else {
            entry.skipReason = "\(frequency) MHz is outside the scanner's bands"
            return
        }
        var channel = Channel(name: name(alphaTag: entry.alphaTag, description: entry.description),
                              frequency: frequency, modulation: modulation)
        if !entry.toneText.isEmpty {
            if let tone = tone(from: entry.toneText) {
                channel.tone = tone
            } else {
                entry.note = "Tone \(entry.toneText.debugDescription) isn't one the scanner decodes, so the channel is open (CSQ)"
            }
        }
        entry.channel = channel
    }

    /// The usable rows to select at first: all of them, except ones whose name and frequency are
    /// already on a channel in `config` or on an earlier row, so importing an overlapping file
    /// doesn't add the same channel twice.
    public static func defaultSelection(_ entries: [Entry], in config: ScannerConfig) -> Set<Int> {
        struct Key: Hashable { var name: String; var frequency: Frequency }
        var seen = Set(config.channels.compactMap { channel in channel.frequency.map { Key(name: channel.name, frequency: $0) } })
        var selected = Set<Int>()
        for entry in entries {
            guard let channel = entry.channel, let frequency = channel.frequency else { continue }
            if seen.insert(Key(name: channel.name, frequency: frequency)).inserted { selected.insert(entry.id) }
        }
        return selected
    }

    static func reason(forMode mode: String) -> String {
        let key = mode.uppercased().filter { $0.isLetter || $0.isNumber }
        if key.isEmpty { return "No mode" }
        if ["LTR", "MOTOROLA", "EDACS", "MPT1327", "MPT"].contains(key) { return "\(mode) is a trunked system" }
        if ["TELM", "DATA", "TELEMETRY"].contains(key) { return "\(mode) is data, not voice" }
        if ["DMR", "DMRE", "P25", "PROJECT25", "NXDN", "NXDN48", "NXDN96", "DSTAR", "YSF", "DPMR", "TETRA", "PROVOICE", "P25E"]
            .contains(key) || key.hasPrefix("NXDN") || key.hasPrefix("DMR") || key.hasPrefix("P25") {
            return "\(mode) is digital"
        }
        return "The scanner doesn't receive \(mode)"
    }

    /// The alpha tag, or the description if there's no tag, made into a name the scanner accepts:
    /// plain ASCII, no commas, at most 16 characters.
    static func name(alphaTag: String, description: String) -> String {
        let source = alphaTag.isEmpty ? description : alphaTag
        var name = String(String.UnicodeScalarView(source.unicodeScalars.compactMap { scalar in
            scalar == "," ? " " : (0x20...0x7E).contains(scalar.value) ? scalar : nil
        }))
        name = String(name.trimmingCharacters(in: .whitespaces).prefix(Channel.maxNameLength))
        while name.hasSuffix(" ") { name.removeLast() }
        return name
    }

    /// `110.9 PL` → CTCSS 110.9, `023 DPL` → DCS 023, `CSQ` → none. RadioReference's digital
    /// codes (`NAC`, `RAN`, `CC`) return `nil`.
    static func tone(from text: String) -> ToneCode? {
        let parts = text.split(separator: " ")
        guard let value = parts.first.map(String.init) else { return ToneCode.none }
        switch parts.count > 1 ? parts.last!.uppercased() : "" {
        case "PL": return ToneCode(parsing: "ctcss" + value)
        case "DPL", "DCS": return ToneCode(parsing: "dcs" + value)
        case "": return ToneCode(parsing: value)
        default: return nil
        }
    }

    // MARK: Columns

    enum Column: CaseIterable {
        case frequency, mode, alphaTag, description, category, tag, tone

        var title: String {
            switch self {
            case .frequency: "Frequency Output"
            case .mode: "Mode"
            case .alphaTag: "Alpha Tag"
            case .description: "Description"
            case .category: "Agency/Category"
            case .tag: "Tag"
            case .tone: "PL Output Tone"
            }
        }

        var aliases: Set<String> {
            switch self {
            case .frequency: ["frequencyoutput", "frequency", "output", "freq"]
            case .mode: ["mode", "modulation"]
            case .alphaTag: ["alphatag"]
            case .description: ["description"]
            case .category: ["agencycategory", "category", "agency"]
            case .tag: ["tag"]
            case .tone: ["ploutputtone", "tone", "pltone", "ctcssdcs"]
            }
        }
    }

    static func column(named title: String) -> Column? {
        let key = title.lowercased().filter { $0.isLetter || $0.isNumber }
        return Column.allCases.first { $0.aliases.contains(key) }
    }
}

extension ScannerConfig {
    /// How many empty channels there are in a row starting at `start` (0 if `start` is in use).
    public func emptyRun(from start: Int) -> Int {
        guard (1...Self.channelCount).contains(start) else { return 0 }
        var number = start
        while number <= Self.channelCount, self[channel: number].isEmpty { number += 1 }
        return number - start
    }

    /// The first channel that starts `count` empty channels in a row, or `nil` if there isn't room.
    /// Prefers a run that stays in one bank.
    public func firstEmptyRun(ofLength count: Int) -> Int? {
        guard count > 0 else { return nil }
        let starts = (1...Self.channelCount).filter { emptyRun(from: $0) >= count }
        return starts.first { !Self.crossesBanks(start: $0, count: count) } ?? starts.first
    }

    /// Where an import of `count` channels starts at first: the lowest selected channel if it's
    /// empty, otherwise the first run of empty channels that fits (or the first empty channel).
    public func importStart(selection: some Collection<Int>, count: Int) -> Int {
        if let first = selection.min(), (1...Self.channelCount).contains(first), self[channel: first].isEmpty { return first }
        return firstEmptyRun(ofLength: max(count, 1)) ?? firstEmptyRun(ofLength: 1) ?? 1
    }

    /// Whether `count` channels from `start` run past the end of `start`'s bank.
    public static func crossesBanks(start: Int, count: Int) -> Bool {
        count > 0 && Channel.bank(ofChannel: start) != Channel.bank(ofChannel: start + count - 1)
    }

    /// Writes `channels` into consecutive slots from `start`. Returns `false`, and changes nothing,
    /// unless every one of those slots is empty.
    @discardableResult
    public mutating func insert(_ channels: [Channel], at start: Int) -> Bool {
        guard !channels.isEmpty, emptyRun(from: start) >= channels.count else { return false }
        for (offset, channel) in channels.enumerated() { self[channel: start + offset] = channel }
        return true
    }
}
