// ecmem: read the Intel NUC EC shared-memory window, or write one byte of
// fan record 1. Uncached mmap of /dev/mem (O_SYNC).
//
//   ecmem read
//   ecmem write <offset> <expected-old> <new>   (offset 0x80..0x8d only)
//
// Values are hex or decimal (strtoul base 0). Refuses unless the EC ID is
// "NUC_EC" and the current byte equals <expected-old>.
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define EC_PAGE   0xFE410000UL
#define EC_WIN    0x400
#define EC_LEN    0x100
#define WR_FIRST  0x80
#define WR_LAST   0x8d

static int parse(const char *s, unsigned long max, unsigned long *out) {
    char *end;
    unsigned long v = strtoul(s, &end, 0);
    if (*s == '\0' || *end != '\0' || v > max) return -1;
    *out = v;
    return 0;
}

int main(int argc, char **argv) {
    int writing = argc == 5 && strcmp(argv[1], "write") == 0;
    if (!(argc == 2 && strcmp(argv[1], "read") == 0) && !writing) {
        fprintf(stderr, "usage: ecmem read | ecmem write <off> <old> <new>\n");
        return 2;
    }
    unsigned long off = 0, old = 0, val = 0;
    if (writing && (parse(argv[2], WR_LAST, &off) || off < WR_FIRST ||
                    parse(argv[3], 0xff, &old) || parse(argv[4], 0xff, &val))) {
        fprintf(stderr, "refused: offset must be 0x%x..0x%x, bytes 0..0xff\n", WR_FIRST, WR_LAST);
        return 2;
    }

    int fd = open("/dev/mem", (writing ? O_RDWR : O_RDONLY) | O_SYNC);
    if (fd < 0) { perror("open /dev/mem"); return 1; }
    long pg = sysconf(_SC_PAGESIZE);
    volatile uint8_t *base = mmap(NULL, pg, writing ? PROT_READ | PROT_WRITE : PROT_READ,
                                  MAP_SHARED, fd, EC_PAGE);
    if (base == MAP_FAILED) { perror("mmap"); return 1; }
    volatile uint8_t *win = base + EC_WIN;

    char id[7];
    for (int i = 0; i < 6; i++) id[i] = (char)win[i];
    id[6] = '\0';
    if (strcmp(id, "NUC_EC") != 0) {
        fprintf(stderr, "refused: EC id is not NUC_EC\n");
        return 3;
    }

    if (!writing) {
        for (int i = 0; i < EC_LEN; i++)
            printf("%02x%c", win[i], (i % 16 == 15) ? '\n' : ' ');
        return 0;
    }

    uint8_t cur = win[off];
    if (cur != old) {
        fprintf(stderr, "refused: byte 0x%lx is 0x%02x, expected 0x%02lx\n", off, cur, old);
        return 4;
    }
    win[off] = (uint8_t)val;
    uint8_t now = win[off];
    printf("0x%lx: 0x%02x -> 0x%02x (readback 0x%02x)\n", off, cur, (unsigned)val, now);
    return now == val ? 0 : 5;
}
