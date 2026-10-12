import Foundation
import IOKit

/// Reports the connected BC125ATs whenever one is plugged in or removed, using IOKit
/// notifications on the main queue.
@MainActor
public final class USBDeviceWatcher {
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private let onChange: @MainActor ([USBScannerDevice]) -> Void

    /// Calls `onChange` immediately with the current devices, then after every change.
    public init(onChange: @escaping @MainActor ([USBScannerDevice]) -> Void) {
        self.onChange = onChange
        let port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, .main)
        self.port = port
        let context = Unmanaged.passUnretained(self).toOpaque()
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            let status = IOServiceAddMatchingNotification(port, type, USBTransport.deviceMatchingDictionary(), { context, iterator in
                guard let context else { return }
                let watcher = Unmanaged<USBDeviceWatcher>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated { watcher.changed(iterator) }
            }, context, &iterator)
            guard status == KERN_SUCCESS else { continue }
            iterators.append(iterator)
            // Arming a notification requires draining its iterator once.
            Self.drain(iterator)
        }
        onChange(USBTransport.connectedDevices())
    }

    isolated deinit {
        iterators.forEach { IOObjectRelease($0) }
        if let port { IONotificationPortDestroy(port) }
    }

    private func changed(_ iterator: io_iterator_t) {
        Self.drain(iterator)
        onChange(USBTransport.connectedDevices())
    }

    private static func drain(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) }
    }
}
