@testable import BC125ATKit
import Testing

@Suite struct RadioReferenceTests {
    static let export = """
    "Frequency Output","Frequency Input","FCC Callsign",Agency/Category,Description,"Alpha Tag","PL Output Tone","PL Input Tone",Mode,"Class Station Code",Tag
    118.30000,0.00000,,,Tower,"ROC Tower",,,AM,BM,Aircraft
    37.900000,39.90000,KEH763,Webster,"Highway Department","Webster Highway","151.4 PL",,FM,RM,"Public Works"
    155.71500,0.00000,KNGA965,,"Fire-Rescue Dispatch/Operations","ROC ARFF","155 DPL",,FMN,BM,"Fire Dispatch"
    173.33750,0.00000,WNYD449,,"SCAN Runway Reporting System","SCAN Rnwy",,,Telm,F,Data
    460.70000,465.70000,KXA741,,"American Airlines",American,"CC 1|TG 1001|SL 1",,DMR,RM,Business
    453.10000,0.00000,,,"County, Fire","",,,"Project 25",BM,"Fire Dispatch"
    851.01250,0.00000,,,Trunk,"Trunk CC",,,FMN,RM,Interop
    461.11250,0.00000,KB74329,,"Fedex - Ramp","Fedex Ramp Operations 2","293 NAC",,FMN,M,Business
    466.03750,0.00000,,,"LTR site",LTR,,,LTR,RM,Business

    """

    @Test func readsUsableRows() throws {
        let entries = try RadioReferenceFormat.entries(from: Self.export)
        #expect(entries.count == 9)
        let usable = entries.filter(\.isUsable)
        #expect(usable.map(\.line) == [2, 3, 4, 9])

        #expect(usable[0].channel == Channel(name: "ROC Tower", frequency: Frequency(parsing: "118.3"), modulation: .am))
        #expect(usable[1].channel?.modulation == .fm)
        #expect(usable[1].channel?.tone == ToneCode(parsing: "151.4"))
        #expect(usable[1].channel?.name == "Webster Highway")
        #expect(usable[2].channel?.modulation == .nfm)
        #expect(usable[2].channel?.tone == ToneCode(parsing: "D155"))
        #expect(usable[2].channel?.lockedOut == false)
        // Truncated to 16 characters, and a NAC is digital, so the channel is left open.
        #expect(usable[3].channel?.name == "Fedex Ramp Opera")
        #expect(usable[3].channel?.tone == ToneCode.none)
        #expect(usable[3].note != nil)
    }

    @Test func explainsSkippedRows() throws {
        let skipped = Dictionary(uniqueKeysWithValues: try RadioReferenceFormat.entries(from: Self.export)
            .filter { !$0.isUsable }.map { ($0.line, $0.skipReason ?? "") })
        #expect(skipped[5] == "Telm is data, not voice")
        #expect(skipped[6] == "DMR is digital")
        #expect(skipped[7] == "Project 25 is digital")
        #expect(skipped[8] == "851.0125 MHz is outside the scanner's bands")
        #expect(skipped[10] == "LTR is a trunked system")
    }

    @Test func namesFallBackToTheDescription() {
        #expect(RadioReferenceFormat.name(alphaTag: "", description: "County, Fire") == "County  Fire")
        #expect(RadioReferenceFormat.name(alphaTag: "Café Ops", description: "") == "Caf Ops")
        #expect(RadioReferenceFormat.name(alphaTag: "Fifteen chars + space", description: "") == "Fifteen chars +")
    }

    @Test func readsTones() {
        #expect(RadioReferenceFormat.tone(from: "110.9 PL") == ToneCode(parsing: "110.9"))
        #expect(RadioReferenceFormat.tone(from: "023 DPL") == .dcs(index: 0))
        #expect(RadioReferenceFormat.tone(from: "CSQ") == ToneCode.none)
        #expect(RadioReferenceFormat.tone(from: "293 NAC") == nil)
        #expect(RadioReferenceFormat.tone(from: "RAN 1") == nil)
    }

    @Test func rejectsOtherFiles() {
        #expect(throws: RadioReferenceFormat.ImportError.missingColumns(["Mode"])) {
            try RadioReferenceFormat.entries(from: CSVFormat.export(sampleConfig()).replacingOccurrences(of: "Modulation", with: "X"))
        }
        #expect(throws: RadioReferenceFormat.ImportError.empty) { try RadioReferenceFormat.entries(from: "") }
    }

    @Test func leavesDuplicatesUnselected() throws {
        let entries = try RadioReferenceFormat.entries(from: Self.export + "118.30000,0.00000,,,Tower again,\"ROC Tower\",,,AM,BM,Aircraft\n")
        var config = ScannerConfig()
        // Same name and frequency as line 3, so it's left out; same frequency as line 2 with
        // another name, so that one stays selected.
        config[channel: 7] = Channel(name: "Webster Highway", frequency: Frequency(parsing: "37.9"), modulation: .fm)
        config[channel: 8] = Channel(name: "Tower", frequency: Frequency(parsing: "118.3"), modulation: .am)
        // Line 11 repeats line 2 within the file.
        #expect(RadioReferenceFormat.defaultSelection(entries, in: config) == [2, 4, 9])
        #expect(RadioReferenceFormat.defaultSelection(entries, in: ScannerConfig()) == [2, 3, 4, 9])
    }

    @Test func findsRoomForChannels() {
        var config = ScannerConfig()
        config[channel: 3] = Channel(frequency: Frequency(parsing: "121.5"))
        config[channel: 49] = Channel(frequency: Frequency(parsing: "121.5"))
        #expect(config.emptyRun(from: 1) == 2)
        #expect(config.emptyRun(from: 3) == 0)
        #expect(config.emptyRun(from: 4) == 45)
        #expect(config.emptyRun(from: 500) == 1)
        #expect(config.firstEmptyRun(ofLength: 2) == 1)
        #expect(config.firstEmptyRun(ofLength: 10) == 4)
        // 46 won't fit in bank 1, so prefer the start of bank 2 over crossing from 50.
        #expect(config.firstEmptyRun(ofLength: 46) == 51)
        #expect(config.firstEmptyRun(ofLength: 451) == 50)
        #expect(config.firstEmptyRun(ofLength: 452) == nil)
        #expect(ScannerConfig.crossesBanks(start: 45, count: 7))
        #expect(!ScannerConfig.crossesBanks(start: 41, count: 10))
    }

    @Test func insertsOnlyIntoEmptyChannels() {
        var config = ScannerConfig()
        config[channel: 5] = Channel(frequency: Frequency(parsing: "121.5"))
        let new = [Channel(name: "A", frequency: Frequency(parsing: "118.3")), Channel(name: "B", frequency: Frequency(parsing: "118.8"))]
        let before = config
        let overlapping = config.insert(new, at: 4)
        #expect(!overlapping)
        #expect(config == before)
        let fitting = config.insert(new, at: 2)
        #expect(fitting)
        #expect(config[channel: 2].name == "A")
        #expect(config[channel: 3].name == "B")
        let pastTheEnd = config.insert(new, at: 500)
        #expect(!pastTheEnd)
    }
}
