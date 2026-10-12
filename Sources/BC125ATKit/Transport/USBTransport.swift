import Foundation
import IOKit
import IOUSBHost

/// A BC125AT visible on USB.
public struct USBScannerDevice: Sendable, Hashable {
    public var productName: String
    public var locationID: UInt32
}

/// Talks to the scanner's CDC data interface directly over bulk endpoints.
///
/// The BC125AT's CDC descriptors aren't accepted by macOS's AppleUSBCDC driver, so no
/// `/dev/cu.*` node appears. Interface 1 (class 0x0A, CDC data) has no driver attached,
/// so user space can open it with IOUSBHost and exchange bytes without any line-coding
/// or DTR setup. See SPEC.md §2.
public final class USBTransport: LineTransport {
    public static let vendorID = 0x1965
    public static let productID = 0x0017
    static let dataInterfaceNumber = 1

    private var interface: IOUSBHostInterface?
    private let inPipe: IOUSBHostPipe
    private let outPipe: IOUSBHostPipe
    private let maxPacketSize: Int
    private var buffer = LineBuffer()

    /// Lists every connected BC125AT.
    public static func connectedDevices() -> [USBScannerDevice] {
        deviceServices().map { service in
            defer { IOObjectRelease(service) }
            return USBScannerDevice(
                productName: property(service, "USB Product Name") ?? "BC125AT",
                locationID: property(service, "locationID") ?? 0
            )
        }
    }

    /// Opens the scanner at `locationID`, or the first one found if `nil`.
    public init(locationID: UInt32? = nil) throws(TransportError) {
        let services = Self.deviceServices()
        defer { services.forEach { IOObjectRelease($0) } }
        guard let device = services.first(where: { locationID == nil || Self.property($0, "locationID") == locationID })
        else { throw .deviceNotFound }
        guard let dataService = Self.childInterface(of: device, number: Self.dataInterfaceNumber)
        else { throw .openFailed("data interface \(Self.dataInterfaceNumber) not found") }
        defer { IOObjectRelease(dataService) }

        let interface: IOUSBHostInterface
        do {
            interface = try IOUSBHostInterface(__ioService: dataService, options: [], queue: nil, interestHandler: nil)
        } catch {
            throw .openFailed(Self.describe(error))
        }

        var inAddress: Int?, outAddress: Int?, packetSize = 64
        var cursor: UnsafePointer<IOUSBDescriptorHeader>?
        while let endpoint = IOUSBGetNextEndpointDescriptor(interface.configurationDescriptor, interface.interfaceDescriptor, cursor) {
            let address = Int(endpoint.pointee.bEndpointAddress)
            if address & 0x80 != 0 { inAddress = address } else { outAddress = address }
            packetSize = Int(endpoint.pointee.wMaxPacketSize)
            cursor = UnsafeRawPointer(endpoint).assumingMemoryBound(to: IOUSBDescriptorHeader.self)
        }
        guard let inAddress, let outAddress else {
            interface.destroy()
            throw .openFailed("bulk endpoints not found")
        }
        do {
            inPipe = try interface.copyPipe(withAddress: inAddress)
            outPipe = try interface.copyPipe(withAddress: outAddress)
        } catch {
            interface.destroy()
            throw .openFailed(Self.describe(error))
        }
        self.interface = interface
        self.maxPacketSize = packetSize
    }

    deinit { close() }

    public func writeLine(_ line: String, timeout: Duration) throws(TransportError) {
        guard interface != nil else { throw .closed }
        let data = NSMutableData(data: Data((line + "\r").utf8))
        var sent = 0
        do {
            try outPipe.__sendIORequest(with: data, bytesTransferred: &sent, completionTimeout: timeout.timeInterval)
        } catch {
            throw Self.transportError(error)
        }
    }

    public func readLine(timeout: Duration) throws(TransportError) -> String {
        guard interface != nil else { throw .closed }
        let deadline = ContinuousClock.now + timeout
        while true {
            if let line = buffer.nextLine() { return line }
            let remaining = deadline - .now
            guard remaining > .zero else { throw .timedOut }
            buffer.append(try readPacket(timeout: remaining))
        }
    }

    public func drainInput() {
        buffer.removeAll()
        while let bytes = try? readPacket(timeout: .milliseconds(50)), !bytes.isEmpty {}
    }

    public func close() {
        interface?.destroy()
        interface = nil
    }

    private func readPacket(timeout: Duration) throws(TransportError) -> [UInt8] {
        let data = NSMutableData(length: maxPacketSize * 8)!
        var received = 0
        do {
            try inPipe.__sendIORequest(with: data, bytesTransferred: &received, completionTimeout: timeout.timeInterval)
        } catch {
            throw Self.transportError(error)
        }
        return [UInt8](UnsafeRawBufferPointer(start: data.bytes, count: received))
    }

    // MARK: IOKit helpers

    private static func deviceServices() -> [io_service_t] {
        let matching = IOUSBHostDevice.__createMatchingDictionary(
            withVendorID: NSNumber(value: vendorID), productID: NSNumber(value: productID), bcdDevice: nil,
            deviceClass: nil, deviceSubclass: nil, deviceProtocol: nil, speed: nil, productIDArray: nil
        ).takeRetainedValue()
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var services: [io_service_t] = []
        while case let service = IOIteratorNext(iterator), service != 0 { services.append(service) }
        return services
    }

    /// `IOUSBHostInterface`'s own matching dictionary doesn't find this device's interfaces,
    /// so walk the device's children instead.
    private static func childInterface(of device: io_service_t, number: Int) -> io_service_t? {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(device, kIOServicePlane, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var found: io_service_t?
        while case let child = IOIteratorNext(iterator), child != 0 {
            if found == nil, IOObjectConformsTo(child, "IOUSBHostInterface") != 0,
               property(child, "bInterfaceNumber") == number {
                found = child
            } else {
                IOObjectRelease(child)
            }
        }
        return found
    }

    private static func property<T>(_ service: io_service_t, _ key: String) -> T? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? T
    }

    private static func transportError(_ error: any Error) -> TransportError {
        if (error as NSError).code == Int(kIOReturnTimeout) { return .timedOut }
        return .ioFailed(describe(error))
    }

    private static func describe(_ error: any Error) -> String {
        let code = UInt32(bitPattern: Int32(truncatingIfNeeded: (error as NSError).code))
        return "\((error as NSError).localizedDescription) (0x\(String(code, radix: 16)))"
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
