#ifndef RIGHTCLICK_HOST_FILES_H
#define RIGHTCLICK_HOST_FILES_H
#include <stddef.h>
#include <stdint.h>
/* Host-only implementation. Bytes and security descriptors never enter the ABI. */
int rc_host_read_file(const char *path, uint64_t maximum, int protected_file,
                      unsigned char **bytes, size_t *length);
int rc_host_harden_private(const char *path, int directory);
/* Create new runtime-owned objects with current-user owner and private DACL
   from inception. Existing paths are never adopted or overwritten. */
int rc_host_create_private_directory(const char *path);
int rc_host_create_private_file(const char *path, const unsigned char *bytes, size_t length);
int rc_host_release_snapshot(const char *path);
/* Thread-local broken-pipe containment for native Linux child stdin. */
int rc_host_write_pipe(int32_t descriptor, const unsigned char *bytes, size_t length);
void rc_host_free(void *value);
#endif
