import BC125ATKit
import Dispatch
import Foundation
import Synchronization

let usage = """
    usage: bc125at-cli <command> [options]

    commands:
      list                     List connected scanners
      info                     Show model and firmware version
      raw [--prg] <cmd>...     Send raw commands and print the replies (--prg wraps them in PRG/EPG)
      dump                     Read every setting and channel (read-only) and print the raw replies
      read <file.bc125at>      Read the whole configuration with ScannerSession (as the app does)
                               and save it as a .bc125at document
      verify [--allow-write]   Run the Phase 0 protocol checks (SPEC.md §10) and print a report.
                               --allow-write also runs round-trip tests that modify, then restore,
                               spare empty channels and a few settings.
      release                  Send EPG to take a stuck scanner out of program mode
      probe freq <from> <to> <step> [--mod M]
      probe freq --values <f1,f2,...> [--mod M] [--spread N]
                               Write each frequency (100 Hz units) to a spare empty channel and
                               print what the scanner stores, as CSV. --spread N rotates writes
                               across N empty channels. Restores every channel used.
      probe lockouts [--start F] [--step S] [--limit N]
                               Add global lockouts until the scanner refuses one, report the
                               capacity, then remove everything that was added.

    options:
      --log <file>             Write a transcript of every command and reply to <file>
    """

/// Set by Ctrl-C so long operations can stop between commands and still send EPG.
let interrupted = Atomic<Bool>(false)

struct Interrupted: Error {}

/// Routes Ctrl-C to `interrupted` instead of killing the process, so the command in flight
/// finishes and cleanup (restoring channels, `EPG`) still runs.
///
/// `nonisolated` matters: a handler closure formed inside `@MainActor` code is main-actor
/// isolated, and Swift traps (SIGTRAP, exit 133) when the signal source runs it on another queue.
nonisolated func installInterruptHandler() -> any DispatchSourceSignal {
    signal(SIGINT, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    source.setEventHandler { interrupted.store(true, ordering: .relaxed) }
    source.resume()
    return source
}

func checkInterrupted() throws {
    if interrupted.load(ordering: .relaxed) { throw Interrupted() }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

/// Mutable transcript shared with the connection's exchange callback.
final class Transcript {
    var lines: [String] = []
}

@main
enum CLI {
    static func main() {
        var arguments = Array(CommandLine.arguments.dropFirst())
        func takeFlag(_ flag: String) -> Bool {
            guard let index = arguments.firstIndex(of: flag) else { return false }
            arguments.remove(at: index)
            return true
        }
        func takeOption(_ option: String) -> String? {
            guard let index = arguments.firstIndex(of: option), index + 1 < arguments.count else { return nil }
            let value = arguments[index + 1]
            arguments.removeSubrange(index...index + 1)
            return value
        }

        let logPath = takeOption("--log")
        guard let command = arguments.first else { print(usage); exit(0) }
        arguments.removeFirst()

        let sigint = installInterruptHandler()
        defer { sigint.cancel() }

        if command == "list" {
            let devices = USBTransport.connectedDevices()
            if devices.isEmpty { print("No BC125AT found.") }
            for device in devices {
                print("\(device.productName)  location 0x\(String(device.locationID, radix: 16))")
            }
            exit(0)
        }

        if command == "read" {
            guard let path = arguments.first else { fail("read needs an output file") }
            readDocument(to: path)
            exit(0)
        }

        let connection: ScannerConnection
        do {
            connection = ScannerConnection(transport: try USBTransport())
        } catch {
            fail(error.description)
        }

        let transcript = Transcript()
        connection.onExchange = { sent, reply in
            transcript.lines.append("> \(sent)")
            transcript.lines.append(reply.map { "< \($0)" } ?? "< (no reply)")
        }
        func saveTranscript() {
            guard let logPath else { return }
            try? (transcript.lines.joined(separator: "\n") + "\n").write(toFile: logPath, atomically: true, encoding: .utf8)
        }

        do {
            switch command {
            case "info":
                print(try connection.execute("MDL").joined(separator: ","))
                print(try connection.execute("VER").joined(separator: ","))

            case "raw":
                let wrap = takeFlag("--prg")
                if wrap { print(try connection.send("PRG")) }
                defer { if wrap { print((try? connection.send("EPG")) ?? "EPG failed") } }
                for line in arguments {
                    try checkInterrupted()
                    print((try? connection.send(line)) ?? "(no reply)")
                }

            case "dump":
                try connection.inProgramMode {
                    for line in Dump.commands {
                        try checkInterrupted()
                        print((try? connection.send(line)) ?? "\(line): (no reply)")
                    }
                }

            case "verify":
                let report = try Verifier(connection: connection, allowWrite: takeFlag("--allow-write")).run()
                print(report)

            case "release":
                print(try connection.send("EPG"))

            case "probe":
                let modulation = takeOption("--mod") ?? "AUTO"
                let values = takeOption("--values")
                let start = takeOption("--start").flatMap { Int($0) } ?? 4500000
                let step = takeOption("--step").flatMap { Int($0) } ?? 125
                let limit = takeOption("--limit").flatMap { Int($0) } ?? 1500
                let spread = takeOption("--spread").flatMap { Int($0) } ?? 1
                switch arguments.first {
                case "freq":
                    let numbers = (values.map { $0.split(separator: ",").map(String.init) } ?? Array(arguments.dropFirst())).compactMap { Int($0) }
                    let frequencies = values != nil ? numbers
                        : numbers.count == 3 ? Array(stride(from: numbers[0], through: numbers[1], by: numbers[2])) : []
                    guard !frequencies.isEmpty else { fail("probe freq needs <from> <to> <step> or --values") }
                    try Probe.frequencies(frequencies, modulation: modulation, spread: spread, connection: connection)
                case "lockouts":
                    try Probe.lockoutCapacity(start: start, step: step, limit: limit, connection: connection)
                default:
                    fail("probe needs freq or lockouts")
                }

            default:
                print(usage)
                exit(2)
            }
        } catch is Interrupted {
            saveTranscript()
            fail("interrupted; scanner taken out of program mode")
        } catch let error as ScannerError {
            saveTranscript()
            fail(error.description)
        } catch {
            saveTranscript()
            fail("\(error)")
        }
        saveTranscript()
    }
}

/// Runs `ScannerSession.readConfiguration` — the app's read path — and saves the result.
func readDocument(to path: String) {
    let done = DispatchSemaphore(value: 0)
    let outcome = Mutex<Result<ScannerConfig, any Error>?>(nil)
    Task {
        let result: Result<ScannerConfig, any Error>
        do {
            let session = try ScannerSession.open()
            result = .success(try await session.readConfiguration())
            await session.close()
        } catch {
            result = .failure(error)
        }
        outcome.withLock { $0 = result }
        done.signal()
    }
    done.wait()
    switch outcome.withLock({ $0 })! {
    case .failure(let error):
        fail("\(error)")
    case .success(let config):
        do {
            try NativeFormat.encode(config).write(to: URL(fileURLWithPath: path))
        } catch {
            fail("couldn't save \(path): \(error.localizedDescription)")
        }
        let issues = config.validate()
        print("Read \(config.usedChannelCount) channels, \(config.globalLockouts.count) global lockouts from \(config.metadata.model ?? "?") \(config.metadata.firmware ?? "")")
        print("\(issues.count { $0.severity == .error }) errors, \(issues.count { $0.severity == .warning }) warnings")
        for issue in issues.prefix(20) { print("  \(issue.severity == .error ? "error" : "warning"): \(issue.location): \(issue.message)") }
        print("Saved \(path)")
    }
}
