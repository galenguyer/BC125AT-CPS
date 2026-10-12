#ifndef BC125AT_USB_H
#define BC125AT_USB_H

#include <stdint.h>

/// An open connection to a BC125AT's CDC data interface (interface 1, two bulk pipes).
///
/// This uses IOKit's IOUSBLib plug-in interfaces rather than the IOUSBHost framework because
/// the App Sandbox (with com.apple.security.device.usb) allows IOUSBLib's user clients but
/// refuses IOUSBHost's (kIOReturnNotPermitted). See SPEC.md §2.
typedef struct bc125at_usb bc125at_usb;

/// Opens the scanner at `location_id`, or the first one found when it is 0.
/// Returns an IOReturn: kIOReturnSuccess, kIOReturnNotFound (no scanner),
/// kIOReturnExclusiveAccess (another process has it open), or another IOKit error.
int32_t bc125at_usb_open(uint32_t location_id, bc125at_usb *_Nullable *_Nonnull out_handle);

/// Writes `length` bytes to the bulk OUT pipe.
int32_t bc125at_usb_write(bc125at_usb *_Nonnull handle, const uint8_t *_Nonnull data, uint32_t length, uint32_t timeout_ms);

/// Reads one transfer from the bulk IN pipe into `buffer`. On entry `*length` is the buffer's
/// capacity; on return it is the number of bytes received. Returns kIOUSBTransactionTimeout
/// if nothing arrives within `timeout_ms`.
int32_t bc125at_usb_read(bc125at_usb *_Nonnull handle, uint8_t *_Nonnull buffer, uint32_t *_Nonnull length, uint32_t timeout_ms);

/// Closes the interface and frees the handle.
void bc125at_usb_close(bc125at_usb *_Nonnull handle);

#endif
