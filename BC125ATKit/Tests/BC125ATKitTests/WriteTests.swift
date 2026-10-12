@testable import BC125ATKit
import Foundation
import Testing

@Suite struct WritePlanTests {
    @Test func identicalConfigsNeedNothing() {
        let config = sampleConfig()
        #expect(WritePlan(from: config, to: config).isEmpty)
    }

    @Test func appOnlyFieldsAreIgnored() {
        var document = sampleConfig()
        document.bankNames[3] = "Fire"
        document.metadata.notes = "notes"
        #expect(WritePlan(from: sampleConfig(), to: document).isEmpty)
    }

    @Test func offPlanValuesThatTheScannerAlreadyHoldsAreNotChanges() {
        var scanner = ScannerConfig()
        scanner[channel: 1] = Channel(name: "X", frequency: Frequency(parsing: "162.5475"))
        var document = scanner
        document[channel: 1].frequency = Frequency(parsing: "162.5510")
        document[channel: 1].name = "X  "
        let plan = WritePlan(from: scanner, to: document)
        #expect(plan.isEmpty)
        #expect(plan.adjustments.map(\.detail) == ["162.5510 MHz will be stored as 162.5475 MHz", #"Name "X  " will be stored as "X""#])
    }

    @Test func stepsAndCommands() {
        let scanner = ScannerConfig()
        var document = scanner
        document.settings.backlight = .alwaysOn
        document.settings.keyLock = true
        document.bankScanEnabled[0] = false
        document.search.customRanges[2].lower = Frequency(parsing: "30")!
        document.closeCall.mode = .priority
        document[channel: 3] = Channel(name: "", frequency: Frequency(parsing: "162.55"), modulation: .fm)
        document.globalLockouts = [Frequency(parsing: "460.025")!]
        let plan = WritePlan(from: scanner, to: document)
        #expect(plan.steps.map(\.command) == [
            "BLT,AO", "KBP,0,1", "SCG,1000000000", "CSP,3,00300000,00499950", "CLC,1,1,1,11111,0",
            "CIN,3, ,01625500,FM,0,2,0,0", "LOF,04600250",
        ])
        #expect(plan.steps(in: .channels).first?.detail == "162.5500 MHz FM")
    }

    @Test func clearingAChannelUsesDCH() {
        let scanner = sampleConfig()
        var document = scanner
        document[channel: 75] = Channel(frequency: nil)
        let plan = WritePlan(from: scanner, to: document)
        #expect(plan.steps.map(\.command) == ["DCH,75"])
        #expect(plan.steps[0].detail.hasPrefix("Clear (was 462.5625 MHz NFM"))
    }

    @Test func priorityChannelsAreWrittenLast() {
        var scanner = ScannerConfig()
        scanner[channel: 1] = Channel(frequency: Frequency(parsing: "150"), priority: true)
        var document = scanner
        document[channel: 1].priority = false
        document[channel: 2] = Channel(frequency: Frequency(parsing: "151"), priority: true)
        document[channel: 3] = Channel(frequency: Frequency(parsing: "152"))
        #expect(WritePlan(from: scanner, to: document).steps.map(\.title) == ["Channel 1", "Channel 3", "Channel 2"])
    }

    @Test func lockoutRemovalsComeFirst() {
        var scanner = ScannerConfig()
        scanner.globalLockouts = [Frequency(parsing: "155")!]
        var document = scanner
        document.globalLockouts = [Frequency(parsing: "156")!]
        #expect(WritePlan(from: scanner, to: document).steps.map(\.command) == ["ULF,01550000", "LOF,01560000"])
    }
}

@Suite struct ScannerWriteTests {
    @Test func writesAndVerifies() async throws {
        let mock = MockScanner()
        let session = ScannerSession(transport: mock)
        var document = sampleConfig()
        document[channel: 3] = Channel(name: "Off plan", frequency: Frequency(parsing: "162.551"), modulation: .fm)
        let plan = WritePlan(from: try await session.readConfiguration(), to: document)
        let report = try await session.write(plan)

        #expect(report.succeeded)
        #expect(report.written == plan.steps.count)
        #expect(report.scannerConfig[channel: 3].frequency == Frequency(parsing: "162.5475"))
        #expect(WritePlan(from: mock.config, to: document).isEmpty)
        #expect(!mock.inProgramMode)
        #expect(mock.received.last == "EPG")
    }

    @Test func movingPriorityWithinABankSticks() async throws {
        var scanner = ScannerConfig()
        scanner[channel: 1] = Channel(frequency: Frequency(parsing: "150"), priority: true)
        let mock = MockScanner(config: scanner)
        let session = ScannerSession(transport: mock)
        var document = scanner
        document[channel: 1].priority = false
        document[channel: 2] = Channel(frequency: Frequency(parsing: "151"), priority: true)
        let report = try await session.write(WritePlan(from: scanner, to: document))
        #expect(report.succeeded)
        #expect(mock.config[channel: 2].priority && !mock.config[channel: 1].priority)
    }

    @Test func rejectedStepsAreReportedAndTheRestStillWritten() async throws {
        let mock = MockScanner()
        let session = ScannerSession(transport: mock)
        var document = ScannerConfig()
        document[channel: 1] = Channel(frequency: Frequency(parsing: "60")) // outside the bands: CIN,ERR
        document[channel: 2] = Channel(frequency: Frequency(parsing: "162.55"))
        let report = try await session.write(WritePlan(from: ScannerConfig(), to: document))
        #expect(report.failures.map(\.step.title) == ["Channel 1"])
        #expect(report.mismatches.map(\.title) == ["Channel 1"])
        #expect(report.written == 1)
        #expect(mock.config[channel: 2].frequency == Frequency(parsing: "162.55"))
    }

    @Test func timeoutStopsTheWriteButLeavesProgramMode() async {
        let mock = MockScanner()
        mock.unresponsiveCommands = ["BLT"]
        let session = ScannerSession(transport: mock)
        var document = ScannerConfig()
        document.settings.backlight = .alwaysOn
        await #expect(throws: ScannerError.transport(.timedOut)) {
            try await session.write(WritePlan(from: ScannerConfig(), to: document))
        }
        #expect(!mock.inProgramMode)
    }
}

@Suite struct ChannelClipboardTests {
    @Test func roundTrips() throws {
        let config = sampleConfig()
        let channels = [config[channel: 1], config[channel: 2], .empty, config[channel: 75]]
        let text = ChannelClipboard.text(for: channels)
        #expect(text.hasPrefix("Name\tFrequency\tModulation\tTone\tDelay\tLockout\tPriority\nAir Guard\t121.5000\tAM\tNone\t2\tNo\tNo\n"))
        #expect(ChannelClipboard.channels(from: text) == channels)
    }

    @Test func pastesFromSpreadsheetsWithoutHeaders() {
        let pasted = ChannelClipboard.channels(from: "Tower\t118.3\tAM\n\tnot a frequency\n")
        #expect(pasted == nil)
        let ok = ChannelClipboard.channels(from: "Tower\t118.3\tAM\nGround\t121.9\tAM\n")
        #expect(ok?.map(\.name) == ["Tower", "Ground"])
        #expect(ok?.allSatisfy { !$0.lockedOut } == true)
    }

    @Test func pastesAColumnOfFrequencies() {
        let pasted = ChannelClipboard.channels(from: "162.4\n162.425\n162.45\n")
        #expect(pasted?.compactMap(\.frequency).map(\.megahertzString) == ["162.4000", "162.4250", "162.4500"])
    }
}
