@testable import BC125ATKit
import Testing

@Suite struct LineBufferTests {
    @Test func splitsLinesAcrossPackets() {
        var buffer = LineBuffer()
        buffer.append(Array("VER,Vers".utf8))
        #expect(buffer.nextLine() == nil)
        buffer.append(Array("ion 1.06.06\rMDL,BC1".utf8))
        #expect(buffer.nextLine() == "VER,Version 1.06.06")
        #expect(buffer.nextLine() == nil)
        buffer.append(Array("25AT\r".utf8))
        #expect(buffer.nextLine() == "MDL,BC125AT")
    }

    @Test func emptyLine() {
        var buffer = LineBuffer()
        buffer.append([0x0D])
        #expect(buffer.nextLine() == "")
    }
}

@Suite struct ReplyParsingTests {
    @Test func stripsCommandName() throws {
        #expect(try ScannerConnection.parse(reply: "MDL,BC125AT", command: "MDL") == ["BC125AT"])
        #expect(try ScannerConnection.parse(reply: "CIN,OK", command: "CIN") == ["OK"])
    }

    @Test func keepsTrailingEmptyField() throws {
        #expect(try ScannerConnection.parse(reply: "BLT,AO,", command: "BLT") == ["AO", ""])
        #expect(try ScannerConnection.parse(reply: "CSP,1,250000,279950,", command: "CSP") == ["1", "250000", "279950", ""])
    }

    @Test func errorsBareAndPrefixed() {
        #expect(throws: ScannerError.rejected(command: "ZZZ")) { try ScannerConnection.parse(reply: "ERR", command: "ZZZ") }
        #expect(throws: ScannerError.notAllowed(command: "BLT")) { try ScannerConnection.parse(reply: "NG", command: "BLT") }
        #expect(throws: ScannerError.notAllowed(command: "PRG")) { try ScannerConnection.parse(reply: "PRG,NG", command: "PRG") }
    }

    @Test func channelNamedERRIsNotAnError() throws {
        let fields = try ScannerConnection.parse(reply: "CIN,1,ERR,1625500,FM,0,2,0,0", command: "CIN")
        #expect(fields[1] == "ERR")
    }

    @Test func mismatchedCommand() {
        #expect(throws: ScannerError.unexpectedResponse(command: "VER", response: "MDL,BC125AT")) {
            try ScannerConnection.parse(reply: "MDL,BC125AT", command: "VER")
        }
    }
}

@Suite struct ProgramModeTests {
    @Test func alwaysExitsProgramMode() {
        let mock = MockTransport { line in
            switch line {
            case "PRG": "PRG,OK"
            case "EPG": "EPG,OK"
            default: "ERR"
            }
        }
        let connection = ScannerConnection(transport: mock)
        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try connection.inProgramMode { throw Boom() }
        }
        #expect(mock.sent == ["PRG", "EPG"])
    }

    @Test func timeoutIsTransportError() {
        let connection = ScannerConnection(transport: MockTransport { _ in nil })
        #expect(throws: ScannerError.transport(.timedOut)) { try connection.execute("MDL") }
    }
}
