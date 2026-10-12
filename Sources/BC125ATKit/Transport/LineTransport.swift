import Foundation

/// A byte pipe to the scanner that frames traffic as `\r`-terminated ASCII lines.
///
/// Implementations are synchronous and not thread-safe; callers serialize access
/// (the scanner only accepts one command at a time anyway).
public protocol LineTransport: AnyObject {
    /// Sends `line` followed by `\r`.
    func writeLine(_ line: String, timeout: Duration) throws(TransportError)

    /// Returns the next line received, without its `\r` terminator.
    func readLine(timeout: Duration) throws(TransportError) -> String

    /// Discards any bytes already received but not yet read.
    func drainInput()

    func close()
}

public enum TransportError: Error, Equatable, CustomStringConvertible {
    case deviceNotFound
    case openFailed(String)
    case timedOut
    case ioFailed(String)
    case closed

    public var description: String {
        switch self {
        case .deviceNotFound: "No BC125AT found on USB"
        case .openFailed(let reason): "Could not open scanner: \(reason)"
        case .timedOut: "Timed out waiting for the scanner"
        case .ioFailed(let reason): "USB I/O failed: \(reason)"
        case .closed: "Connection is closed"
        }
    }
}

/// Accumulates received bytes and splits them into `\r`-terminated lines.
struct LineBuffer {
    private var pending: [UInt8] = []

    mutating func append(_ bytes: some Sequence<UInt8>) {
        pending.append(contentsOf: bytes)
    }

    /// Removes and returns the first complete line, if any.
    mutating func nextLine() -> String? {
        guard let end = pending.firstIndex(of: 0x0D) else { return nil }
        let line = String(decoding: pending[..<end], as: UTF8.self)
        pending.removeSubrange(...end)
        return line
    }

    mutating func removeAll() {
        pending.removeAll()
    }
}
