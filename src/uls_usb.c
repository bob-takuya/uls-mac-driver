/*
 * ULS (Universal Laser Systems) USB Communication Implementation
 * macOS Driver Implementation
 *
 * Based on reverse engineering of Windows driver ucpinst-5.38.58.00.exe
 */

#include "uls_usb.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <IOKit/IOCFPlugIn.h>

/* Private variables for hotplug notification */
static IONotificationPortRef gNotifyPort = NULL;
static io_iterator_t gAddedIter = 0;
static io_iterator_t gRemovedIter = 0;
static ULSDeviceCallback gHotplugCallback = NULL;
static void *gHotplugUserContext = NULL;
static CFRunLoopRef gRunLoop = NULL;
static pthread_t gNotificationThread;
static bool gNotificationThreadRunning = false;

/* Supported Product IDs */
static const uint16_t gSupportedPIDs[] = {
    ULS_PID_PLS_BOOTLOADER,
    ULS_PID_PLS_PRINT,
    ULS_PID_VLS_360_BOOTLOADER,
    ULS_PID_VLS_360_PRINT,
    ULS_PID_ILS_BOOTLOADER,
    ULS_PID_ILS_PRINT,
    ULS_PID_VLS_230_BOOTLOADER,
    ULS_PID_VLS_230_PRINT,
    0 /* terminator */
};

/* Helper function to get model type from product ID */
static ULSModelType get_model_type(uint16_t productId) {
    switch (productId) {
        case ULS_PID_PLS_BOOTLOADER:
        case ULS_PID_PLS_PRINT:
            return ULS_MODEL_PLS;
        case ULS_PID_VLS_360_BOOTLOADER:
        case ULS_PID_VLS_360_PRINT:
            return ULS_MODEL_VLS_360;
        case ULS_PID_VLS_230_BOOTLOADER:
        case ULS_PID_VLS_230_PRINT:
            return ULS_MODEL_VLS_230;
        case ULS_PID_ILS_BOOTLOADER:
        case ULS_PID_ILS_PRINT:
            return ULS_MODEL_ILS;
        default:
            return ULS_MODEL_UNKNOWN;
    }
}

/* Helper function to check if device is in bootloader mode */
static bool is_bootloader_mode(uint16_t productId) {
    return (productId == ULS_PID_PLS_BOOTLOADER ||
            productId == ULS_PID_VLS_360_BOOTLOADER ||
            productId == ULS_PID_ILS_BOOTLOADER ||
            productId == ULS_PID_VLS_230_BOOTLOADER);
}

/* Find all connected ULS devices */
ULSError uls_find_devices(ULSDeviceInfo **devices, int *count) {
    CFMutableDictionaryRef matchingDict;
    io_iterator_t iter;
    io_service_t usbDevice;
    kern_return_t kr;
    int deviceCount = 0;
    int capacity = 8;

    *devices = NULL;
    *count = 0;

    /* Create matching dictionary for USB devices */
    matchingDict = IOServiceMatching(kIOUSBDeviceClassName);
    if (matchingDict == NULL) {
        return ULS_ERROR_UNKNOWN;
    }

    /* Add vendor ID to matching criteria */
    CFNumberRef vendorIdRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type,
                                              (int[]){ULS_USB_VENDOR_ID});
    CFDictionarySetValue(matchingDict, CFSTR(kUSBVendorID), vendorIdRef);
    CFRelease(vendorIdRef);

    /* Get matching services */
    kr = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict, &iter);
    if (kr != KERN_SUCCESS) {
        return ULS_ERROR_NOT_FOUND;
    }

    /* Allocate initial device array */
    *devices = (ULSDeviceInfo *)malloc(capacity * sizeof(ULSDeviceInfo));
    if (*devices == NULL) {
        IOObjectRelease(iter);
        return ULS_ERROR_UNKNOWN;
    }

    /* Iterate through found devices */
    while ((usbDevice = IOIteratorNext(iter)) != 0) {
        CFNumberRef productIdRef;
        CFStringRef serialRef;
        SInt32 productId;

        /* Get product ID */
        productIdRef = (CFNumberRef)IORegistryEntryCreateCFProperty(
            usbDevice, CFSTR(kUSBProductID), kCFAllocatorDefault, 0);

        if (productIdRef) {
            CFNumberGetValue(productIdRef, kCFNumberSInt32Type, &productId);
            CFRelease(productIdRef);

            /* Check if this is a supported product */
            bool supported = false;
            for (int i = 0; gSupportedPIDs[i] != 0; i++) {
                if (gSupportedPIDs[i] == productId) {
                    supported = true;
                    break;
                }
            }

            if (supported) {
                /* Expand array if needed */
                if (deviceCount >= capacity) {
                    capacity *= 2;
                    *devices = (ULSDeviceInfo *)realloc(*devices, capacity * sizeof(ULSDeviceInfo));
                    if (*devices == NULL) {
                        IOObjectRelease(usbDevice);
                        IOObjectRelease(iter);
                        return ULS_ERROR_UNKNOWN;
                    }
                }

                /* Fill device info */
                ULSDeviceInfo *info = &(*devices)[deviceCount];
                memset(info, 0, sizeof(ULSDeviceInfo));
                info->vendorId = ULS_USB_VENDOR_ID;
                info->productId = productId;
                info->model = get_model_type(productId);
                info->isConnected = true;

                if (is_bootloader_mode(productId)) {
                    info->state = ULS_STATE_BOOTLOADER;
                } else {
                    info->state = ULS_STATE_READY;
                }

                /* Get serial number if available */
                serialRef = (CFStringRef)IORegistryEntryCreateCFProperty(
                    usbDevice, CFSTR(kUSBSerialNumberString), kCFAllocatorDefault, 0);
                if (serialRef) {
                    CFStringGetCString(serialRef, info->serialNumber,
                                       sizeof(info->serialNumber), kCFStringEncodingUTF8);
                    CFRelease(serialRef);
                }

                deviceCount++;
            }
        }

        IOObjectRelease(usbDevice);
    }

    IOObjectRelease(iter);
    *count = deviceCount;

    return (deviceCount > 0) ? ULS_SUCCESS : ULS_ERROR_NOT_FOUND;
}

/* Free device list */
void uls_free_device_list(ULSDeviceInfo *devices, int count) {
    if (devices) {
        free(devices);
    }
}

/* Open a ULS device */
ULSDevice* uls_open_device(uint16_t vendorId, uint16_t productId) {
    CFMutableDictionaryRef matchingDict;
    io_iterator_t iter;
    io_service_t usbDevice;
    kern_return_t kr;
    IOCFPlugInInterface **plugInInterface = NULL;
    SInt32 score;
    HRESULT res;
    ULSDevice *device = NULL;

    /* Create matching dictionary */
    matchingDict = IOServiceMatching(kIOUSBDeviceClassName);
    if (matchingDict == NULL) {
        return NULL;
    }

    /* Add vendor and product ID */
    CFNumberRef vendorIdRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type,
                                              (int[]){vendorId});
    CFNumberRef productIdRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type,
                                               (int[]){productId});
    CFDictionarySetValue(matchingDict, CFSTR(kUSBVendorID), vendorIdRef);
    CFDictionarySetValue(matchingDict, CFSTR(kUSBProductID), productIdRef);
    CFRelease(vendorIdRef);
    CFRelease(productIdRef);

    /* Get matching services */
    kr = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict, &iter);
    if (kr != KERN_SUCCESS) {
        return NULL;
    }

    /* Get first matching device */
    usbDevice = IOIteratorNext(iter);
    IOObjectRelease(iter);

    if (usbDevice == 0) {
        return NULL;
    }

    /* Create plugin interface */
    kr = IOCreatePlugInInterfaceForService(usbDevice, kIOUSBDeviceUserClientTypeID,
                                            kIOCFPlugInInterfaceID, &plugInInterface, &score);
    if (kr != KERN_SUCCESS || plugInInterface == NULL) {
        IOObjectRelease(usbDevice);
        return NULL;
    }

    /* Allocate device structure */
    device = (ULSDevice *)calloc(1, sizeof(ULSDevice));
    if (device == NULL) {
        (*plugInInterface)->Release(plugInInterface);
        IOObjectRelease(usbDevice);
        return NULL;
    }

    /* Get device interface */
    res = (*plugInInterface)->QueryInterface(plugInInterface,
                                              CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID),
                                              (LPVOID *)&device->device);
    (*plugInInterface)->Release(plugInInterface);

    if (res != S_OK || device->device == NULL) {
        free(device);
        IOObjectRelease(usbDevice);
        return NULL;
    }

    /* Open the device */
    kr = (*device->device)->USBDeviceOpen(device->device);
    if (kr != KERN_SUCCESS) {
        (*device->device)->Release(device->device);
        free(device);
        IOObjectRelease(usbDevice);
        return NULL;
    }

    /* Configure the device */
    IOUSBConfigurationDescriptorPtr configDesc;
    kr = (*device->device)->GetConfigurationDescriptorPtr(device->device, 0, &configDesc);
    if (kr == KERN_SUCCESS) {
        (*device->device)->SetConfiguration(device->device, configDesc->bConfigurationValue);
    }

    /* Find and open interface */
    IOUSBFindInterfaceRequest request;
    io_iterator_t interfaceIter;
    io_service_t usbInterface;

    request.bInterfaceClass = kIOUSBFindInterfaceDontCare;
    request.bInterfaceSubClass = kIOUSBFindInterfaceDontCare;
    request.bInterfaceProtocol = kIOUSBFindInterfaceDontCare;
    request.bAlternateSetting = kIOUSBFindInterfaceDontCare;

    kr = (*device->device)->CreateInterfaceIterator(device->device, &request, &interfaceIter);
    if (kr == KERN_SUCCESS) {
        usbInterface = IOIteratorNext(interfaceIter);
        if (usbInterface != 0) {
            IOCFPlugInInterface **intfPlugIn;
            kr = IOCreatePlugInInterfaceForService(usbInterface, kIOUSBInterfaceUserClientTypeID,
                                                    kIOCFPlugInInterfaceID, &intfPlugIn, &score);
            if (kr == KERN_SUCCESS && intfPlugIn != NULL) {
                res = (*intfPlugIn)->QueryInterface(intfPlugIn,
                                                     CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID),
                                                     (LPVOID *)&device->interface);
                (*intfPlugIn)->Release(intfPlugIn);

                if (res == S_OK && device->interface != NULL) {
                    (*device->interface)->USBInterfaceOpen(device->interface);

                    /* Find bulk endpoints */
                    UInt8 numEndpoints;
                    (*device->interface)->GetNumEndpoints(device->interface, &numEndpoints);

                    for (UInt8 i = 1; i <= numEndpoints; i++) {
                        UInt8 direction, number, transferType, interval;
                        UInt16 maxPacketSize;

                        (*device->interface)->GetPipeProperties(device->interface, i,
                                                                 &direction, &number, &transferType,
                                                                 &maxPacketSize, &interval);

                        if (transferType == kUSBBulk) {
                            if (direction == kUSBIn) {
                                device->bulkInPipe = i;
                            } else {
                                device->bulkOutPipe = i;
                            }
                        }
                    }
                }
            }
            IOObjectRelease(usbInterface);
        }
        IOObjectRelease(interfaceIter);
    }

    /* Fill device info */
    device->usbDevice = usbDevice;
    device->info.vendorId = vendorId;
    device->info.productId = productId;
    device->info.model = get_model_type(productId);
    device->info.isConnected = true;
    device->info.state = is_bootloader_mode(productId) ? ULS_STATE_BOOTLOADER : ULS_STATE_READY;
    device->isOpen = true;

    return device;
}

/* Open device by serial number */
ULSDevice* uls_open_device_by_serial(const char *serialNumber) {
    ULSDeviceInfo *devices = NULL;
    int count = 0;
    ULSDevice *result = NULL;

    if (uls_find_devices(&devices, &count) == ULS_SUCCESS) {
        for (int i = 0; i < count; i++) {
            if (strcmp(devices[i].serialNumber, serialNumber) == 0) {
                result = uls_open_device(devices[i].vendorId, devices[i].productId);
                break;
            }
        }
        uls_free_device_list(devices, count);
    }

    return result;
}

/* Close device */
void uls_close_device(ULSDevice *device) {
    if (device == NULL) return;

    if (device->interface) {
        (*device->interface)->USBInterfaceClose(device->interface);
        (*device->interface)->Release(device->interface);
    }

    if (device->device) {
        (*device->device)->USBDeviceClose(device->device);
        (*device->device)->Release(device->device);
    }

    if (device->usbDevice) {
        IOObjectRelease(device->usbDevice);
    }

    free(device);
}

/* Bulk write */
ULSError uls_bulk_write(ULSDevice *device, const uint8_t *data, size_t length, size_t *bytesWritten) {
    if (device == NULL || !device->isOpen || device->interface == NULL) {
        return ULS_ERROR_NOT_CONNECTED;
    }

    if (data == NULL || length == 0) {
        return ULS_ERROR_INVALID_PARAM;
    }

    kern_return_t kr;
    UInt32 size = (UInt32)length;

    kr = (*device->interface)->WritePipe(device->interface, device->bulkOutPipe,
                                          (void *)data, size);

    if (kr == KERN_SUCCESS) {
        if (bytesWritten) *bytesWritten = length;
        return ULS_SUCCESS;
    } else if (kr == kIOUSBTransactionTimeout) {
        return ULS_ERROR_TIMEOUT;
    } else {
        return ULS_ERROR_IO;
    }
}

/* Bulk read */
ULSError uls_bulk_read(ULSDevice *device, uint8_t *buffer, size_t bufferSize, size_t *bytesRead) {
    if (device == NULL || !device->isOpen || device->interface == NULL) {
        return ULS_ERROR_NOT_CONNECTED;
    }

    if (buffer == NULL || bufferSize == 0) {
        return ULS_ERROR_INVALID_PARAM;
    }

    kern_return_t kr;
    UInt32 size = (UInt32)bufferSize;

    kr = (*device->interface)->ReadPipe(device->interface, device->bulkInPipe,
                                         buffer, &size);

    if (kr == KERN_SUCCESS) {
        if (bytesRead) *bytesRead = size;
        return ULS_SUCCESS;
    } else if (kr == kIOUSBTransactionTimeout) {
        return ULS_ERROR_TIMEOUT;
    } else {
        return ULS_ERROR_IO;
    }
}

/* Control transfer */
ULSError uls_control_transfer(ULSDevice *device, uint8_t requestType, uint8_t request,
                               uint16_t value, uint16_t index,
                               uint8_t *data, uint16_t length) {
    if (device == NULL || !device->isOpen || device->device == NULL) {
        return ULS_ERROR_NOT_CONNECTED;
    }

    IOUSBDevRequest req;
    kern_return_t kr;

    req.bmRequestType = requestType;
    req.bRequest = request;
    req.wValue = value;
    req.wIndex = index;
    req.wLength = length;
    req.pData = data;

    kr = (*device->device)->DeviceRequest(device->device, &req);

    if (kr == KERN_SUCCESS) {
        return ULS_SUCCESS;
    } else {
        return ULS_ERROR_IO;
    }
}

/* Get device status */
ULSError uls_get_status(ULSDevice *device, ULSDeviceState *state) {
    if (device == NULL || state == NULL) {
        return ULS_ERROR_INVALID_PARAM;
    }

    uint8_t cmd[] = {ULS_CMD_STATUS, 0x00, 0x00, 0x00};
    uint8_t response[64];
    size_t written, read;

    ULSError err = uls_bulk_write(device, cmd, sizeof(cmd), &written);
    if (err != ULS_SUCCESS) return err;

    err = uls_bulk_read(device, response, sizeof(response), &read);
    if (err != ULS_SUCCESS) return err;

    /* Parse status response */
    if (read > 0) {
        switch (response[0]) {
            case 0x00: *state = ULS_STATE_READY; break;
            case 0x01: *state = ULS_STATE_BUSY; break;
            case 0xFF: *state = ULS_STATE_ERROR; break;
            default: *state = ULS_STATE_READY; break;
        }
        device->info.state = *state;
    }

    return ULS_SUCCESS;
}

/* Home the laser head */
ULSError uls_home(ULSDevice *device) {
    if (device == NULL) return ULS_ERROR_INVALID_PARAM;

    uint8_t cmd[] = {ULS_CMD_HOME, 0x00, 0x00, 0x00};
    size_t written;

    return uls_bulk_write(device, cmd, sizeof(cmd), &written);
}

/* Move to position */
ULSError uls_move_to(ULSDevice *device, float x, float y) {
    if (device == NULL) return ULS_ERROR_INVALID_PARAM;

    /* Convert float positions to device units (typically 1000 DPI) */
    int32_t xUnits = (int32_t)(x * 1000.0f);
    int32_t yUnits = (int32_t)(y * 1000.0f);

    uint8_t cmd[12];
    cmd[0] = ULS_CMD_MOVE;
    cmd[1] = 0x00;
    cmd[2] = 0x00;
    cmd[3] = 0x00;
    memcpy(&cmd[4], &xUnits, 4);
    memcpy(&cmd[8], &yUnits, 4);

    size_t written;
    return uls_bulk_write(device, cmd, sizeof(cmd), &written);
}

/* Set laser power */
ULSError uls_set_power(ULSDevice *device, uint8_t power) {
    if (device == NULL) return ULS_ERROR_INVALID_PARAM;
    if (power > 100) power = 100;

    uint8_t cmd[] = {ULS_CMD_SET_POWER, power, 0x00, 0x00};
    size_t written;

    return uls_bulk_write(device, cmd, sizeof(cmd), &written);
}

/* Set speed */
ULSError uls_set_speed(ULSDevice *device, uint8_t speed) {
    if (device == NULL) return ULS_ERROR_INVALID_PARAM;
    if (speed > 100) speed = 100;

    uint8_t cmd[] = {ULS_CMD_SET_SPEED, speed, 0x00, 0x00};
    size_t written;

    return uls_bulk_write(device, cmd, sizeof(cmd), &written);
}

/* Set PPI */
ULSError uls_set_ppi(ULSDevice *device, uint16_t ppi) {
    if (device == NULL) return ULS_ERROR_INVALID_PARAM;

    uint8_t cmd[4];
    cmd[0] = ULS_CMD_SET_PPI;
    cmd[1] = (ppi >> 8) & 0xFF;
    cmd[2] = ppi & 0xFF;
    cmd[3] = 0x00;

    size_t written;
    return uls_bulk_write(device, cmd, sizeof(cmd), &written);
}

/* Turn laser on */
ULSError uls_laser_on(ULSDevice *device) {
    if (device == NULL) return ULS_ERROR_INVALID_PARAM;

    uint8_t cmd[] = {ULS_CMD_LASER_ON, 0x00, 0x00, 0x00};
    size_t written;

    return uls_bulk_write(device, cmd, sizeof(cmd), &written);
}

/* Turn laser off */
ULSError uls_laser_off(ULSDevice *device) {
    if (device == NULL) return ULS_ERROR_INVALID_PARAM;

    uint8_t cmd[] = {ULS_CMD_LASER_OFF, 0x00, 0x00, 0x00};
    size_t written;

    return uls_bulk_write(device, cmd, sizeof(cmd), &written);
}

/* Job control functions */
ULSError uls_start_job(ULSDevice *device) {
    if (device == NULL) return ULS_ERROR_INVALID_PARAM;

    uint8_t cmd[] = {ULS_CMD_START_JOB, 0x00, 0x00, 0x00};
    size_t written;

    return uls_bulk_write(device, cmd, sizeof(cmd), &written);
}

ULSError uls_pause_job(ULSDevice *device) {
    if (device == NULL) return ULS_ERROR_INVALID_PARAM;

    uint8_t cmd[] = {ULS_CMD_PAUSE_JOB, 0x00, 0x00, 0x00};
    size_t written;

    return uls_bulk_write(device, cmd, sizeof(cmd), &written);
}

ULSError uls_resume_job(ULSDevice *device) {
    if (device == NULL) return ULS_ERROR_INVALID_PARAM;

    uint8_t cmd[] = {ULS_CMD_RESUME_JOB, 0x00, 0x00, 0x00};
    size_t written;

    return uls_bulk_write(device, cmd, sizeof(cmd), &written);
}

ULSError uls_stop_job(ULSDevice *device) {
    if (device == NULL) return ULS_ERROR_INVALID_PARAM;

    uint8_t cmd[] = {ULS_CMD_STOP_JOB, 0x00, 0x00, 0x00};
    size_t written;

    return uls_bulk_write(device, cmd, sizeof(cmd), &written);
}

/* Send job data */
ULSError uls_send_job_data(ULSDevice *device, const uint8_t *data, size_t length) {
    if (device == NULL || data == NULL) return ULS_ERROR_INVALID_PARAM;

    size_t offset = 0;
    size_t written;

    while (offset < length) {
        size_t chunkSize = length - offset;
        if (chunkSize > ULS_USB_MAX_TRANSFER_SIZE) {
            chunkSize = ULS_USB_MAX_TRANSFER_SIZE;
        }

        ULSError err = uls_bulk_write(device, data + offset, chunkSize, &written);
        if (err != ULS_SUCCESS) return err;

        offset += written;
    }

    return ULS_SUCCESS;
}

/* Get current position */
ULSError uls_get_position(ULSDevice *device, float *x, float *y, float *z) {
    if (device == NULL) return ULS_ERROR_INVALID_PARAM;

    uint8_t cmd[] = {ULS_CMD_GET_POSITION, 0x00, 0x00, 0x00};
    uint8_t response[16];
    size_t written, read;

    ULSError err = uls_bulk_write(device, cmd, sizeof(cmd), &written);
    if (err != ULS_SUCCESS) return err;

    err = uls_bulk_read(device, response, sizeof(response), &read);
    if (err != ULS_SUCCESS) return err;

    if (read >= 12) {
        int32_t xUnits, yUnits, zUnits;
        memcpy(&xUnits, &response[0], 4);
        memcpy(&yUnits, &response[4], 4);
        memcpy(&zUnits, &response[8], 4);

        if (x) *x = xUnits / 1000.0f;
        if (y) *y = yUnits / 1000.0f;
        if (z) *z = zUnits / 1000.0f;
    }

    return ULS_SUCCESS;
}

/* Get firmware version */
ULSError uls_get_firmware_version(ULSDevice *device, char *version, size_t maxLength) {
    if (device == NULL || version == NULL) return ULS_ERROR_INVALID_PARAM;

    uint8_t cmd[] = {ULS_CMD_FIRMWARE_VERSION, 0x00, 0x00, 0x00};
    uint8_t response[64];
    size_t written, read;

    ULSError err = uls_bulk_write(device, cmd, sizeof(cmd), &written);
    if (err != ULS_SUCCESS) return err;

    err = uls_bulk_read(device, response, sizeof(response), &read);
    if (err != ULS_SUCCESS) return err;

    if (read > 0) {
        size_t copyLen = read < maxLength - 1 ? read : maxLength - 1;
        memcpy(version, response, copyLen);
        version[copyLen] = '\0';
    }

    return ULS_SUCCESS;
}

/* Upload firmware from Intel HEX file */
ULSError uls_upload_firmware(ULSDevice *device, const char *hexFilePath) {
    if (device == NULL || hexFilePath == NULL) {
        return ULS_ERROR_INVALID_PARAM;
    }

    /* Check if device is in bootloader mode */
    if (device->info.state != ULS_STATE_BOOTLOADER) {
        return ULS_ERROR_INVALID_PARAM;
    }

    FILE *file = fopen(hexFilePath, "r");
    if (file == NULL) {
        return ULS_ERROR_IO;
    }

    char line[256];
    uint8_t buffer[ULS_USB_MAX_TRANSFER_SIZE];
    size_t bufferPos = 0;

    while (fgets(line, sizeof(line), file)) {
        /* Skip empty lines and non-record lines */
        if (line[0] != ':') continue;

        /* Parse Intel HEX record */
        int byteCount, address, recordType;
        if (sscanf(line + 1, "%02X%04X%02X", &byteCount, &address, &recordType) != 3) {
            continue;
        }

        /* End of file record */
        if (recordType == 0x01) {
            break;
        }

        /* Data record */
        if (recordType == 0x00) {
            for (int i = 0; i < byteCount && bufferPos < sizeof(buffer); i++) {
                int dataByte;
                if (sscanf(line + 9 + i * 2, "%02X", &dataByte) == 1) {
                    buffer[bufferPos++] = (uint8_t)dataByte;
                }
            }

            /* Send buffer when full */
            if (bufferPos >= ULS_USB_MAX_TRANSFER_SIZE) {
                size_t written;
                ULSError err = uls_bulk_write(device, buffer, bufferPos, &written);
                if (err != ULS_SUCCESS) {
                    fclose(file);
                    return err;
                }
                bufferPos = 0;
            }
        }
    }

    /* Send remaining data */
    if (bufferPos > 0) {
        size_t written;
        ULSError err = uls_bulk_write(device, buffer, bufferPos, &written);
        if (err != ULS_SUCCESS) {
            fclose(file);
            return err;
        }
    }

    fclose(file);
    return ULS_SUCCESS;
}

/* Error string conversion */
const char* uls_error_string(ULSError error) {
    switch (error) {
        case ULS_SUCCESS: return "Success";
        case ULS_ERROR_NOT_FOUND: return "Device not found";
        case ULS_ERROR_ACCESS_DENIED: return "Access denied";
        case ULS_ERROR_BUSY: return "Device busy";
        case ULS_ERROR_TIMEOUT: return "Timeout";
        case ULS_ERROR_IO: return "I/O error";
        case ULS_ERROR_INVALID_PARAM: return "Invalid parameter";
        case ULS_ERROR_NOT_CONNECTED: return "Not connected";
        default: return "Unknown error";
    }
}

/* Model string conversion */
const char* uls_model_string(ULSModelType model) {
    switch (model) {
        case ULS_MODEL_PLS: return "PLS Series";
        case ULS_MODEL_VLS_360: return "VLS 360/460/660";
        case ULS_MODEL_VLS_230: return "VLS 230/350";
        case ULS_MODEL_ILS: return "ILS Series";
        default: return "Unknown";
    }
}

/* State string conversion */
const char* uls_state_string(ULSDeviceState state) {
    switch (state) {
        case ULS_STATE_DISCONNECTED: return "Disconnected";
        case ULS_STATE_BOOTLOADER: return "Bootloader Mode";
        case ULS_STATE_READY: return "Ready";
        case ULS_STATE_BUSY: return "Busy";
        case ULS_STATE_ERROR: return "Error";
        default: return "Unknown";
    }
}

/* Notification thread function */
static void *notification_thread_func(void *arg) {
    gRunLoop = CFRunLoopGetCurrent();
    CFRunLoopAddSource(gRunLoop,
                       IONotificationPortGetRunLoopSource(gNotifyPort),
                       kCFRunLoopDefaultMode);
    CFRunLoopRun();
    return NULL;
}

/* Device added callback */
static void device_added_callback(void *refCon, io_iterator_t iterator) {
    io_service_t usbDevice;
    while ((usbDevice = IOIteratorNext(iterator)) != 0) {
        if (gHotplugCallback) {
            /* Create temporary device for callback */
            CFNumberRef productIdRef = (CFNumberRef)IORegistryEntryCreateCFProperty(
                usbDevice, CFSTR(kUSBProductID), kCFAllocatorDefault, 0);

            if (productIdRef) {
                SInt32 productId;
                CFNumberGetValue(productIdRef, kCFNumberSInt32Type, &productId);
                CFRelease(productIdRef);

                ULSDevice *device = uls_open_device(ULS_USB_VENDOR_ID, productId);
                if (device) {
                    gHotplugCallback(device, true, gHotplugUserContext);
                    /* Note: caller is responsible for closing device */
                }
            }
        }
        IOObjectRelease(usbDevice);
    }
}

/* Device removed callback */
static void device_removed_callback(void *refCon, io_iterator_t iterator) {
    io_service_t usbDevice;
    while ((usbDevice = IOIteratorNext(iterator)) != 0) {
        if (gHotplugCallback) {
            gHotplugCallback(NULL, false, gHotplugUserContext);
        }
        IOObjectRelease(usbDevice);
    }
}

/* Register hotplug callback */
ULSError uls_register_hotplug_callback(ULSDeviceCallback callback, void *userContext) {
    if (gNotificationThreadRunning) {
        return ULS_ERROR_BUSY;
    }

    gHotplugCallback = callback;
    gHotplugUserContext = userContext;

    gNotifyPort = IONotificationPortCreate(kIOMainPortDefault);
    if (gNotifyPort == NULL) {
        return ULS_ERROR_UNKNOWN;
    }

    CFMutableDictionaryRef matchingDict = IOServiceMatching(kIOUSBDeviceClassName);
    CFNumberRef vendorIdRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type,
                                              (int[]){ULS_USB_VENDOR_ID});
    CFDictionarySetValue(matchingDict, CFSTR(kUSBVendorID), vendorIdRef);
    CFRelease(vendorIdRef);

    /* Register for device additions */
    CFRetain(matchingDict); /* Need to retain for second use */
    IOServiceAddMatchingNotification(gNotifyPort, kIOFirstMatchNotification,
                                     matchingDict, device_added_callback, NULL, &gAddedIter);

    /* Register for device removals */
    IOServiceAddMatchingNotification(gNotifyPort, kIOTerminatedNotification,
                                     matchingDict, device_removed_callback, NULL, &gRemovedIter);

    /* Iterate to arm the notifications */
    io_object_t obj;
    while ((obj = IOIteratorNext(gAddedIter)) != 0) {
        IOObjectRelease(obj);
    }
    while ((obj = IOIteratorNext(gRemovedIter)) != 0) {
        IOObjectRelease(obj);
    }

    /* Start notification thread */
    gNotificationThreadRunning = true;
    pthread_create(&gNotificationThread, NULL, notification_thread_func, NULL);

    return ULS_SUCCESS;
}

/* Unregister hotplug callback */
void uls_unregister_hotplug_callback(void) {
    if (!gNotificationThreadRunning) return;

    gNotificationThreadRunning = false;

    if (gRunLoop) {
        CFRunLoopStop(gRunLoop);
    }

    pthread_join(gNotificationThread, NULL);

    if (gAddedIter) {
        IOObjectRelease(gAddedIter);
        gAddedIter = 0;
    }

    if (gRemovedIter) {
        IOObjectRelease(gRemovedIter);
        gRemovedIter = 0;
    }

    if (gNotifyPort) {
        IONotificationPortDestroy(gNotifyPort);
        gNotifyPort = NULL;
    }

    gHotplugCallback = NULL;
    gHotplugUserContext = NULL;
    gRunLoop = NULL;
}
