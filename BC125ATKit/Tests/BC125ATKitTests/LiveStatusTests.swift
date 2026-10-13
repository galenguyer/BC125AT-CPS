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
