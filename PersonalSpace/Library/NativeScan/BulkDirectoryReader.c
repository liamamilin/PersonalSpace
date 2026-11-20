/* Adapted from Oil Find's sift_read_dir, commit
 * 8f7b9db9e9785eb0a75746fa7f3c66fd47aae6c8, Sources/COilFind/coilfind.c.
 * Copyright (c) 2026 Lin Zhihuang. MIT; see THIRD_PARTY_NOTICES.md.
 * PersonalSpace: nanosecond/creation dates, Finder hidden flags, bounds checks,
 * required-attribute fallback, and a persistent readdir fallback for other volumes. */
#include "BulkDirectoryReader.h"
#include <sys/attr.h>
#include <sys/stat.h>
#include <sys/vnode.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

struct ps_directory_reader { int fd; int count_only; DIR *fallback; struct dirent *pending; };
static size_t align4(size_t size) { return (size + 3) & ~(size_t)3; }
static void from_stat(ps_scan_entry *entry, const struct stat *value) {
    entry->type = S_ISDIR(value->st_mode) ? 1 : S_ISLNK(value->st_mode) ? 2 : S_ISREG(value->st_mode) ? 0 : 3;
    entry->dev = value->st_dev; entry->inode = value->st_ino; entry->flags = value->st_flags;
    entry->size = value->st_size;
    entry->modified_seconds = value->st_mtimespec.tv_sec;
    entry->modified_nanoseconds = value->st_mtimespec.tv_nsec;
    entry->created_seconds = value->st_birthtimespec.tv_sec;
    entry->created_nanoseconds = value->st_birthtimespec.tv_nsec;
    entry->needs_hidden_check = 1; /* stat does not include Finder invisible flags */
}
static int enable_fallback(ps_directory_reader *reader) {
    int duplicate = dup(reader->fd);
    if (duplicate < 0) return -1;
    reader->fallback = fdopendir(duplicate);
    if (!reader->fallback) { int saved = errno; close(duplicate); errno = saved; return -1; }
    return 0;
}
ps_directory_reader *ps_directory_reader_create(int fd, int prefer_bulk, int count_only) {
    ps_directory_reader *reader = calloc(1, sizeof(*reader));
    if (reader) {
        reader->fd = fd;
        reader->count_only = count_only;
        if (!prefer_bulk && enable_fallback(reader) != 0) { free(reader); return NULL; }
    }
    return reader;
}
void ps_directory_reader_destroy(ps_directory_reader *reader) {
    if (reader->fallback) closedir(reader->fallback);
    free(reader);
}
static int fallback_next(ps_directory_reader *reader, void *scratch, size_t size, ps_scan_entry *out, int capacity) {
    size_t used = 0; int count = 0;
    while (count < capacity) {
        errno = 0;
        /* readdir owns this pointer until its next call. Retain an entry that
         * did not fit instead of relying on seekdir support on remote volumes. */
        struct dirent *item = reader->pending ? reader->pending : readdir(reader->fallback);
        reader->pending = NULL;
        if (!item) return errno ? -1 : count;
        size_t length = strlen(item->d_name) + 1;
        if (length > size) { errno = ENAMETOOLONG; return -1; }
        if (length > size - used) { reader->pending = item; break; }
        ps_scan_entry entry = {0}; entry.type = 3;
        entry.name = (char *)scratch + used;
        memcpy((char *)scratch + used, item->d_name, length); used += length;
        struct stat value;
        if (fstatat(reader->fd, entry.name, &value, AT_SYMLINK_NOFOLLOW) != 0) entry.error = errno;
        else from_stat(&entry, &value);
        out[count++] = entry;
    }
    return count;
}
int ps_directory_reader_next(ps_directory_reader *reader, void *scratch, size_t size, ps_scan_entry *out, int capacity) {
    if (reader->fallback) return fallback_next(reader, scratch, size, out, capacity);
    struct attrlist attributes = {0}; attributes.bitmapcount = ATTR_BIT_MAP_COUNT;
    attributes.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_ERROR | ATTR_CMN_NAME | ATTR_CMN_DEVID |
        ATTR_CMN_OBJTYPE | ATTR_CMN_FNDRINFO | ATTR_CMN_FLAGS | ATTR_CMN_FILEID;
    if (!reader->count_only) {
        attributes.commonattr |= ATTR_CMN_CRTIME | ATTR_CMN_MODTIME;
        attributes.fileattr = ATTR_FILE_DATALENGTH;
    }
    int count;
    do { count = getattrlistbulk(reader->fd, &attributes, scratch, size, 0); } while (count < 0 && errno == EINTR);
    if (count < 0 && (errno == ENOTSUP || errno == EINVAL || errno == ENOSYS)) {
        if (enable_fallback(reader) != 0) return -1;
        return fallback_next(reader, scratch, size, out, capacity);
    }
    if (count <= 0) return count;
    if (count > capacity) { errno = ENOBUFS; return -1; }
    uint8_t *cursor = scratch, *limit = cursor + size;
    for (int index = 0; index < count; index++) {
        if ((size_t)(limit - cursor) < 4) { errno = EIO; return -1; }
        uint32_t length; memcpy(&length, cursor, 4);
        if (length < 8 || length > (size_t)(limit - cursor)) { errno = EIO; return -1; }
        uint8_t *end = cursor + length, *position = cursor + 4;
        attribute_set_t returned;
        if (sizeof(returned) > (size_t)(end - position)) { errno = EIO; return -1; }
        memcpy(&returned, position, sizeof(returned)); position += sizeof(returned);
        ps_scan_entry entry = {0}; entry.type = 3;
#define TAKE(destination, bytes) do { size_t amount = align4(bytes); if (amount > (size_t)(end-position)) { errno=EIO; return -1; } memcpy(&(destination),position,bytes); position+=amount; } while(0)
        if (returned.commonattr & ATTR_CMN_ERROR) TAKE(entry.error, sizeof(int32_t));
        if (returned.commonattr & ATTR_CMN_NAME) {
            attrreference_t reference; uint8_t *reference_position = position;
            TAKE(reference, sizeof(reference));
            if (reference.attr_dataoffset < 0 || (size_t)reference.attr_dataoffset >= (size_t)(end-reference_position)) { errno=EIO; return -1; }
            const char *name = (const char *)reference_position + reference.attr_dataoffset;
            if (reference.attr_length == 0 || reference.attr_length > (size_t)(end-(const uint8_t *)name) ||
                name[reference.attr_length-1] != '\0') { errno=EIO; return -1; }
            entry.name = name;
        }
        if (!entry.name) { errno=EIO; return -1; }
        if (returned.commonattr & ATTR_CMN_DEVID) TAKE(entry.dev, sizeof(dev_t));
        if (returned.commonattr & ATTR_CMN_OBJTYPE) {
            fsobj_type_t type; TAKE(type, sizeof(type)); entry.type = type == VDIR ? 1 : type == VLNK ? 2 : type == VREG ? 0 : 3;
        }
        if (returned.commonattr & ATTR_CMN_CRTIME) {
            struct timespec date; TAKE(date, sizeof(date)); entry.created_seconds=date.tv_sec; entry.created_nanoseconds=date.tv_nsec;
        }
        if (returned.commonattr & ATTR_CMN_MODTIME) {
            struct timespec date; TAKE(date, sizeof(date)); entry.modified_seconds=date.tv_sec; entry.modified_nanoseconds=date.tv_nsec;
        }
        if (returned.commonattr & ATTR_CMN_FNDRINFO) {
            uint8_t finder[32]; TAKE(finder, sizeof(finder));
            if ((((uint16_t)finder[8] << 8) | finder[9]) & 0x4000) entry.flags |= UF_HIDDEN;
        } else entry.needs_hidden_check = 1;
        uint32_t hidden = entry.flags;
        if (returned.commonattr & ATTR_CMN_FLAGS) TAKE(entry.flags, sizeof(uint32_t));
        entry.flags |= hidden;
        if (returned.commonattr & ATTR_CMN_FILEID) TAKE(entry.inode, sizeof(uint64_t));
        if (returned.fileattr & ATTR_FILE_DATALENGTH) TAKE(entry.size, sizeof(uint64_t));
#undef TAKE
        uint32_t required = ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_FLAGS | ATTR_CMN_FILEID;
        if (!reader->count_only) required |= ATTR_CMN_CRTIME | ATTR_CMN_MODTIME;
        if (!entry.error && ((returned.commonattr & required) != required ||
            (!reader->count_only && entry.type == 0 && !(returned.fileattr & ATTR_FILE_DATALENGTH)) || (entry.flags & SF_FIRMLINK))) {
            struct stat value;
            if (fstatat(reader->fd, entry.name, &value, AT_SYMLINK_NOFOLLOW) != 0) entry.error=errno;
            else { from_stat(&entry, &value); entry.flags |= hidden; }
        }
        out[index] = entry; cursor=end;
    }
    return count;
}
