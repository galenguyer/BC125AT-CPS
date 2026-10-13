import AppKit
import BC125ATKit
import SwiftUI

/// A text field that edits a local copy and commits it on Return or when focus leaves, so a
/// change is one undo step rather than one per keystroke. `commit` returns false to reject the
/// text, which beeps and restores the current value.
struct CommitTextField: View {
    var title: String
    var value: String
    var commit: (String) -> Bool

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $text, prompt: Text(title))
            .focused($focused)
            .onSubmit(apply)
            .onChange(of: focused) { _, isFocused in if !isFocused { apply() } }
            .onAppear { text = value }
            // Show the committed value as stored (e.g. "151.82" becomes "151.8200"), and pick up
            // outside changes such as undo.
            .onChange(of: value) { _, newValue in text = newValue }
            .onExitCommand { text = value; focused = false }
    }

    private func apply() {
        guard text != value else { return }
        if !commit(text) {
            NSSound.beep()
            text = value
        }
    }
}

/// Edits a frequency in MHz. Accepts anything `Frequency(parsing:)` does; clearing the field is
/// allowed only when `allowsEmpty`.
struct FrequencyField: View {
    var title = "MHz"
    var frequency: Frequency?
    var allowsEmpty = false
    var set: (Frequency?) -> Void

    var body: some View {
        CommitTextField(title: title, value: frequency?.megahertzString ?? "") { text in
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                guard allowsEmpty else { return false }
                set(nil)
                return true
            }
            guard let parsed = Frequency(parsing: trimmed) else { return false }
            set(parsed)
            return true
        }
        .monospacedDigit()
    }
}

/// None / Search / No Tone, then CTCSS and DCS submenus.
struct ToneMenuItems: View {
    var select: (ToneCode) -> Void

    var body: some View {
        Button(ToneCode.none.displayName) { select(.none) }
        Button("Search") { select(.search) }
        Button("No Tone") { select(.noTone) }
        Menu("CTCSS") {
            ForEach(ToneCode.ctcssTenthsHz.indices, id: \.self) { index in
                Button(ToneCode.ctcss(index: index).displayName) { select(.ctcss(index: index)) }
            }
        }
        Menu("DCS") {
            ForEach(ToneCode.dcsCodes.indices, id: \.self) { index in
                Button(ToneCode.dcs(index: index).displayName) { select(.dcs(index: index)) }
            }
        }
    }
}

extension ScannerConfig {
    /// Applies `edit` to each channel in `numbers`, then mirrors the scanner's rule that a bank
    /// has one priority channel: if an edit turned priority on, the bank's others are cleared.
    mutating func editChannels(_ numbers: some Sequence<Int>, _ edit: (inout Channel) -> Void) {
        for number in numbers {
            let wasPriority = self[channel: number].priority
            var channel = self[channel: number]
            edit(&channel)
            self[channel: number] = channel
            if channel.priority, !wasPriority {
                for other in Channel.channels(inBank: Channel.bank(ofChannel: number)) where other != number {
                    self[channel: other].priority = false
                }
            }
        }
    }

    /// Sets a channel's frequency. Giving an empty channel a frequency makes it a new, active
    /// channel (empty channels are locked out on the scanner); clearing it empties the channel.
    mutating func setFrequency(_ frequency: Frequency?, ofChannel number: Int) {
        if frequency == nil {
            self[channel: number] = .empty
        } else if self[channel: number].isEmpty {
            self[channel: number] = Channel(frequency: frequency)
        } else {
            self[channel: number].frequency = frequency
        }
    }
}
