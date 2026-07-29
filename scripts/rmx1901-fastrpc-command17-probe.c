// SPDX-License-Identifier: MIT
// Device-local RMX1901 FastRPC command-17 ABI and postcondition probe.
#include <errno.h>
#include <fcntl.h>
#include <linux/ioctl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define FASTRPC_IOCTL_GETINFO _IOWR('R', 8, uint32_t)

struct fastrpc_ioctl_capability {
    uint32_t domain;
    uint32_t attribute_ID;
    uint32_t capability;
};

#define FASTRPC_IOCTL_GET_DSP_CAPABILITY \
    _IOWR('R', 17, struct fastrpc_ioctl_capability)
#define CAPABILITY_SENTINEL UINT32_C(0xa5a5a5a5)
#define NUM_DOMAINS 4U
#define NUM_ATTRIBUTES 258U

static int query_capability(int fd, uint32_t domain, uint32_t attribute,
                            uint32_t *result) {
    struct fastrpc_ioctl_capability query = {
        .domain = domain,
        .attribute_ID = attribute,
        .capability = CAPABILITY_SENTINEL,
    };
    int rc;
    int saved_errno;

    errno = 0;
    rc = ioctl(fd, FASTRPC_IOCTL_GET_DSP_CAPABILITY, &query);
    saved_errno = errno;
    printf("query domain=%u attribute=0x%03x rc=%d errno=%d capability=0x%08x\n",
           domain, attribute, rc, saved_errno, query.capability);
    if (result != NULL)
        *result = query.capability;
    errno = saved_errno;
    return rc;
}

static int parse_domain(const char *text, uint32_t *domain) {
    char *end = NULL;
    unsigned long value;

    errno = 0;
    value = strtoul(text, &end, 0);
    if (errno != 0 || end == text || *end != '\0' || value >= NUM_DOMAINS)
        return -1;
    *domain = (uint32_t)value;
    return 0;
}

int main(int argc, char **argv) {
    const char *device = "/dev/adsprpc-smd";
    uint32_t domain = 0;
    const uint32_t attributes[] = {0x80U, 0x100U, 0x101U};
    uint32_t first[sizeof(attributes) / sizeof(attributes[0])] = {0};
    uint32_t second[sizeof(attributes) / sizeof(attributes[0])] = {0};
    uint32_t info;
    uint32_t rejected;
    int failures = 0;
    int fd;
    size_t i;

    if (argc > 1)
        device = argv[1];
    if (argc > 2 && parse_domain(argv[2], &domain) != 0) {
        fprintf(stderr, "invalid domain: %s\n", argv[2]);
        return 2;
    }
    if (argc > 3) {
        fprintf(stderr, "usage: %s [device [domain]]\n", argv[0]);
        return 2;
    }

    printf("uapi getinfo=0x%08lx command17=0x%08lx struct_size=%zu\n",
           (unsigned long)FASTRPC_IOCTL_GETINFO,
           (unsigned long)FASTRPC_IOCTL_GET_DSP_CAPABILITY,
           sizeof(struct fastrpc_ioctl_capability));
    if ((unsigned long)FASTRPC_IOCTL_GETINFO != 0xc0045208UL ||
        (unsigned long)FASTRPC_IOCTL_GET_DSP_CAPABILITY != 0xc00c5211UL ||
        sizeof(struct fastrpc_ioctl_capability) != 12U) {
        fprintf(stderr, "compiled UAPI constants do not match RMX1901 contract\n");
        return 1;
    }

    fd = open(device, O_RDWR | O_CLOEXEC);
    if (fd < 0) {
        fprintf(stderr, "open device=%s failed errno=%d (%s)\n",
                device, errno, strerror(errno));
        return 1;
    }

    info = domain;
    errno = 0;
    if (ioctl(fd, FASTRPC_IOCTL_GETINFO, &info) != 0) {
        fprintf(stderr, "GETINFO domain=%u failed errno=%d (%s)\n",
                domain, errno, strerror(errno));
        close(fd);
        return 1;
    }
    printf("getinfo domain=%u rc=0 smmu=%u\n", domain, info);

    for (i = 0; i < sizeof(attributes) / sizeof(attributes[0]); ++i) {
        if (query_capability(fd, domain, attributes[i], &first[i]) != 0)
            ++failures;
    }
    for (i = 0; i < sizeof(attributes) / sizeof(attributes[0]); ++i) {
        if (query_capability(fd, domain, attributes[i], &second[i]) != 0)
            ++failures;
        if (first[i] != second[i]) {
            fprintf(stderr, "unstable capability attribute=0x%03x first=0x%08x second=0x%08x\n",
                    attributes[i], first[i], second[i]);
            ++failures;
        }
    }

    if (first[0] == CAPABILITY_SENTINEL) {
        fprintf(stderr, "DSP attribute 0x080 was not copied back\n");
        ++failures;
    }
    if (first[1] != 2U) {
        fprintf(stderr, "kernel attribute 0x100 expected 2, got %u\n", first[1]);
        ++failures;
    }
    if (first[2] != 1U) {
        fprintf(stderr, "kernel attribute 0x101 expected 1, got %u\n", first[2]);
        ++failures;
    }

    errno = 0;
    if (query_capability(fd, (domain + 1U) % NUM_DOMAINS, 0x100U, &rejected) != -1 ||
        errno != EINVAL) {
        fprintf(stderr, "cross-domain query was not rejected with EINVAL\n");
        ++failures;
    }
    errno = 0;
    if (query_capability(fd, domain, NUM_ATTRIBUTES, &rejected) != -1 ||
        errno != EOVERFLOW) {
        fprintf(stderr, "out-of-range attribute was not rejected with EOVERFLOW\n");
        ++failures;
    }

    close(fd);
    if (failures != 0) {
        printf("overall=FAIL failures=%d\n", failures);
        return 1;
    }
    printf("overall=PASS\n");
    return 0;
}
