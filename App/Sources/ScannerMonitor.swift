import BC125ATKit
import Observation

/// Which scanners are plugged in, kept up to date by IOKit notifications. Shared by all windows.
@MainActor
@Observable
final class ScannerMonitor {
    private(set) var devices: [USBScannerDevice] = [] {
        didSet { live.deviceChanged(selectedDevice) }
    }
    /// The scanner reads and writes go to, by USB location. Falls back to the first one connected.
    var selectedLocation: UInt32? {
        didSet { live.deviceChanged(selectedDevice) }
    }
    /// What the selected scanner is receiving, with its volume and squelch.
    let live = LiveMonitor()

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
