import AppKit
import BC125ATKit
import SwiftUI

struct ChannelRow: Identifiable {
    var id: Int { number }
    var number: Int
    var channel: Channel
    var issues: [ValidationIssue]

    var frequencyText: String { channel.frequency?.megahertzString ?? "" }
}

/// The channel editor (SPEC.md §8.2). Every change goes through `config`, so each one is a single
/// undo step; bulk edits and pastes change many channels in one step.
struct ChannelTableView: View {
    @Binding var config: ScannerConfig
    var numbers: [Int]
    var issues: [ValidationIssue]
    var title: String

    @AppStorage("showEmptyChannels") private var showEmptyChannels = false
    @State private var searchText = ""
    @State private var selection = Set<Int>()
    @State private var sortOrder = [KeyPathComparator(\ChannelRow.number)]

    var body: some View {
        let rows = makeRows()
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("") { row in
                if let worst = row.issues.map(\.severity).max() {
                    IssueIcon(severity: worst)
                        .help(row.issues.map(\.message).joined(separator: "\n"))
                }
            }
            .width(18)
            TableColumn("#", value: \.number) { row in
                Text("\(row.number)").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 32, ideal: 40, max: 50)
            TableColumn("Name", value: \.channel.name) { row in
                CommitTextField(title: row.channel.isEmpty ? "" : "No name", value: row.channel.name) { text in
                    edit(row.number) { $0.name = text }
                    return true
                }
                .disabled(row.channel.isEmpty)
            }
            .width(min: 100, ideal: 150)
            TableColumn("Frequency (MHz)", value: \.frequencyText) { row in
                FrequencyField(title: row.channel.isEmpty ? "Add…" : "MHz", frequency: row.channel.frequency, allowsEmpty: true) { frequency in
                    config.setFrequency(frequency, ofChannel: row.number)
                }
            }
            .width(min: 90, ideal: 110)
            TableColumn("Mod") { row in
                if !row.channel.isEmpty {
                    Picker("Modulation", selection: channelBinding(row.number, \.modulation)) {
                        ForEach(Modulation.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                }
            }
            .width(min: 60, ideal: 70)
            TableColumn("Tone") { row in
                if !row.channel.isEmpty {
                    Menu(row.channel.tone.displayName) {
                        ToneMenuItems { tone in edit(row.number) { $0.tone = tone } }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            .width(min: 80, ideal: 105)
            TableColumn("Delay") { row in
                if !row.channel.isEmpty {
                    Picker("Delay", selection: channelBinding(row.number, \.delay)) {
                        ForEach(Delay.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                }
            }
            .width(min: 60, ideal: 70)
            TableColumn("L/O") { row in
                if !row.channel.isEmpty {
                    Toggle("Locked out", isOn: channelBinding(row.number, \.lockedOut))
                        .labelsHidden()
                        .help("Skip this channel when scanning")
                }
            }
            .width(min: 28, ideal: 32)
            TableColumn("Pri") { row in
                if !row.channel.isEmpty {
                    Toggle("Priority", isOn: channelBinding(row.number, \.priority))
                        .labelsHidden()
                        .help("Priority channel (one per bank)")
                }
            }
            .width(min: 28, ideal: 32)
        }
        .contextMenu(forSelectionType: Int.self) { numbers in
            if !numbers.isEmpty { bulkMenu(for: numbers) }
        }
        .onCopyCommand { copyItems() }
        .onCutCommand {
            let items = copyItems()
            clear(selection)
            return items
        }
        .onPasteCommand(of: [.plainText]) { providers in paste(providers) }
        .onDeleteCommand { clear(selection) }
        .overlay {
            if rows.isEmpty {
                if searchText.isEmpty {
                    ContentUnavailableView("No Channels", systemImage: "dot.radiowaves.left.and.right",
                                           description: Text("Read from the scanner, paste channels, or show empty channels and type a frequency."))
                } else {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Name or frequency")
        .navigationTitle(title)
        .toolbar {
            ToolbarItem {
                Toggle("Show Empty Channels", systemImage: "eye", isOn: $showEmptyChannels)
                    .help(showEmptyChannels ? "Hide empty channels" : "Show empty channels")
            }
        }
    }

    // MARK: Rows

    private func makeRows() -> [ChannelRow] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let rows = numbers.compactMap { number -> ChannelRow? in
            let channel = config[channel: number]
            if channel.isEmpty, !showEmptyChannels { return nil }
            let row = ChannelRow(number: number, channel: channel, issues: issues.filter { $0.location == .channel(number) })
            if !query.isEmpty, !row.channel.name.lowercased().contains(query), !row.frequencyText.hasPrefix(query) { return nil }
            return row
        }
        return rows.sorted(using: sortOrder)
    }

    // MARK: Editing

    private func edit(_ number: Int, _ change: (inout Channel) -> Void) {
        config.editChannels([number], change)
    }

    private func channelBinding<Value>(_ number: Int, _ keyPath: WritableKeyPath<Channel, Value>) -> Binding<Value> {
        Binding(
            get: { config[channel: number][keyPath: keyPath] },
            set: { value in edit(number) { $0[keyPath: keyPath] = value } }
        )
    }

    /// Bulk edits for the selected (or right-clicked) channels; empty channels are skipped.
    @ViewBuilder
    private func bulkMenu(for numbers: Set<Int>) -> some View {
        let used = numbers.sorted().filter { !config[channel: $0].isEmpty }
        Button("Copy") { copyToPasteboard(numbers) }
        Button("Clear \(numbers.count == 1 ? "Channel" : "\(numbers.count) Channels")") { clear(numbers) }
        if !used.isEmpty {
            Divider()
            Menu("Modulation") {
                ForEach(Modulation.allCases, id: \.self) { modulation in
                    Button(modulation.displayName) { config.editChannels(used) { $0.modulation = modulation } }
                }
            }
            Menu("Tone") {
                ToneMenuItems { tone in config.editChannels(used) { $0.tone = tone } }
            }
            Menu("Delay") {
                ForEach(Delay.allCases, id: \.self) { delay in
                    Button(delay.displayName) { config.editChannels(used) { $0.delay = delay } }
                }
            }
            Divider()
            Button("Lock Out") { config.editChannels(used) { $0.lockedOut = true } }
            Button("Unlock") { config.editChannels(used) { $0.lockedOut = false } }
            if used.count == 1 {
                Button(config[channel: used[0]].priority ? "Remove Priority" : "Make Priority Channel") {
                    config.editChannels(used) { $0.priority.toggle() }
                }
            }
        }
    }

    private func clear(_ numbers: Set<Int>) {
        guard !numbers.isEmpty else { return }
        config.editChannels(numbers) { $0 = .empty }
    }

    // MARK: Pasteboard

    private func copyItems() -> [NSItemProvider] {
        let numbers = selection.sorted()
        guard !numbers.isEmpty else { return [] }
        return [NSItemProvider(object: ChannelClipboard.text(for: numbers.map { config[channel: $0] }) as NSString)]
    }

    private func copyToPasteboard(_ numbers: Set<Int>) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(ChannelClipboard.text(for: numbers.sorted().map { config[channel: $0] }), forType: .string)
    }

    /// Pastes into consecutive channels starting at the first selected one (or the first channel
    /// in view), stopping at channel 500.
    private func paste(_ providers: [NSItemProvider]) {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return }
        let start = selection.min() ?? numbers.first ?? 1
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            let text = (object as? NSString).map(String.init) ?? ""
            Task { @MainActor in
                guard let channels = ChannelClipboard.channels(from: text) else {
                    NSSound.beep()
                    return
                }
                let targets = Array(start..<min(start + channels.count, ScannerConfig.channelCount + 1))
                var updated = config
                for (number, channel) in zip(targets, channels) { updated[channel: number] = channel }
                config = updated
                selection = Set(targets)
                if targets.count < channels.count { NSSound.beep() }
            }
        }
    }
}
