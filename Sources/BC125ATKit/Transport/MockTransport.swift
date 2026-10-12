import Foundation

/// A fake scanner for tests. `respond` maps each command line to the line the scanner sends back.
public final class MockTransport: LineTransport {
    public private(set) var sent: [String] = []
    private var replies: [String] = []
    private let respond: (String) -> String?

    public init(respond: @escaping (String) -> String?) {
        self.respond = respond
    }

    public func writeLine(_ line: String, timeout: Duration) throws(TransportError) {
        sent.append(line)
        if let reply = respond(line) { replies.append(reply) }
    }

    public func readLine(timeout: Duration) throws(TransportError) -> String {
        guard !replies.isEmpty else { throw .timedOut }
        return replies.removeFirst()
    }

    public func drainInput() {
        replies.removeAll()
    }

    public func close() {}
}
