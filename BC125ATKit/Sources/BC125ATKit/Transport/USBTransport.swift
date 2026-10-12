import CBC125ATUSB
import Foundation
import IOKit
import IOKit.usb

/// A BC125AT visible on USB.
public struct USBScannerDevice: Sendable, Hashable {
    public var productName: String
    public var locationID: UInt32
}

/// Talks to the scanner's CDC data interface directly over its bulk pipes.
///
/// The BC125AT's CDC descriptors aren't accepted by macOS's AppleUSBCDC driver, so no
/// `/dev/cu.*` node appears. Interface 1 (class 0x0A, CDC data) has no driver attached, so user
/// space can open it and exchange bytes without any line-coding or DTR setup. The I/O itself is
/// in the `CBC125ATUSB` C target, which uses IOUSBLib because the App Sandbox refuses the newer
/// IOUSBHost framework's user clients. See SPEC.md §2.
public final class USBTransport: LineTransport {
    public static let vendorID = 0x1965
    public static let productID = 0x0017

    private var handle: OpaquePointer?
    private var buffer = LineBuffer()

    /// Lists every connected BC125AT. Reads the IOKit registry only; opens nothing.
    public static func connectedDevices() -> [USBScannerDevice] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, deviceMatchingDictionary(), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var devices: [USBScannerDevice] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            devices.append(USBScannerDevice(
                productName: property(service, kUSBProductString) ?? "BC125AT",
                locationID: property(service, kUSBDevicePropertyLocationID) ?? 0
            ))
            IOObjectRelease(service)
        }
        return devices
    }

    /// Opens the scanner at `locationID`, or the first one found if `nil`.
    public init(locationID: UInt32? = nil) throws(TransportError) {
        var handle: OpaquePointer?
        let result = bc125at_usb_open(locationID ?? 0, &handle)
        switch result {
        case kIOReturnSuccess: self.handle = handle
        case kIOReturnNotFound: throw .deviceNotFound
        case kIOReturnExclusiveAccess: throw .openFailed("another program is using the scanner")
        default: throw .openFailed(Self.describe(result))
        }
    }

    deinit { close() }

    public func writeLine(_ line: String, timeout: Duration) throws(TransportError) {
        guard let handle else { throw .closed }
        var bytes = Array((line + "\r").utf8)
        let result = bc125at_usb_write(handle, &bytes, UInt32(bytes.count), timeout.milliseconds)
        guard result == kIOReturnSuccess else { throw Self.transportError(result) }
    }

    public func readLine(timeout: Duration) throws(TransportError) -> String {
        guard handle != nil else { throw .closed }
        let deadline = ContinuousClock.now + timeout
        while true {
            if let line = buffer.nextLine() { return line }
            let remaining = deadline - .now
            guard remaining > .zero else { throw .timedOut }
            buffer.append(try readTransfer(timeout: remaining))
        }
    }

    public func drainInput() {
        buffer.removeAll()
        while let bytes = try? readTransfer(timeout: .milliseconds(50)), !bytes.isEmpty {}
    }

    public func close() {
        if let handle { bc125at_usb_close(handle) }
        handle = nil
    }

    private func readTransfer(timeout: Duration) throws(TransportError) -> [UInt8] {
        guard let handle else { throw .closed }
        var bytes = [UInt8](repeating: 0, count: 512)
        var length = UInt32(bytes.count)
        let result = bc125at_usb_read(handle, &bytes, &length, max(1, timeout.milliseconds))
        guard result == kIOReturnSuccess else { throw Self.transportError(result) }
        return Array(bytes.prefix(Int(length)))
    }

    // MARK: IOKit helpers

    static func deviceMatchingDictionary() -> CFMutableDictionary {
        let matching = IOServiceMatching(kIOUSBHostDeviceClassName) as NSMutableDictionary
        matching[kUSBVendorID] = vendorID
        matching[kUSBProductID] = productID
        return matching as CFMutableDictionary
    }

    private static func property<T>(_ service: io_service_t, _ key: String) -> T? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? T
    }

    private static func transportError(_ result: Int32) -> TransportError {
        switch result {
        case Int32(bitPattern: 0xE000_4051) /* kIOUSBTransactionTimeout */, kIOReturnTimeout: .timedOut
        case kIOReturnNoDevice, kIOReturnNotResponding, kIOReturnNotAttached: .ioFailed("the scanner was disconnected")
        default: .ioFailed(describe(result))
        }
    }

    private static func describe(_ result: Int32) -> String {
        let text = mach_error_string(result).map { String(cString: $0) } ?? "IOKit error"
        return "\(text) (0x\(String(UInt32(bitPattern: result), radix: 16)))"
    }
}

extension Duration {
    var milliseconds: UInt32 {
        let (seconds, attoseconds) = components
        return UInt32(clamping: seconds * 1_000 + attoseconds / 1_000_000_000_000_000)
    }
}
