/* Derived from Oil Find (MIT), Copyright (c) 2026 Lin Zhihuang.
 * See THIRD_PARTY_NOTICES.md. PersonalSpace adaptations preserve subsecond dates,
 * creation dates, hidden flags, and support descriptor-based fallback traversal. */
#ifndef PS_BULK_DIRECTORY_READER_H
#define PS_BULK_DIRECTORY_READER_H
#include <stddef.h>
#include <stdint.h>
typedef struct {
    const char *name;
    uint32_t type; /* 0 regular, 1 directory, 2 symlink, 3 other */
    uint32_t flags, needs_hidden_check;
    int32_t dev, error;
    uint64_t inode, size;
    int64_t modified_seconds, modified_nanoseconds;
    int64_t created_seconds, created_nanoseconds;
} ps_scan_entry;
typedef struct ps_directory_reader ps_directory_reader;
/* The caller retains ownership of fd. Entry names live until the next read. */
/* prefer_bulk=0 also permits correctness testing of the unsupported-volume path. */
/* count_only omits size/date attributes; visibility and directory identity stay checked. */
ps_directory_reader *ps_directory_reader_create(int fd, int prefer_bulk, int count_only);
int ps_directory_reader_next(ps_directory_reader *, void *scratch, size_t scratch_size,
                             ps_scan_entry *entries, int capacity);
void ps_directory_reader_destroy(ps_directory_reader *);
#endif
