@testable import BC125ATKit
import Foundation
import Testing

/// `GLG` replies as a real BC125AT gave them (made-up names and channels).
@Suite struct LiveStatusTests {
    @Test func parsesAReceivingChannel() {
        let status = LiveStatus(glg: "04625625,NFM,,82,,,TALKAROUND,1,0,,312,".components(separatedBy: ","))
        #expect(status.frequency == Frequency(parsing: "462.5625"))
        #expect(status.modulation == .nfm)
        #expect(status.tone == ToneCode(code: 82))
        #expect(status.name == "TALKAROUND")
        #expect(status.channel == 312)
        #expect(status.receiving)
        #expect(!status.muted)
    }

    @Test func parsesScanningAndEmptyReplies() {
        let scanning = LiveStatus(glg: "01215000,AM,,0,,,GUARD,0,1,,1,".components(separatedBy: ","))
        #expect(scanning.tone == ToneCode.none)
        #expect(!scanning.receiving && scanning.muted)
        #expect(scanning.channel == 1)

        let empty = LiveStatus(glg: Array(repeating: "", count: 12))
        #expect(empty == LiveStatus())
        #expect(LiveStatus(glg: []) == LiveStatus())
    }

    /// Recorded 2026-10-15 from a BC125AT held on channel 13 with priority on: one poll in a while
    /// lands on the priority check and reports channel 1's frequency (121.5000) under channel 13.
    @Test func recognisesAPriorityCheckDuringHold() {
        let held = LiveStatus(glg: "01187000,AM,,0,,,YYZ TWR N,0,1,,13,".components(separatedBy: ","))
        let sample = LiveStatus(glg: "01215000,AM,,0,,,YYZ TWR N,0,1,,13,".components(separatedBy: ","))
        #expect(sample.looksLikePriorityCheck(after: held))
        #expect(!held.looksLikePriorityCheck(after: held), "the same reply again isn't a change")
        #expect(!held.looksLikePriorityCheck(after: nil))

        // Moving to another channel, as while scanning, is movement.
        let next = LiveStatus(glg: "01206250,AM,,0,,,ZOB38 IAG-SH,0,1,,110,".components(separatedBy: ","))
        #expect(!next.looksLikePriorityCheck(after: held))
        // A signal on the new frequency is a priority hit, and is shown.
        let hit = LiveStatus(glg: "01215000,AM,,0,,,GUARD,1,0,,13,".components(separatedBy: ","))
        #expect(!hit.looksLikePriorityCheck(after: held))
        // Searches and Close Call have no channel number; there, a frequency change is movement.
        let search = LiveStatus(glg: "01550000,NFM,,0,,,,0,1,,,".components(separatedBy: ","))
        let searchNext = LiveStatus(glg: "01550050,NFM,,0,,,,0,1,,,".components(separatedBy: ","))
        #expect(!searchNext.looksLikePriorityCheck(after: search))
    }

    @Test func sessionReadsStatusAndSetsLevels() async throws {
        var config = ScannerConfig()
        config.settings.volume = 3
        config.settings.squelch = 2
        let mock = MockScanner(config: config)
        mock.glgFields = "01625500,FM,,0,,,WX,1,0,,7,".components(separatedBy: ",")
        let session = ScannerSession(transport: mock)

        #expect(try await session.liveStatus().channel == 7)
        #expect(try await session.levels() == (3, 2))
        try await session.setVolume(9)
        try await session.setSquelch(20) // clamped to 15
        #expect(try await session.levels() == (9, 15))
        #expect(!mock.received.contains("PRG"), "live commands don't enter program mode")
    }
}
