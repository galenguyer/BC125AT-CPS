import BC125ATKit
import SwiftUI

/// A RadioReference export waiting to be imported.
struct RadioReferenceFile: Identifiable {
    let id = UUID()
    var name: String
    var entries: [RadioReferenceFormat.Entry]
}

/// Choose which frequencies from a RadioReference export to import, and the empty channels to put
/// them in (SPEC.md §5.2). Only rows the scanner can receive are offered, all selected to start
/// except ones already in the document with the same name and frequency.
struct RadioReferenceImportSheet: View {
    var file: RadioReferenceFile
    var config: ScannerConfig
    /// The selected channels in file order, and the channel to start at.
    var onImport: ([Channel], Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<Int>
    @State private var start: Int
    @State private var filter = ""

    private let usable: [RadioReferenceFormat.Entry]
    private let skipped: [RadioReferenceFormat.Entry]
    /// Channel numbers already holding each frequency, to point out duplicates.
    private let existing: [Frequency: [Int]]

    init(file: RadioReferenceFile, config: ScannerConfig, onImport: @escaping ([Channel], Int) -> Void) {
        self.file = file
        self.config = config
        self.onImport = onImport
        usable = file.entries.filter(\.isUsable)
        skipped = file.entries.filter { !$0.isUsable }
        var existing: [Frequency: [Int]] = [:]
        for number in 1...ScannerConfig.channelCount {
            if let frequency = config[channel: number].frequency { existing[frequency, default: []].append(number) }
        }
        self.existing = existing
        let selection = RadioReferenceFormat.defaultSelection(file.entries, in: config)
        _selected = State(initialValue: selection)
        _start = State(initialValue: config.firstEmptyRun(ofLength: max(selection.count, 1)) ?? config.firstEmptyRun(ofLength: 1) ?? 1)
    }

    private var visible: [RadioReferenceFormat.Entry] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return usable }
        return usable.filter { entry in
            [entry.frequencyText, entry.alphaTag, entry.description, entry.category, entry.tag, entry.mode]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var chosen: [Channel] { usable.filter { selected.contains($0.id) }.compactMap(\.channel) }

    var body: some View {
        let count = chosen.count
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Import from RadioReference").font(.headline)
                Text("\(file.name): \(usable.count) of \(file.entries.count) frequencies can be used on the BC125AT.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                TextField("Filter", text: $filter, prompt: Text("Filter by name, description, tag or frequency"))
                    .textFieldStyle(.roundedBorder)
                Button("Select All") { selected.formUnion(visible.map(\.id)) }
                Button("Select None") { selected.subtract(visible.map(\.id)) }
            }
            table
            if !skipped.isEmpty {
                DisclosureGroup("\(skipped.count) \(skipped.count == 1 ? "frequency" : "frequencies") can't be used") {
                    List(skipped) { entry in
                        HStack(alignment: .firstTextBaseline) {
                            Text(entry.frequencyText).monospacedDigit().frame(width: 90, alignment: .leading)
                            Text(entry.alphaTag.isEmpty ? entry.description : entry.alphaTag).frame(width: 150, alignment: .leading)
                            Text(entry.skipReason ?? "").foregroundStyle(.secondary)
                        }
                        .lineLimit(1)
                    }
                    .listStyle(.bordered)
                    .frame(height: 120)
                }
            }
            Divider()
            placement(count: count)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Import \(count) \(count == 1 ? "Channel" : "Channels")") {
                    onImport(chosen, start)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(count == 0 || config.emptyRun(from: start) < count)
            }
        }
        .padding(20)
        .frame(minWidth: 760, idealWidth: 860, minHeight: 560, idealHeight: 640)
    }

    private var table: some View {
        Table(visible) {
            TableColumn("") { (entry: RadioReferenceFormat.Entry) in
                Toggle("Import", isOn: Binding(
                    get: { selected.contains(entry.id) },
                    set: { if $0 { selected.insert(entry.id) } else { selected.remove(entry.id) } }
                ))
                .labelsHidden()
            }
            .width(22)
            TableColumn("Frequency") { (entry: RadioReferenceFormat.Entry) in
                Text(entry.channel?.frequency?.megahertzString ?? "").monospacedDigit()
            }
            .width(min: 70, ideal: 80)
            TableColumn("Name") { (entry: RadioReferenceFormat.Entry) in Text(entry.channel?.name ?? "") }
                .width(min: 90, ideal: 130)
            TableColumn("Mod") { (entry: RadioReferenceFormat.Entry) in
                Text(entry.channel?.modulation.displayName ?? "").help("RadioReference mode: \(entry.mode)")
            }
            .width(min: 36, ideal: 44)
            TableColumn("Tone") { (entry: RadioReferenceFormat.Entry) in Text(entry.channel?.tone.displayName ?? "") }
                .width(min: 60, ideal: 84)
            TableColumn("Tag") { (entry: RadioReferenceFormat.Entry) in Text(entry.tag) }
                .width(min: 60, ideal: 100)
            TableColumn("Description") { (entry: RadioReferenceFormat.Entry) in
                Text([entry.category, entry.description].filter { !$0.isEmpty }.joined(separator: " · "))
                    .help(entry.description)
            }
            TableColumn("Notes") { (entry: RadioReferenceFormat.Entry) in
                if let note = notes(for: entry) {
                    Label(note, systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.orange)
                        .help(note)
                }
            }
            .width(40)
        }
    }

    private func notes(for entry: RadioReferenceFormat.Entry) -> String? {
        var notes: [String] = []
        if let note = entry.note { notes.append(note) }
        if let channel = entry.channel, let frequency = channel.frequency, let numbers = existing[frequency] {
            let list = numbers.map(String.init).joined(separator: ", ")
            notes.append(numbers.contains { config[channel: $0].name == channel.name }
                ? "Already on channel \(list) with the same name, so it isn't selected"
                : "This frequency is already on channel \(list)")
        }
        return notes.isEmpty ? nil : notes.joined(separator: "\n")
    }

    @ViewBuilder
    private func placement(count: Int) -> some View {
        let run = config.emptyRun(from: start)
        let end = start + count - 1
        HStack {
            Text("Start at channel")
            TextField("Channel", value: $start, format: .number.grouping(.never))
                .labelsHidden()
                .frame(width: 56)
                .multilineTextAlignment(.trailing)
                .onChange(of: start) { start = min(max(start, 1), ScannerConfig.channelCount) }
            Stepper("Channel", value: $start, in: 1...ScannerConfig.channelCount).labelsHidden()
            Text(bankTitle(Channel.bank(ofChannel: start))).foregroundStyle(.secondary)
            Spacer()
            Button("Find Empty Channels") {
                if let found = config.firstEmptyRun(ofLength: count) { start = found }
            }
            .disabled(count == 0 || config.firstEmptyRun(ofLength: count) == nil)
            .help("Move the start to the first place with \(count) empty channels in a row, keeping them in one bank if possible")
        }
        Group {
            if count == 0 {
                Label("Select at least one frequency to import.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            } else if run >= count {
                Label(count == 1 ? "Channel \(start) is empty." : "Channels \(start)–\(end) are empty.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if ScannerConfig.crossesBanks(start: start, count: count) {
                    Label("These channels run from \(bankTitle(Channel.bank(ofChannel: start))) into \(bankTitle(Channel.bank(ofChannel: end))).",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            } else {
                Label(fitProblem(run: run, count: count), systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func fitProblem(run: Int, count: Int) -> String {
        if run == 0 { return "Channel \(start) is in use. Choose an empty channel to start at." }
        let limit = start + run > ScannerConfig.channelCount
            ? "the last channel is 500"
            : "channel \(start + run) is in use"
        return "Only \(run) empty \(run == 1 ? "channel" : "channels") from \(start) (\(limit)), but \(count) are selected. Choose another start or select fewer."
    }

    private func bankTitle(_ bank: Int) -> String {
        let name = config.bankNames[bank - 1]
        return name.isEmpty ? "Bank \(bank)" : "Bank \(bank) (\(name))"
    }
}
