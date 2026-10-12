import Foundation

public enum ScannerError: Error, Equatable, CustomStringConvertible {
    case transport(TransportError)
    /// `ERR`: command format or value error.
    case rejected(command: String)
    /// `NG`: command valid but not allowed now (e.g. outside program mode, or scanner in a menu).
    case notAllowed(command: String)
    case unexpectedResponse(command: String, response: String)

    public var description: String {
        switch self {
        case .transport(let error): error.description
        case .rejected(let command): "Scanner rejected \(command) (ERR)"
        case .notAllowed(let command): "Scanner refused \(command) right now (NG)"
        case .unexpectedResponse(let command, let response): "Unexpected reply to \(command): \(response.debugDescription)"
        }
    }
}

/// Sends commands one at a time and interprets the replies (SPEC.md §3).
public final class ScannerConnection {
    public let transport: any LineTransport
    public var defaultTimeout: Duration = .seconds(1)
    /// Called with every line sent and the reply received (or `nil` on failure). For logs and transcripts.
    public var onExchange: ((_ sent: String, _ reply: String?) -> Void)?

    public init(transport: any LineTransport) {
        self.transport = transport
        transport.drainInput()
    }

    /// Sends `line` and returns the raw reply, without interpreting it.
    public func send(_ line: String, timeout: Duration? = nil) throws(ScannerError) -> String {
        do {
            try transport.writeLine(line, timeout: timeout ?? defaultTimeout)
            let reply = try transport.readLine(timeout: timeout ?? defaultTimeout)
            onExchange?(line, reply)
            return reply
        } catch {
            onExchange?(line, nil)
            // A reply that arrives late would be read as the answer to the next command.
            transport.drainInput()
            throw .transport(error)
        }
    }

    /// Sends a command and returns the reply's fields after the command name.
    ///
    /// `BLT` → `["AO", ""]`; `CIN,1` → `["1", "NAME", "1625500", …]`; a set command → `["OK"]`.
    @discardableResult
    public func execute(_ line: String, timeout: Duration? = nil) throws(ScannerError) -> [String] {
        let command = String(line.prefix { $0 != "," })
        let reply = try send(line, timeout: timeout)
        return try Self.parse(reply: reply, command: command)
    }

    static func parse(reply: String, command: String) throws(ScannerError) -> [String] {
        var fields = reply.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        // Errors arrive bare ("ERR") or prefixed ("PRG,NG").
        switch fields.last {
        case "ERR" where fields.count <= 2: throw .rejected(command: command)
        case "NG" where fields.count <= 2: throw .notAllowed(command: command)
        default: break
        }
        guard fields.first == command, fields.count >= 2 else {
            throw .unexpectedResponse(command: command, response: reply)
        }
        fields.removeFirst()
        return fields
    }

    public func enterProgramMode() throws(ScannerError) {
        try expectOK("PRG")
    }

    public func exitProgramMode() throws(ScannerError) {
        try expectOK("EPG")
    }

    /// Runs `body` in program mode, always sending `EPG` afterwards — even if `body` throws.
    public func inProgramMode<T>(_ body: () throws -> T) throws -> T {
        try enterProgramMode()
        defer { try? exitProgramMode() }
        return try body()
    }

    private func expectOK(_ command: String) throws(ScannerError) {
        let fields = try execute(command)
        guard fields == ["OK"] else {
            throw .unexpectedResponse(command: command, response: ([command] + fields).joined(separator: ","))
        }
    }
}
