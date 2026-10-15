@testable import BC125ATKit
import Testing

/// Detecting scanning or hold, and putting the scanner back afterwards (SPEC.md §3.8).
@Suite struct ScanModeTests {
    private func scanner(_ mode: ScanMode) -> MockScanner {
        let mock = MockScanner(config: sampleConfig())
        mock.scanMode = mode
        return mock
    }

    @Test func detectsScanning() async throws {
        let session = ScannerSession(transport: scanner(.scanning))
        #expect(try await session.scanMode() == .scanning)
    }

    @Test func detectsHold() async throws {
        let session = ScannerSession(transport: scanner(.hold(channel: 75)))
        #expect(try await session.scanMode() == .hold(channel: 75))
    }

    /// Searching, menus and the like report no channel, and aren't restored.
    @Test func noChannelIsUnknown() async throws {
        let session = ScannerSession(transport: MockScanner())
        #expect(try await session.scanMode() == nil)
    }

    @Test func holdsOnAChannelFromScanningWithoutTogglingBanks() async throws {
        let mock = scanner(.scanning)
        let banks = mock.config.bankScanEnabled
        #expect(try await ScannerSession(transport: mock).hold(on: 500))
        #expect(mock.scanMode == .hold(channel: 500))
        #expect(mock.config.bankScanEnabled == banks)
        #expect(mock.received.filter { $0.hasPrefix("KEY") } == ["KEY,S,P", "KEY,H,P", "KEY,5,P", "KEY,0,P", "KEY,0,P", "KEY,H,P"])
    }

    @Test func holdsOnAChannelFromHoldOnAnother() async throws {
        let mock = scanner(.hold(channel: 1))
        #expect(try await ScannerSession(transport: mock).hold(on: 75))
        #expect(mock.scanMode == .hold(channel: 75))
    }

    @Test func holdingOnAnEmptyChannelReportsFailure() async throws {
        let mock = scanner(.scanning)
        #expect(try await ScannerSession(transport: mock).hold(on: 3) == false)
    }

    /// Program mode leaves the scanner held on channel 1; restoring puts it back.
    @Test func restoresAfterReading() async throws {
        for mode in [ScanMode.scanning, .hold(channel: 75)] {
            let mock = scanner(mode)
            let session = ScannerSession(transport: mock)
            let before = try await session.scanMode()
            _ = try await session.readConfiguration()
            #expect(mock.scanMode == .hold(channel: 1))
            #expect(try await session.restore(try #require(before)))
            #expect(mock.scanMode == mode)
        }
    }
}
