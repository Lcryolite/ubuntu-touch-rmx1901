#include <libusb-1.0/libusb.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

struct sahara_packet {
    uint32_t command;
    uint32_t length;
};


struct sahara_hello {
    uint32_t command;
    uint32_t length;
    uint32_t version;
    uint32_t compatible_version;
    uint32_t max_packet_length;
    uint32_t mode;
    uint32_t reserved[6];
};

int main(void)
{
    libusb_context *context = NULL;
    libusb_device **devices = NULL;
    libusb_device_handle *handle = NULL;
    struct sahara_hello hello = { 0 };
    struct sahara_packet packet = { 7, 8 };
    struct sahara_packet response = { 0, 0 };
    ssize_t count;
    int matches = 0;
    int transferred = 0;
    int result = 1;

    if (libusb_init(&context) != 0)
        goto out;
    count = libusb_get_device_list(context, &devices);
    if (count < 0)
        goto out;

    for (ssize_t index = 0; index < count; index++) {
        struct libusb_device_descriptor descriptor;
        if (libusb_get_device_descriptor(devices[index], &descriptor) != 0)
            continue;
        if (descriptor.idVendor == 0x05c6 && descriptor.idProduct == 0x900e) {
            matches++;
            if (matches == 1)
                handle = libusb_open_device_with_vid_pid(context, 0x05c6, 0x900e);
        }
    }
    if (matches != 1 || handle == NULL) {
        fprintf(stderr, "expected exactly one 05c6:900e device, found %d\n", matches);
        goto out;
    }
    if (libusb_claim_interface(handle, 0) != 0) {
        fprintf(stderr, "failed to claim Sahara USB interface\n");
        goto out;
    }


    if (libusb_bulk_transfer(handle, 0x81, (unsigned char *)&hello,
                            sizeof(hello), &transferred, 5000) != 0 ||
        transferred != (int)sizeof(hello) ||
        hello.command != 1 || hello.length != sizeof(hello)) {
        fprintf(stderr, "failed to receive valid Sahara hello packet\n");
        goto release;
    }
    fprintf(stdout, "sahara_hello_received=48\n");
    transferred = 0;
    if (libusb_bulk_transfer(handle, 0x01, (unsigned char *)&packet,
                            sizeof(packet), &transferred, 5000) != 0 ||
        transferred != (int)sizeof(packet)) {
        fprintf(stderr, "failed to send complete Sahara reset packet\n");
        goto release;
    }
    fprintf(stdout, "sahara_reset_sent=8\n");

    transferred = 0;
    int read_status = libusb_bulk_transfer(handle, 0x81,
                                           (unsigned char *)&response,
                                           sizeof(response), &transferred, 5000);
    if (read_status == LIBUSB_ERROR_NO_DEVICE) {
        fprintf(stdout, "sahara_reset_result=device_disconnected\n");
        result = 0;
    } else if (read_status == 0 && transferred == (int)sizeof(response) &&
               response.command == 8 && response.length == 8) {
        fprintf(stdout, "sahara_reset_result=response_received\n");
        result = 0;
    } else {
        fprintf(stderr, "reset sent but no valid reset response (status=%d bytes=%d)\n",
                read_status, transferred);
    }

release:
    libusb_release_interface(handle, 0);
out:
    if (handle != NULL)
        libusb_close(handle);
    if (devices != NULL)
        libusb_free_device_list(devices, 1);
    if (context != NULL)
        libusb_exit(context);
    return result;
}
