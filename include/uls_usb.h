/*
 * ULS (Universal Laser Systems) USB Communication Header
 * macOS Driver Implementation
 *
 * Based on reverse engineering of Windows driver ucpinst-5.38.58.00.exe
 * For educational and research purposes.
 */

#ifndef ULS_USB_H
#define ULS_USB_H

#include <IOKit/usb/IOUSBLib.h>
#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>
#include <stdbool.h>

/* USB Vendor and Product IDs for ULS devices */
#define ULS_USB_VENDOR_ID           0x10C3

/* PLS Series (Platform Laser System) */
#define ULS_PID_PLS_BOOTLOADER      0x00A4
#define ULS_PID_PLS_PRINT           0x00A5

/* VLS 360/460/660 Series */
#define ULS_PID_VLS_360_BOOTLOADER  0x00B4
#define ULS_PID_VLS_360_PRINT       0x00B5

/* ILS Series (Industrial Laser System) */
#define ULS_PID_ILS_BOOTLOADER      0x00C4
#define ULS_PID_ILS_PRINT           0x00C5

/* VLS 230/350 Series */
#define ULS_PID_VLS_230_BOOTLOADER  0x00E4
#define ULS_PID_VLS_230_PRINT       0x00E5

/* USB Transfer Settings */
#define ULS_USB_TIMEOUT_MS          5000
#define ULS_USB_MAX_TRANSFER_SIZE   4096
#define ULS_USB_BULK_EP_OUT         0x02
#define ULS_USB_BULK_EP_IN          0x81

/* Device States */
typedef enum {
    ULS_STATE_DISCONNECTED = 0,
    ULS_STATE_BOOTLOADER,
    ULS_STATE_READY,
    ULS_STATE_BUSY,
    ULS_STATE_ERROR
} ULSDeviceState;

/* Device Model Types */
typedef enum {
    ULS_MODEL_UNKNOWN = 0,
    ULS_MODEL_PLS,          /* PLS 3.50, 4.60, 4.75, 6.60, 6.75, 6.120, 6.150 */
    ULS_MODEL_VLS_360,      /* VLS 360, 460, 660 */
    ULS_MODEL_VLS_230,      /* VLS 230, 350 */
    ULS_MODEL_ILS           /* ILS 9.75, 9.150, 12.75, 12.150 */
} ULSModelType;

/* Device Information Structure */
typedef struct {
    uint16_t vendorId;
    uint16_t productId;
    char serialNumber[256];
    char firmwareVersion[32];
    ULSModelType model;
    ULSDeviceState state;
    bool isConnected;
} ULSDeviceInfo;

/* USB Device Handle */
typedef struct {
    IOUSBDeviceInterface **device;
    IOUSBInterfaceInterface **interface;
    io_service_t usbDevice;
    ULSDeviceInfo info;
    uint8_t bulkOutPipe;
    uint8_t bulkInPipe;
    bool isOpen;
} ULSDevice;

/* Laser Command Types */
typedef enum {
    ULS_CMD_STATUS = 0x01,
    ULS_CMD_HOME = 0x02,
    ULS_CMD_MOVE = 0x03,
    ULS_CMD_LASER_ON = 0x04,
    ULS_CMD_LASER_OFF = 0x05,
    ULS_CMD_SET_POWER = 0x06,
    ULS_CMD_SET_SPEED = 0x07,
    ULS_CMD_SET_PPI = 0x08,
    ULS_CMD_START_JOB = 0x10,
    ULS_CMD_PAUSE_JOB = 0x11,
    ULS_CMD_RESUME_JOB = 0x12,
    ULS_CMD_STOP_JOB = 0x13,
    ULS_CMD_GET_POSITION = 0x20,
    ULS_CMD_FIRMWARE_VERSION = 0x30,
    ULS_CMD_FIRMWARE_UPDATE = 0x40
} ULSCommandType;

/* Error Codes */
typedef enum {
    ULS_SUCCESS = 0,
    ULS_ERROR_NOT_FOUND = -1,
    ULS_ERROR_ACCESS_DENIED = -2,
    ULS_ERROR_BUSY = -3,
    ULS_ERROR_TIMEOUT = -4,
    ULS_ERROR_IO = -5,
    ULS_ERROR_INVALID_PARAM = -6,
    ULS_ERROR_NOT_CONNECTED = -7,
    ULS_ERROR_UNKNOWN = -100
} ULSError;

/* Function Prototypes */

/* Device Discovery and Connection */
ULSError uls_find_devices(ULSDeviceInfo **devices, int *count);
void uls_free_device_list(ULSDeviceInfo *devices, int count);

ULSDevice* uls_open_device(uint16_t vendorId, uint16_t productId);
ULSDevice* uls_open_device_by_serial(const char *serialNumber);
void uls_close_device(ULSDevice *device);

/* USB Communication */
ULSError uls_bulk_write(ULSDevice *device, const uint8_t *data, size_t length, size_t *bytesWritten);
ULSError uls_bulk_read(ULSDevice *device, uint8_t *buffer, size_t bufferSize, size_t *bytesRead);
ULSError uls_control_transfer(ULSDevice *device, uint8_t requestType, uint8_t request,
                               uint16_t value, uint16_t index,
                               uint8_t *data, uint16_t length);

/* Device Commands */
ULSError uls_get_status(ULSDevice *device, ULSDeviceState *state);
ULSError uls_home(ULSDevice *device);
ULSError uls_move_to(ULSDevice *device, float x, float y);
ULSError uls_set_power(ULSDevice *device, uint8_t power); /* 0-100 */
ULSError uls_set_speed(ULSDevice *device, uint8_t speed); /* 0-100 */
ULSError uls_set_ppi(ULSDevice *device, uint16_t ppi);
ULSError uls_laser_on(ULSDevice *device);
ULSError uls_laser_off(ULSDevice *device);

/* Job Control */
ULSError uls_start_job(ULSDevice *device);
ULSError uls_pause_job(ULSDevice *device);
ULSError uls_resume_job(ULSDevice *device);
ULSError uls_stop_job(ULSDevice *device);
ULSError uls_send_job_data(ULSDevice *device, const uint8_t *data, size_t length);

/* Position and Status */
ULSError uls_get_position(ULSDevice *device, float *x, float *y, float *z);
ULSError uls_get_firmware_version(ULSDevice *device, char *version, size_t maxLength);

/* Firmware Update (for bootloader mode) */
ULSError uls_upload_firmware(ULSDevice *device, const char *hexFilePath);

/* Utility Functions */
const char* uls_error_string(ULSError error);
const char* uls_model_string(ULSModelType model);
const char* uls_state_string(ULSDeviceState state);

/* Callback for device hotplug events */
typedef void (*ULSDeviceCallback)(ULSDevice *device, bool connected, void *userContext);
ULSError uls_register_hotplug_callback(ULSDeviceCallback callback, void *userContext);
void uls_unregister_hotplug_callback(void);

#endif /* ULS_USB_H */
