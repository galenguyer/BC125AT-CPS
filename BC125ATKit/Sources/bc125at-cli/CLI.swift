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
      write <file> [--yes] [--backup <file>]
                               Show what writing the document (.bc125at, or Uniden's .bc125at_ss)
                               would change; with --yes, back up the scanner (to --backup, if
                               given), write, and verify
      convert <in> <out>       Convert between .bc125at and Uniden's .bc125at_ss (by extension)
      verify [--allow-write]   Run the Phase 0 protocol checks (SPEC.md §10) and print a report.
                               --allow-write also runs round-trip tests that modify, then restore,
                               spare empty channels and a few settings.
      release                  Send EPG to take a stuck scanner out of program mode
      mode                     Say whether the scanner is scanning or in hold, and on which channel
      scan                     Press Scan: resume scanning
      hold <channel>           Hold on a channel (1-500)
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
        if command == "mode" || command == "scan" || command == "hold" {
            let channel = arguments.first.flatMap { Int($0) }
            if command == "hold", !(channel.map { (1...ScannerConfig.channelCount).contains($0) } ?? false) {
                fail("hold needs a channel number, 1-500")
            }
            let message = runBlocking {
                let session = try ScannerSession.open()
                defer { Task { await session.close() } }
                switch command {
                case "scan":
                    try await session.scan()
                    return "Scanning"
                case "hold":
                    return try await session.hold(on: channel!) ? "Holding on channel \(channel!)" : "The scanner didn't stop on channel \(channel!) (is it empty?)"
                default:
                    return describe(try await session.scanMode())
                }
            }
            print(message)
            exit(0)
        }
        if command == "convert" {
            guard arguments.count == 2 else { fail("convert needs an input and an output file") }
            save(load(arguments[0]), to: arguments[1])
            print("Converted \(arguments[0]) to \(arguments[1])")
            exit(0)
        }
        if command == "write" {
            let confirmed = takeFlag("--yes")
            let backup = takeOption("--backup")
            guard let path = arguments.first else { fail("write needs a .bc125at file") }
            writeDocument(from: path, confirmed: confirmed, backupPath: backup)
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

/// Runs async work from the synchronous CLI. The session runs on its own queue, so blocking the
/// main thread here is fine.
func runBlocking<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) -> T {
    let done = DispatchSemaphore(value: 0)
    let outcome = Mutex<Result<T, any Error>?>(nil)
    Task {
        let result: Result<T, any Error>
        do { result = .success(try await work()) } catch { result = .failure(error) }
        outcome.withLock { $0 = result }
        done.signal()
    }
    done.wait()
    switch outcome.withLock({ $0 })! {
    case .success(let value): return value
    case .failure(let error): fail("\(error)")
    }
}

/// Runs `ScannerSession.readConfiguration` — the app's read path — and saves the result.
func readDocument(to path: String) {
    let config = runBlocking {
        let session = try ScannerSession.open()
        defer { Task { await session.close() } }
        return try await keepingScanMode(session) { try await session.readConfiguration() }
    }
    save(config, to: path)
    let issues = config.validate()
    print("Read \(config.usedChannelCount) channels, \(config.globalLockouts.count) global lockouts from \(config.metadata.model ?? "?") \(config.metadata.firmware ?? "")")
    print("\(issues.count { $0.severity == .error }) errors, \(issues.count { $0.severity == .warning }) warnings")
    for issue in issues.prefix(20) { print("  \(issue.severity == .error ? "error" : "warning"): \(issue.location): \(issue.message)") }
    print("Saved \(path)")
}

/// The app's write path (SPEC.md §7): validate, read, plan, back up, write, verify.
func writeDocument(from path: String, confirmed: Bool, backupPath: String?) {
    var document = load(path)
    let errors = document.validate().filter { $0.severity == .error }
    guard errors.isEmpty else {
        for issue in errors { print("error: \(issue.location): \(issue.message)") }
        fail("\(errors.count) errors; fix them before writing")
    }
    let current = runBlocking {
        let session = try ScannerSession.open()
        defer { Task { await session.close() } }
        return try await keepingScanMode(session) { try await session.readConfiguration() }
    }
    // Uniden's files have no global lockouts, so leave the scanner's alone.
    if isUniden(path) { document.globalLockouts = current.globalLockouts }
    let plan = WritePlan(from: current, to: document)
    for adjustment in plan.adjustments { print("note: \(adjustment.title): \(adjustment.detail)") }
    guard !plan.isEmpty else { print("The scanner already matches \(path)."); return }
    for section in WritePlan.Section.allCases where !plan.steps(in: section).isEmpty {
        print("\(section.rawValue):")
        for step in plan.steps(in: section) { print("  \(step.title): \(step.detail)    [\(step.command)]") }
    }
    guard confirmed else { print("\(plan.steps.count) changes. Run again with --yes to write them."); return }
    if let backupPath { save(current, to: backupPath); print("Backed up the scanner to \(backupPath)") }
    let report = runBlocking {
        let session = try ScannerSession.open()
        defer { Task { await session.close() } }
        return try await keepingScanMode(session) { try await session.write(plan) }
    }
    print("Wrote \(report.written) of \(plan.steps.count) changes.")
    for failure in report.failures { print("failed: \(failure.step.title): \(failure.reason)") }
    for mismatch in report.mismatches { print("mismatch after read-back: \(mismatch.title): \(mismatch.detail)") }
    for stored in report.storedDifferently { print("stored differently: \(stored.title): \(stored.detail)") }
    print(report.succeeded ? "Verified: the scanner matches the document." : "The scanner does NOT fully match the document.")
}

/// Notes whether the scanner is scanning or held, runs `work` (which leaves it held on channel 1),
/// then puts it back, as the app does (SPEC.md §3.8).
func keepingScanMode<T: Sendable>(_ session: ScannerSession, _ work: () async throws -> T) async throws -> T {
    let mode = try? await session.scanMode()
    let result = try await work()
    if let mode {
        let restored = (try? await session.restore(mode)) ?? false
        FileHandle.standardError.write(Data("\(restored ? "Back to" : "Couldn't return to") \(describe(mode).lowercased())\n".utf8))
    }
    return result
}

func describe(_ mode: ScanMode?) -> String {
    switch mode {
    case .scanning: "Scanning"
    case .hold(let channel): "Holding on channel \(channel)"
    case nil: "Not on a memory channel (a menu, search, Close Call Only or weather)"
    }
}

func isUniden(_ path: String) -> Bool {
    URL(fileURLWithPath: path).pathExtension.lowercased() == UnidenFormat.fileExtension
}

/// Opens a .bc125at document or a Uniden .bc125at_ss file.
func load(_ path: String) -> ScannerConfig {
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return isUniden(path) ? try UnidenFormat.decode(data) : try NativeFormat.decode(data)
    } catch {
        fail("couldn't open \(path): \(error)")
    }
}

/// Saves as a .bc125at document, or as a Uniden .bc125at_ss file if the path says so.
func save(_ config: ScannerConfig, to path: String) {
    do {
        let data = isUniden(path) ? UnidenFormat.encode(config) : try NativeFormat.encode(config)
        try data.write(to: URL(fileURLWithPath: path))
    } catch {
        fail("couldn't save \(path): \(error.localizedDescription)")
    }
}
