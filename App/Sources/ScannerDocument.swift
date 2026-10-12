import BC125ATKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let bc125atConfig = UTType(exportedAs: "net.k9fgt.bc125at.config", conformingTo: .json)
}

/// A `.bc125at` file: one scanner configuration (SPEC.md §5).
struct ScannerDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.bc125atConfig]

    var config: ScannerConfig

    init(config: ScannerConfig = ScannerConfig()) {
        self.config = config
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        do {
            config = try NativeFormat.decode(data)
        } catch {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedFailureReasonErrorKey: error.description])
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try NativeFormat.encode(config))
    }
}
