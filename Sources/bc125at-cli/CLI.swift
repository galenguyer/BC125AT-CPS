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
      verify [--allow-write]   Run the Phase 0 protocol checks (SPEC.md §10) and print a report.
                               --allow-write also runs round-trip tests that modify, then restore,
                               spare empty channels and a few settings.
      release                  Send EPG to take a stuck scanner out of program mode

    options:
      --log <file>             Write a transcript of every command and reply to <file>
    """

/// Set by Ctrl-C so long operations can stop between commands and still send EPG.
let interrupted = Atomic<Bool>(false)

struct Interrupted: Error {}

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

        signal(SIGINT, SIG_IGN)
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        sigint.setEventHandler { interrupted.store(true, ordering: .relaxed) }
        sigint.resume()

        if command == "list" {
            let devices = USBTransport.connectedDevices()
            if devices.isEmpty { print("No BC125AT found.") }
            for device in devices {
                print("\(device.productName)  location 0x\(String(device.locationID, radix: 16))")
            }
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
