#ifndef RIGHTCLICK_HOST_FILES_H
#define RIGHTCLICK_HOST_FILES_H
#include <stddef.h>
#include <stdint.h>
/* Host-only implementation. Bytes and security descriptors never enter the ABI. */
int rc_host_read_file(const char *path, uint64_t maximum, int protected_file,
                      unsigned char **bytes, size_t *length);
int rc_host_harden_private(const char *path, int directory);
int rc_host_release_snapshot(const char *path);
void rc_host_free(void *value);
#endif
