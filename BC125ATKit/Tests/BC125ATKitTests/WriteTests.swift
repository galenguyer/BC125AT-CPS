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

    /// On the Canada band plan the app can't predict snapping, so it writes frequencies as
    /// entered and reports what the scanner stored instead of calling it a failure.
    @Test func canadaPlanWritesAsEnteredAndReportsWhatWasStored() async throws {
        let mock = MockScanner() // snaps to its own plan, which the document doesn't know
        let session = ScannerSession(transport: mock)
        var document = ScannerConfig()
        document.settings.bandPlan = .canada
        document[channel: 1] = Channel(name: "Off plan", frequency: Frequency(parsing: "154.0062"), modulation: .nfm)
        document[channel: 2] = Channel(frequency: Frequency(parsing: "162.55"))

        let issues = document.validate()
        #expect(issues.contains { $0.location == .channel(1) && $0.severity == .warning && $0.message.contains("Canada") })
        #expect(!issues.contains { $0.message.contains("will be stored as") })

        let plan = WritePlan(from: ScannerConfig(), to: document)
        #expect(plan.adjustments.isEmpty)
        #expect(plan.target[channel: 1].frequency == Frequency(parsing: "154.0062"))

        let report = try await session.write(plan)
        #expect(report.succeeded)
        #expect(report.storedDifferently == [.init(title: "Channel 1", detail: "154.0062 MHz was stored as 154.0025 MHz")])
        #expect(report.acceptedConfig[channel: 1].frequency == Frequency(parsing: "154.0025"))
        #expect(report.acceptedConfig[channel: 1].name == "Off plan")
        #expect(report.acceptedConfig[channel: 2] == document[channel: 2])
    }

    /// A channel started from its name has no frequency yet: it's flagged, and not written.
    @Test func nameOnlyChannelIsWarnedAboutAndNotWritten() {
        var document = ScannerConfig()
        document[channel: 5].name = "Pending"
        #expect(document[channel: 5].isEmpty)
        #expect(document.validate().contains { $0.location == .channel(5) && $0.severity == .warning && $0.message.contains("no frequency") })
        #expect(WritePlan(from: ScannerConfig(), to: document).isEmpty)
    }

    @Test func rangesOnlyPlanKeepsInRangeFrequencies() {
        #expect(BandPlan.rangesOnly.storedValue(for: Frequency(parsing: "154.0062")!) == Frequency(parsing: "154.0062"))
        #expect(BandPlan.rangesOnly.storedValue(for: Frequency(parsing: "60")!) == nil)
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
        #expect(text.hasPrefix("Name\tFrequency\tModulation\tTone\tDelay\tLockout\tPriority\nAir Guard\t121.5000\tAM\tCSQ\t2\tNo\tNo\n"))
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

@Suite struct ChannelMoveTests {
    func numbered(_ count: Int) -> ScannerConfig {
        var config = ScannerConfig()
        for n in 1...count { config[channel: n] = Channel(name: "C\(n)", frequency: Frequency(hundredHz: UInt32(1_500_000 + n * 50))) }
        return config
    }

    func names(_ config: ScannerConfig, _ range: ClosedRange<Int>) -> [String] {
        range.map { config[channel: $0].isEmpty ? "-" : config[channel: $0].name }
    }

    @Test func movesDownAndSwapsDisplacedIntoTheGap() {
        var config = numbered(6)
        #expect(config.moveChannels([2, 3], to: 5) == [5, 6])
        #expect(names(config, 1...7) == ["C1", "C5", "C6", "C4", "C2", "C3", "-"])
    }

    @Test func overlappingMoveKeepsEveryChannel() {
        var config = numbered(5)
        config.moveChannels([1, 2], to: 2)
        #expect(names(config, 1...5) == ["C3", "C1", "C2", "C4", "C5"])
        #expect(Set(names(config, 1...5)) == Set((1...5).map { "C\($0)" }))
    }

    @Test func movingIntoEmptySlotsLeavesGaps() {
        var config = numbered(3)
        config.moveChannels([1], to: 10)
        #expect(names(config, 1...3) == ["-", "C2", "C3"])
        #expect(config[channel: 10].name == "C1")
    }

    @Test func clipsAtTheLastChannel() {
        var config = numbered(3)
        #expect(config.moveChannels([1, 2, 3], to: 499) == [499, 500])
        #expect(config[channel: 499].name == "C1" && config[channel: 500].name == "C2" && config[channel: 3].name == "C3")
    }

    @Test func intoBankUsesFirstEmptySlots() {
        var config = numbered(3)
        config[channel: 51] = Channel(name: "B2", frequency: Frequency(parsing: "160"))
        #expect(config.moveChannels([1, 3], intoBank: 2) == [52, 53])
        #expect(names(config, 1...3) == ["-", "C2", "-"])
        #expect(names(config, 51...53) == ["B2", "C1", "C3"])
    }

    @Test func intoFullBankChangesNothing() {
        var config = numbered(100)
        let before = config
        #expect(config.moveChannels([1], intoBank: 2) == nil)
        #expect(config == before)
    }
}
