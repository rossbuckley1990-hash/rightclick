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
/* Mutable client config uses owner-only ACLs at CREATE_NEW, unlike immutable
   runtime snapshots. No credentials are returned in errors. */
int rc_host_write_private_config(const char *path, const unsigned char *bytes, size_t length);
int rc_host_replace_config(const char *source, const char *destination);
/* Trusted native CLI process group. argv/environment are null-terminated;
   a null environment inherits the user's native-client environment. Poll never
   reaps, retaining PID/group ownership until dispose terminates and reaps. */
int rc_host_spawn_client(const char *executable, const char *const *argv,
    const char *const *environment, int input_pipe, int merge_error,
    int32_t *pid, int32_t *input_descriptor, int32_t *output_descriptor);
int rc_host_poll_client(int32_t pid, int32_t *status);
int rc_host_dispose_client(int32_t pid);
/* Thread-local broken-pipe containment for native Linux child stdin. */
int rc_host_write_pipe(int32_t descriptor, const unsigned char *bytes, size_t length);
void rc_host_free(void *value);
#endif
