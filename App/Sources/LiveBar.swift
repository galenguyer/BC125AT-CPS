import BC125ATKit
import SwiftUI

/// The strip along the bottom of the window: what the scanner is receiving, the last
/// transmission heard, and its volume and squelch (SPEC.md §8.6).
struct LiveBar: View {
    /// Also the height of the sidebar's update note, so the two line up.
    static let height: CGFloat = 34

    var live: LiveMonitor

    var body: some View {
        HStack(spacing: 12) {
            nowPlaying
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
            // Shown only when it fits whole; a cut-down "Last: ROC… 1 min…" helps no one.
            ViewThatFits(in: .horizontal) {
                lastHeard
                Color.clear.frame(width: 0, height: 0)
            }
            Divider().frame(height: 16)
            scanControls
            Divider().frame(height: 16)
            levels
            Button(live.enabled ? "Pause Live View" : "Resume Live View",
                   systemImage: live.enabled ? "pause.circle" : "play.circle") { live.enabled.toggle() }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(live.enabled ? "Stop watching the scanner (frees it for other programs)" : "Watch what the scanner is receiving")
        }
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: Now playing

    @ViewBuilder
    private var nowPlaying: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            switch live.state {
            case .live:
                if let status = live.status, live.settled {
                    channel(status, emphasised: true)
                } else {
                    Text("Scanning…").foregroundStyle(.secondary)
                }
            case .connecting: Text("Connecting…").foregroundStyle(.secondary)
            case .noScanner: Text("No scanner connected").foregroundStyle(.secondary)
            case .off: Text("Live view off").foregroundStyle(.secondary)
            case .paused(let reason): Text(reason).foregroundStyle(.secondary)
            case .unavailable(let message): Text(message).foregroundStyle(.orange)
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    private var indicatorColor: Color {
        guard live.state == .live, let status = live.status else { return .secondary.opacity(0.4) }
        if status.receiving { return .green }
        return live.settled ? .accentColor : .secondary
    }

    /// `CH 312  TALKAROUND  462.5625 MHz  NFM  CTCSS 123.0`
    private func channel(_ status: LiveStatus, emphasised: Bool) -> some View {
        HStack(spacing: 6) {
            // When space is short, only the name is cut; the numbers stay whole.
            if let number = status.channel {
                Text("CH \(number)").monospacedDigit().foregroundStyle(.secondary).fixedSize()
            }
            if !status.name.isEmpty {
                Text(status.name).fontWeight(emphasised ? .semibold : .regular)
            }
            if let frequency = status.frequency {
                Text("\(frequency.megahertzString) MHz").monospacedDigit().fixedSize()
            }
            if let modulation = status.modulation {
                Text(modulation.displayName).foregroundStyle(.secondary).fixedSize()
            }
            if let tone = status.tone, tone != .none {
                Text(tone.displayName).foregroundStyle(.secondary).fixedSize()
            }
        }
    }

    @ViewBuilder
    private var lastHeard: some View {
        // Shown when something was heard and the scanner has moved on from it.
        if let heard = live.lastHeard, live.state == .live, live.status?.receiving != true {
            HStack(spacing: 4) {
                Text("Last:").foregroundStyle(.secondary)
                Text(heard.status.name.isEmpty ? heard.status.frequency.map { "\($0.megahertzString) MHz" } ?? "" : heard.status.name)
                (Text(heard.at, style: .relative) + Text(" ago")).foregroundStyle(.secondary).monospacedDigit()
            }
            .lineLimit(1)
            .fixedSize()
            .help(heard.status.frequency.map { "\($0.megahertzString) MHz" } ?? "")
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: Scan and Hold

    /// Scan resumes scanning; Hold stops on the channel shown (SPEC.md §3.8). Hold goes through
    /// `hold(on:)` rather than the scanner's Hold key, which is a toggle.
    private var scanControls: some View {
        HStack(spacing: 2) {
            Button("Scan", systemImage: "play.fill") { live.scan() }
                .help("Resume scanning, as the scanner's Scan key does")
            Button("Hold", systemImage: "pause.fill") {
                if let channel = live.status?.channel { live.hold(on: channel) }
            }
            .help("Stop on the channel shown")
            .disabled(live.status?.channel == nil)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .disabled(!live.canControl)
    }

    // MARK: Volume and squelch

    private var levels: some View {
        HStack(spacing: 14) {
            level("Volume", systemImage: "speaker.wave.2", value: live.volume, set: live.setVolume)
            level("Squelch", systemImage: "waveform.path", value: live.squelch, set: live.setSquelch)
        }
        .disabled(live.state != .live)
    }

    private func level(_ title: String, systemImage: String, value: Int?, set: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .help(title)
                .accessibilityHidden(true)
            Slider(value: Binding(get: { Double(value ?? 0) }, set: { set(Int($0.rounded())) }),
                   in: Double(SystemSettings.levelRange.lowerBound)...Double(SystemSettings.levelRange.upperBound), step: 1)
                .frame(width: 100)
                .controlSize(.small)
                .accessibilityLabel(title)
                .accessibilityValue(value.map(String.init) ?? "unknown")
            Text(value.map(String.init) ?? "–")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .trailing)
        }
    }
}
