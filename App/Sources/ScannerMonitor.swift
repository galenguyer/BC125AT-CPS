import BC125ATKit
import Observation

/// Which scanners are plugged in, kept up to date by IOKit notifications. Shared by all windows.
@MainActor
@Observable
final class ScannerMonitor {
    private(set) var devices: [USBScannerDevice] = []
    /// The scanner reads and writes go to, by USB location. Falls back to the first one connected.
    var selectedLocation: UInt32?

    @ObservationIgnored private var watcher: USBDeviceWatcher?

    init() {
        watcher = USBDeviceWatcher { [weak self] devices in
            self?.devices = devices
        }
    }

    var selectedDevice: USBScannerDevice? {
        devices.first { $0.locationID == selectedLocation } ?? devices.first
    }
}
