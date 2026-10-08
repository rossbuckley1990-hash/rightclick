#include "RightClickHostFiles.h"
#include <stdlib.h>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <aclapi.h>
#include <wchar.h>

static WCHAR *wide_path(const char *path) {
    if (!path) return NULL;
    int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, NULL, 0);
    if (length < 2 || length > 32768) return NULL;
    WCHAR *result = calloc((size_t)length, sizeof(WCHAR));
    if (!result || !MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, result, length)) {
        free(result); return NULL;
    }
    return result;
}

static TOKEN_USER *current_user(void) {
    HANDLE token = NULL;
    DWORD length = 0;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return NULL;
    GetTokenInformation(token, TokenUser, NULL, 0, &length);
    if (!length || length > 65536) { CloseHandle(token); return NULL; }
    TOKEN_USER *user = malloc(length);
    if (!user || !GetTokenInformation(token, TokenUser, user, length, &length)) {
        free(user); user = NULL;
    }
    CloseHandle(token);
    return user;
}

static int same_final_path(HANDLE file, const WCHAR *path) {
    WCHAR expected[32768], actual[32768];
    DWORD e = GetFullPathNameW(path, 32768, expected, NULL);
    DWORD a = GetFinalPathNameByHandleW(file, actual, 32768, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
    if (!e || e >= 32768 || !a || a >= 32768) return 0;
    /* Windows TEMP may contain a legitimate 8.3 parent name. Expand lexical
       component names, then still compare against the independently opened
       final handle path; a junction/symlink target is not the selected path. */
    DWORD l = GetLongPathNameW(expected, expected, 32768);
    if (!l || l >= 32768) return 0;
    /* A final handle must refer to the exact selected path, including parents. */
    if (wcsncmp(actual, L"\\\\?\\UNC\\", 8) == 0) {
        WCHAR unc[32768] = L"\\\\";
        if (wcslen(actual + 8) + 3 >= 32768) return 0;
        wcscat(unc, actual + 8);
        return _wcsicmp(expected, unc) == 0;
    }
    return _wcsicmp(expected, wcsncmp(actual, L"\\\\?\\", 4) == 0 ? actual + 4 : actual) == 0;
}

static int current_owner(HANDLE file, TOKEN_USER *user) {
    PSID owner = NULL;
    PSECURITY_DESCRIPTOR descriptor = NULL;
    int result = GetSecurityInfo(file, SE_FILE_OBJECT, OWNER_SECURITY_INFORMATION,
        &owner, NULL, NULL, NULL, &descriptor) == ERROR_SUCCESS &&
        owner && IsValidSid(owner) && EqualSid(owner, user->User.Sid);
    if (descriptor) LocalFree(descriptor);
    return result;
}

static int set_readonly(HANDLE file, int readonly) {
    FILE_BASIC_INFO information;
    if (!GetFileInformationByHandleEx(file, FileBasicInfo, &information, sizeof(information))) return 0;
    if (readonly) {
        information.FileAttributes &= ~FILE_ATTRIBUTE_NORMAL;
        information.FileAttributes |= FILE_ATTRIBUTE_READONLY;
    } else {
        information.FileAttributes &= ~FILE_ATTRIBUTE_READONLY;
        if (!information.FileAttributes) information.FileAttributes = FILE_ATTRIBUTE_NORMAL;
    }
    return SetFileInformationByHandle(file, FileBasicInfo, &information, sizeof(information)) != 0;
}

static int protected_authority(HANDLE file) {
    TOKEN_USER *user = current_user();
    if (!user) return 0;
    PSID owner = NULL;
    PACL acl = NULL;
    PSECURITY_DESCRIPTOR descriptor = NULL;
    int permitted = 0;
    if (GetSecurityInfo(file, SE_FILE_OBJECT, OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
                        &owner, NULL, &acl, NULL, &descriptor) != ERROR_SUCCESS) goto done;
    if (!owner || !IsValidSid(owner) || !EqualSid(owner, user->User.Sid) || !acl || !IsValidAcl(acl)) goto done;
    ACL_SIZE_INFORMATION information;
    if (!GetAclInformation(acl, &information, sizeof(information), AclSizeInformation) ||
        information.AceCount > 128 || information.AclBytesInUse > 32768) goto done;
    BYTE system[SECURITY_MAX_SID_SIZE], administrators[SECURITY_MAX_SID_SIZE];
    DWORD system_length = sizeof(system), administrators_length = sizeof(administrators);
    if (!CreateWellKnownSid(WinLocalSystemSid, NULL, system, &system_length) ||
        !CreateWellKnownSid(WinBuiltinAdministratorsSid, NULL, administrators, &administrators_length)) goto done;
    for (DWORD i = 0; i < information.AceCount; ++i) {
        void *raw = NULL;
        if (!GetAce(acl, i, &raw)) goto done;
        ACE_HEADER *header = raw;
        if (header->AceFlags & INHERIT_ONLY_ACE) continue;
        if (header->AceType == ACCESS_DENIED_ACE_TYPE) continue;
        /* Object/callback/conditional grants require a future explicit backend. */
        if (header->AceType != ACCESS_ALLOWED_ACE_TYPE || header->AceSize < sizeof(ACCESS_ALLOWED_ACE)) goto done;
        ACCESS_ALLOWED_ACE *ace = raw;
        PSID sid = (PSID)&ace->SidStart;
        if (!IsValidSid(sid) || GetLengthSid(sid) > header->AceSize - offsetof(ACCESS_ALLOWED_ACE, SidStart)) goto done;
        if (!EqualSid(sid, user->User.Sid) && !EqualSid(sid, system) && !EqualSid(sid, administrators)) goto done;
    }
    permitted = 1;
done:
    if (descriptor) LocalFree(descriptor);
    free(user);
    return permitted;
}

static int creation_descriptor(SECURITY_DESCRIPTOR *descriptor, TOKEN_USER *user, PACL *acl, int directory) {
    EXPLICIT_ACCESS_W entry = {0};
    entry.grfAccessPermissions = FILE_ALL_ACCESS;
    entry.grfAccessMode = SET_ACCESS;
    entry.grfInheritance = directory ? SUB_CONTAINERS_AND_OBJECTS_INHERIT : NO_INHERITANCE;
    entry.Trustee.TrusteeForm = TRUSTEE_IS_SID;
    entry.Trustee.TrusteeType = TRUSTEE_IS_USER;
    entry.Trustee.ptstrName = (LPWSTR)user->User.Sid;
    return SetEntriesInAclW(1, &entry, NULL, acl) == ERROR_SUCCESS &&
        InitializeSecurityDescriptor(descriptor, SECURITY_DESCRIPTOR_REVISION) &&
        SetSecurityDescriptorOwner(descriptor, user->User.Sid, FALSE) &&
        SetSecurityDescriptorDacl(descriptor, TRUE, *acl, FALSE) &&
        SetSecurityDescriptorControl(descriptor, SE_DACL_PROTECTED, SE_DACL_PROTECTED);
}

typedef struct {
    WCHAR *path;
    HANDLE handles[256];
    size_t count;
} PRIVATE_PARENT_PINS;

static void release_parent_pins(PRIVATE_PARENT_PINS *pins) {
    for (size_t i = 0; i < pins->count; ++i) CloseHandle(pins->handles[i]);
    free(pins->path); free(pins);
}

/* Pin every existing ancestor before object creation, rejecting a static
   redirect before it can create even an empty target. No write/delete sharing
   is admitted while those native handles are retained. This does not claim
   isolation from a compromised host owner or kernel. */
static PRIVATE_PARENT_PINS *pin_private_parents(const WCHAR *path) {
    PRIVATE_PARENT_PINS *pins = calloc(1, sizeof(PRIVATE_PARENT_PINS));
    if (!pins) return NULL;
    pins->path = calloc(32768, sizeof(WCHAR));
    if (!pins->path) goto denied;
    /* Never reinterpret a relative, device or drive-relative reference. */
    int drive = ((path[0] >= L'A' && path[0] <= L'Z') || (path[0] >= L'a' && path[0] <= L'z')) &&
        path[1] == L':' && (path[2] == L'\\' || path[2] == L'/');
    int unc = path[0] == L'\\' && path[1] == L'\\' && path[2] != L'?' && path[2] != L'.';
    if (!drive && !unc) goto denied;
    DWORD length = GetFullPathNameW(path, 32768, pins->path, NULL);
    if (!length || length >= 32768) goto denied;
    size_t root = 2;
    if (unc) {
        WCHAR *server = wcschr(pins->path + 2, L'\\');
        WCHAR *share = server ? wcschr(server + 1, L'\\') : NULL;
        if (!server || server == pins->path + 2 || !share || share == server + 1) goto denied;
        root = (size_t)(share - pins->path);
    }
    if (wcschr(pins->path + root + 1, L':')) goto denied;
    for (size_t i = root; i < length; ++i) {
        if (pins->path[i] != L'\\') continue;
        /* Include the slash for the drive/UNC root; other prefixes end just
           before a separator. The final selected leaf is not an ancestor. */
        size_t end = i == root ? i + 1 : i;
        WCHAR saved = pins->path[end]; pins->path[end] = 0;
        HANDLE parent = CreateFileW(pins->path, READ_CONTROL | FILE_READ_ATTRIBUTES, FILE_SHARE_READ,
            NULL, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS, NULL);
        BY_HANDLE_FILE_INFORMATION information;
        int valid = parent != INVALID_HANDLE_VALUE && GetFileType(parent) == FILE_TYPE_DISK &&
            GetFileInformationByHandle(parent, &information) &&
            (information.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) &&
            !(information.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) && same_final_path(parent, pins->path);
        pins->path[end] = saved;
        if (!valid || pins->count == 256) {
            if (parent != INVALID_HANDLE_VALUE) CloseHandle(parent);
            goto denied;
        }
        pins->handles[pins->count++] = parent;
    }
    if (!pins->count || pins->path[length - 1] == L'\\') goto denied;
    return pins;
denied:
    release_parent_pins(pins); return NULL;
}

int rc_host_create_private_directory(const char *path) {
    WCHAR *wide = wide_path(path);
    TOKEN_USER *user = current_user();
    SECURITY_DESCRIPTOR descriptor; PACL acl = NULL;
    PRIVATE_PARENT_PINS *pins = NULL;
    int result = 2;
    if (!wide || !user || !creation_descriptor(&descriptor, user, &acl, 1)) goto done;
    pins = pin_private_parents(wide);
    if (!pins) goto done;
    SECURITY_ATTRIBUTES attributes = {sizeof(SECURITY_ATTRIBUTES), &descriptor, FALSE};
    if (!CreateDirectoryW(wide, &attributes)) goto done;
    HANDLE file = CreateFileW(wide, READ_CONTROL | FILE_READ_ATTRIBUTES, FILE_SHARE_READ, NULL, OPEN_EXISTING,
        FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS, NULL);
    if (file != INVALID_HANDLE_VALUE) {
        BY_HANDLE_FILE_INFORMATION information;
        if (GetFileType(file) == FILE_TYPE_DISK && GetFileInformationByHandle(file, &information) &&
            !(information.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) &&
            (information.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) &&
            same_final_path(file, wide) && protected_authority(file)) result = 0;
        CloseHandle(file);
    }
done:
    if (pins) release_parent_pins(pins);
    if (acl) LocalFree(acl);
    free(user); free(wide); return result;
}

int rc_host_create_private_file(const char *path, const unsigned char *bytes, size_t length) {
    if (length > 268435456 || (!bytes && length)) return 3;
    WCHAR *wide = wide_path(path);
    TOKEN_USER *user = current_user();
    SECURITY_DESCRIPTOR descriptor; PACL acl = NULL;
    PRIVATE_PARENT_PINS *pins = NULL;
    int result = 2;
    if (!wide || !user || !creation_descriptor(&descriptor, user, &acl, 0)) goto done;
    pins = pin_private_parents(wide);
    if (!pins) goto done;
    SECURITY_ATTRIBUTES attributes = {sizeof(SECURITY_ATTRIBUTES), &descriptor, FALSE};
    HANDLE file = CreateFileW(wide, GENERIC_WRITE | READ_CONTROL | FILE_READ_ATTRIBUTES | DELETE, FILE_SHARE_READ, &attributes, CREATE_NEW,
        FILE_FLAG_OPEN_REPARSE_POINT | FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) goto done;
    BY_HANDLE_FILE_INFORMATION information;
    if (GetFileType(file) != FILE_TYPE_DISK || !GetFileInformationByHandle(file, &information) ||
        (information.dwFileAttributes & (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY)) ||
        !same_final_path(file, wide) || !protected_authority(file)) goto close;
    size_t offset = 0;
    while (offset < length) {
        DWORD count = 0;
        DWORD wanted = (DWORD)((length - offset) > 65536 ? 65536 : (length - offset));
        if (!WriteFile(file, bytes + offset, wanted, &count, NULL) || !count) goto close;
        offset += count;
    }
    if (same_final_path(file, wide) && protected_authority(file) && set_readonly(file, 1)) result = 0;
close:
    if (result != 0) {
        /* Dispose only the original newly created handle; never remove a
           path whose identity could have changed after failed admission. */
        FILE_DISPOSITION_INFO disposition = {TRUE};
        SetFileInformationByHandle(file, FileDispositionInfo, &disposition, sizeof(disposition));
    }
    CloseHandle(file);
done:
    if (pins) release_parent_pins(pins);
    if (acl) LocalFree(acl);
    free(user); free(wide); return result;
}

int rc_host_read_file(const char *path, uint64_t maximum, int protected_file,
                      unsigned char **bytes, size_t *length) {
    *bytes = NULL; *length = 0;
    if (!maximum || maximum > 268435456) return 3;
    WCHAR *wide = wide_path(path);
    if (!wide) return 2;
    /* Deny write/delete sharing while the admitted handle is inspected/read. */
    HANDLE file = CreateFileW(wide, GENERIC_READ | READ_CONTROL, FILE_SHARE_READ, NULL, OPEN_EXISTING,
                              FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_SEQUENTIAL_SCAN, NULL);
    if (file == INVALID_HANDLE_VALUE) { free(wide); return 2; }
    int result = 2;
    BY_HANDLE_FILE_INFORMATION information;
    if (GetFileType(file) != FILE_TYPE_DISK || !GetFileInformationByHandle(file, &information) ||
        (information.dwFileAttributes & (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY)) ||
        !same_final_path(file, wide)) goto done;
    if (protected_file && !protected_authority(file)) goto done;
    uint64_t size = ((uint64_t)information.nFileSizeHigh << 32) | information.nFileSizeLow;
    if (size > maximum) { result = 3; goto done; }
    unsigned char *buffer = malloc((size_t)size + 1);
    if (!buffer) { result = 1; goto done; }
    size_t offset = 0;
    while (offset < (size_t)size) {
        DWORD read = 0;
        DWORD wanted = (DWORD)(((size_t)size - offset) > 65536 ? 65536 : (size_t)size - offset);
        if (!ReadFile(file, buffer + offset, wanted, &read, NULL) || !read) { free(buffer); goto done; }
        offset += read;
    }
    unsigned char extra; DWORD count = 0;
    if (!ReadFile(file, &extra, 1, &count, NULL) || count) { free(buffer); result = 3; goto done; }
    *bytes = buffer; *length = offset; result = 0;
done:
    CloseHandle(file); free(wide); return result;
}

int rc_host_harden_private(const char *path, int directory) {
    WCHAR *wide = wide_path(path);
    TOKEN_USER *user = current_user();
    if (!wide || !user) { free(wide); free(user); return 2; }
    HANDLE file = CreateFileW(wide, READ_CONTROL | WRITE_DAC | FILE_READ_ATTRIBUTES | FILE_WRITE_ATTRIBUTES, FILE_SHARE_READ, NULL, OPEN_EXISTING,
                              FILE_FLAG_OPEN_REPARSE_POINT | (directory ? FILE_FLAG_BACKUP_SEMANTICS : 0), NULL);
    int result = 2;
    if (file == INVALID_HANDLE_VALUE) goto done;
    BY_HANDLE_FILE_INFORMATION information;
    if (GetFileType(file) != FILE_TYPE_DISK || !GetFileInformationByHandle(file, &information) ||
        information.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT ||
        !!(information.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != !!directory ||
        !same_final_path(file, wide) || !current_owner(file, user)) goto close;
    EXPLICIT_ACCESS_W entry = {0};
    entry.grfAccessPermissions = FILE_ALL_ACCESS;
    entry.grfAccessMode = SET_ACCESS;
    entry.grfInheritance = directory ? SUB_CONTAINERS_AND_OBJECTS_INHERIT : NO_INHERITANCE;
    entry.Trustee.TrusteeForm = TRUSTEE_IS_SID;
    entry.Trustee.TrusteeType = TRUSTEE_IS_USER;
    entry.Trustee.ptstrName = (LPWSTR)user->User.Sid;
    PACL acl = NULL;
    if (SetEntriesInAclW(1, &entry, NULL, &acl) != ERROR_SUCCESS) goto close;
    if (SetSecurityInfo(file, SE_FILE_OBJECT, DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
                        NULL, NULL, acl, NULL) == ERROR_SUCCESS && protected_authority(file) &&
                        (directory || set_readonly(file, 1))) result = 0;
    LocalFree(acl);
close:
    CloseHandle(file);
done:
    free(user); free(wide); return result;
}
int rc_host_release_snapshot(const char *path) {
    WCHAR *wide = wide_path(path);
    if (!wide) return 2;
    HANDLE file = CreateFileW(wide, READ_CONTROL | FILE_READ_ATTRIBUTES | FILE_WRITE_ATTRIBUTES,
                              FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    int result = 2;
    if (file != INVALID_HANDLE_VALUE) {
        BY_HANDLE_FILE_INFORMATION information;
        if (GetFileInformationByHandle(file, &information) &&
            !(information.dwFileAttributes & (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY)) &&
            same_final_path(file, wide) && protected_authority(file) &&
            set_readonly(file, 0)) result = 0;
        CloseHandle(file);
    }
    free(wide); return result;
}
#else
int rc_host_read_file(const char *path, uint64_t maximum, int protected_file, unsigned char **bytes, size_t *length) {
    (void)path; (void)maximum; (void)protected_file; *bytes = NULL; *length = 0; return 2;
}
int rc_host_harden_private(const char *path, int directory) { (void)path; (void)directory; return 2; }
int rc_host_create_private_directory(const char *path) { (void)path; return 2; }
int rc_host_create_private_file(const char *path, const unsigned char *bytes, size_t length) {
    (void)path; (void)bytes; (void)length; return 2;
}
int rc_host_release_snapshot(const char *path) { (void)path; return 2; }
#endif
void rc_host_free(void *value) { free(value); }

#if defined(__APPLE__) || defined(__linux__)
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#ifdef __APPLE__
#include <sys/acl.h>
#endif

int rc_host_acl_safe(int32_t descriptor, int private_data) {
#ifdef __APPLE__
    acl_t acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED);
    if (!acl) return errno == ENOENT;
    acl_entry_t entry;
    int selector = ACL_FIRST_ENTRY, count = 0, safe = acl_valid(acl) == 0;
    while (safe && acl_get_entry(acl, selector, &entry) == 0) {
        selector = ACL_NEXT_ENTRY;
        acl_tag_t tag;
        acl_permset_t permissions;
        if (++count > 1024 || acl_get_tag_type(entry, &tag)) { safe = 0; break; }
        if (tag != ACL_EXTENDED_ALLOW) continue;
        if (acl_get_permset(entry, &permissions)) { safe = 0; break; }
        acl_perm_t rejected[] = { ACL_WRITE_DATA, ACL_APPEND_DATA, ACL_DELETE,
            ACL_DELETE_CHILD, ACL_WRITE_ATTRIBUTES, ACL_WRITE_EXTATTRIBUTES,
            ACL_WRITE_SECURITY, ACL_CHANGE_OWNER };
        for (size_t i = 0; i < sizeof(rejected) / sizeof(rejected[0]); ++i)
            if (acl_get_perm_np(permissions, rejected[i]) != 0) safe = 0;
        if (private_data && acl_get_perm_np(permissions, ACL_READ_DATA) != 0) safe = 0;
    }
    /* Exhaustion reports EINVAL on Darwin; other parser failures are unsafe. */
    safe = safe && errno == EINVAL;
    acl_free(acl);
    return safe;
#else
    (void)descriptor; (void)private_data;
    /* Linux access ACL effective grants are represented by the mode mask. */
    return 1;
#endif
}

static int trusted_directory(int fd) {
    struct stat value;
    return fstat(fd, &value) == 0 && S_ISDIR(value.st_mode) &&
        (value.st_uid == 0 || value.st_uid == geteuid()) &&
        (!(value.st_mode & 0022) || (value.st_uid == 0 && (value.st_mode & S_ISVTX))) &&
        rc_host_acl_safe(fd, 0);
}

int32_t rc_host_open_trusted_directory(const char *path) {
    if (!path || path[0] != '/' || strlen(path) >= PATH_MAX) return -1;
    char *copy = strdup(path);
    if (!copy) return -1;
    int fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0 || !trusted_directory(fd)) goto fail;
    char *cursor = copy + 1;
    while (*cursor) {
        char *part = cursor;
        while (*cursor && *cursor != '/') ++cursor;
        if (*cursor) *cursor++ = '\0';
        if (!*part || !strcmp(part, ".") || !strcmp(part, "..")) goto fail;
        int next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (next < 0) goto fail;
        close(fd); fd = next;
        if (!trusted_directory(fd)) goto fail;
    }
    free(copy); return fd;
fail:
    if (fd >= 0) close(fd);
    free(copy); return -1;
}

int32_t rc_host_open_protected_file(const char *path, uint64_t maximum) {
    if (!path || path[0] != '/' || strlen(path) >= PATH_MAX) return -1;
    char *copy = strdup(path);
    if (!copy) return -1;
    char *slash = strrchr(copy, '/');
    if (!slash || !slash[1] || !strcmp(slash + 1, ".") || !strcmp(slash + 1, "..")) { free(copy); return -1; }
    char *name = slash + 1;
    int parent;
    if (slash == copy) parent = rc_host_open_trusted_directory("/");
    else { *slash = '\0'; parent = rc_host_open_trusted_directory(copy); }
    if (parent < 0) { free(copy); return -1; }
    int fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    struct stat value, named;
    int safe = fd >= 0 && fstat(fd, &value) == 0 && S_ISREG(value.st_mode) &&
        value.st_uid == geteuid() && !(value.st_mode & 0077) && value.st_nlink == 1 &&
        value.st_size >= 0 && (uint64_t)value.st_size <= maximum && rc_host_acl_safe(fd, 1) &&
        fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0 &&
        named.st_dev == value.st_dev && named.st_ino == value.st_ino && named.st_nlink == 1;
    close(parent); free(copy);
    if (!safe) { if (fd >= 0) close(fd); return -1; }
    return fd;
}
#else
int rc_host_acl_safe(int32_t descriptor, int private_data) { (void)descriptor; (void)private_data; return 0; }
int32_t rc_host_open_trusted_directory(const char *path) { (void)path; return -1; }
int32_t rc_host_open_protected_file(const char *path, uint64_t maximum) { (void)path; (void)maximum; return -1; }
#endif

#ifdef __linux__
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <time.h>
#include <unistd.h>
int rc_host_write_pipe(int32_t descriptor, const unsigned char *bytes, size_t length) {
    if (descriptor < 0 || length > 1048576 || (!bytes && length)) return EINVAL;
    sigset_t blocked, previous, pending;
    sigemptyset(&blocked); sigaddset(&blocked, SIGPIPE);
    int status = pthread_sigmask(SIG_BLOCK, &blocked, &previous);
    if (status) return status;
    int was_blocked = sigismember(&previous, SIGPIPE);
    int was_pending = sigpending(&pending) == 0 ? sigismember(&pending, SIGPIPE) : 1;
    size_t offset = 0;
    int failure = 0;
    while (offset < length) {
        ssize_t count = write(descriptor, bytes + offset, length - offset);
        if (count > 0) offset += (size_t)count;
        else if (count < 0 && errno == EINTR) continue;
        else { failure = count < 0 ? errno : EIO; break; }
    }
    /* Consume only a new pipe signal from this write, not an existing signal
       or one the caller deliberately had blocked. Never alter global policy. */
    if (failure == EPIPE && !was_blocked && !was_pending) {
        struct timespec immediate = {0, 0};
        while (sigtimedwait(&blocked, NULL, &immediate) < 0 && errno == EINTR) {}
    }
    status = pthread_sigmask(SIG_SETMASK, &previous, NULL);
    return failure ? failure : status;
}
#else
int rc_host_write_pipe(int32_t descriptor, const unsigned char *bytes, size_t length) {
    (void)descriptor; (void)bytes; (void)length; return 2;
}
#endif
