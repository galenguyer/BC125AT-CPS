#include "bc125at_usb.h"

#include <stdlib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>

struct bc125at_usb {
    IOUSBInterfaceInterface942 **interface;
    UInt8 in_pipe;
    UInt8 out_pipe;
};

static int read_int_property(io_registry_entry_t entry, CFStringRef key, int fallback) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0);
    int result = fallback;
    if (value != NULL) {
        if (CFGetTypeID(value) == CFNumberGetTypeID()) CFNumberGetValue(value, kCFNumberIntType, &result);
        CFRelease(value);
    }
    return result;
}

/// Finds interface 1 of the matching device. `IOServiceMatching` on the interface class doesn't
/// find this device's interfaces, so walk the device's children instead.
static io_service_t find_data_interface(uint32_t location_id) {
    CFMutableDictionaryRef matching = IOServiceMatching(kIOUSBHostDeviceClassName);
    int vendor = 0x1965, product = 0x0017;
    CFNumberRef vendor_number = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &vendor);
    CFNumberRef product_number = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &product);
    CFDictionarySetValue(matching, CFSTR(kUSBVendorID), vendor_number);
    CFDictionarySetValue(matching, CFSTR(kUSBProductID), product_number);
    CFRelease(vendor_number);
    CFRelease(product_number);

    io_iterator_t devices;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, matching, &devices) != KERN_SUCCESS) return 0;
    io_service_t found = 0, device;
    while (found == 0 && (device = IOIteratorNext(devices)) != 0) {
        if (location_id == 0 || (uint32_t)read_int_property(device, CFSTR(kUSBDevicePropertyLocationID), 0) == location_id) {
            io_iterator_t children;
            if (IORegistryEntryGetChildIterator(device, kIOServicePlane, &children) == KERN_SUCCESS) {
                io_service_t child;
                while ((child = IOIteratorNext(children)) != 0) {
                    if (found == 0 && IOObjectConformsTo(child, kIOUSBHostInterfaceClassName)
                        && read_int_property(child, CFSTR(kUSBInterfaceNumber), -1) == 1) {
                        found = child;
                    } else {
                        IOObjectRelease(child);
                    }
                }
                IOObjectRelease(children);
            }
        }
        IOObjectRelease(device);
    }
    IOObjectRelease(devices);
    return found;
}

int32_t bc125at_usb_open(uint32_t location_id, bc125at_usb **out_handle) {
    *out_handle = NULL;
    io_service_t service = find_data_interface(location_id);
    if (service == 0) return kIOReturnNotFound;

    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    kern_return_t result = IOCreatePlugInInterfaceForService(service, kIOUSBInterfaceUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
    IOObjectRelease(service);
    if (result != KERN_SUCCESS || plugin == NULL) return result != KERN_SUCCESS ? result : kIOReturnError;

    IOUSBInterfaceInterface942 **interface = NULL;
    HRESULT query = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID942), (LPVOID *)&interface);
    IODestroyPlugInInterface(plugin);
    if (query != S_OK || interface == NULL) return kIOReturnUnsupported;

    result = (*interface)->USBInterfaceOpen(interface);
    if (result != kIOReturnSuccess) {
        (*interface)->Release(interface);
        return result;
    }

    UInt8 endpoints = 0, in_pipe = 0, out_pipe = 0;
    (*interface)->GetNumEndpoints(interface, &endpoints);
    for (UInt8 pipe = 1; pipe <= endpoints; pipe++) {
        UInt8 direction, number, transfer_type, interval;
        UInt16 max_packet;
        if ((*interface)->GetPipeProperties(interface, pipe, &direction, &number, &transfer_type, &max_packet, &interval) != kIOReturnSuccess) continue;
        if (transfer_type != kUSBBulk) continue;
        if (direction == kUSBIn) in_pipe = pipe;
        else if (direction == kUSBOut) out_pipe = pipe;
    }
    if (in_pipe == 0 || out_pipe == 0) {
        (*interface)->USBInterfaceClose(interface);
        (*interface)->Release(interface);
        return kIOReturnNotFound;
    }

    bc125at_usb *handle = malloc(sizeof *handle);
    if (handle == NULL) {
        (*interface)->USBInterfaceClose(interface);
        (*interface)->Release(interface);
        return kIOReturnNoMemory;
    }
    handle->interface = interface;
    handle->in_pipe = in_pipe;
    handle->out_pipe = out_pipe;
    *out_handle = handle;
    return kIOReturnSuccess;
}

int32_t bc125at_usb_write(bc125at_usb *handle, const uint8_t *data, uint32_t length, uint32_t timeout_ms) {
    return (*handle->interface)->WritePipeTO(handle->interface, handle->out_pipe, (void *)data, length, timeout_ms, timeout_ms);
}

int32_t bc125at_usb_read(bc125at_usb *handle, uint8_t *buffer, uint32_t *length, uint32_t timeout_ms) {
    return (*handle->interface)->ReadPipeTO(handle->interface, handle->in_pipe, buffer, length, timeout_ms, timeout_ms);
}

void bc125at_usb_close(bc125at_usb *handle) {
    (*handle->interface)->USBInterfaceClose(handle->interface);
    (*handle->interface)->Release(handle->interface);
    free(handle);
}
