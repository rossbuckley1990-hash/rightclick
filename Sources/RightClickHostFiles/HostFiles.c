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

static int create_private_file(const char *path, const unsigned char *bytes, size_t length, int immutable) {
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
    if (same_final_path(file, wide) && protected_authority(file) && FlushFileBuffers(file) &&
        (!immutable || set_readonly(file, 1))) result = 0;
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

int rc_host_create_private_file(const char *path, const unsigned char *bytes, size_t length) {
    return create_private_file(path, bytes, length, 1);
}
int rc_host_write_private_config(const char *path, const unsigned char *bytes, size_t length) {
    if (length > 4194304 || (!bytes && length)) return 3;
    return create_private_file(path, bytes, length, 0);
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
static int config_path_admitted(const WCHAR *wide, int source) {
    HANDLE file = CreateFileW(wide, READ_CONTROL | FILE_READ_ATTRIBUTES, FILE_SHARE_READ, NULL,
                              OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    if (file == INVALID_HANDLE_VALUE) return !source && GetLastError() == ERROR_FILE_NOT_FOUND;
    BY_HANDLE_FILE_INFORMATION information;
    TOKEN_USER *user = current_user();
    int result = GetFileType(file) == FILE_TYPE_DISK && GetFileInformationByHandle(file, &information) &&
        !(information.dwFileAttributes & (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY)) &&
        information.nNumberOfLinks == 1 && same_final_path(file, wide) && user && current_owner(file, user) &&
        (!source || protected_authority(file));
    free(user); CloseHandle(file); return result;
}
int rc_host_replace_config(const char *source, const char *destination) {
    WCHAR *from = wide_path(source), *to = wide_path(destination);
    int result = 2;
    PRIVATE_PARENT_PINS *source_pins = from ? pin_private_parents(from) : NULL;
    PRIVATE_PARENT_PINS *destination_pins = to ? pin_private_parents(to) : NULL;
    if (!source_pins || !destination_pins || !from || !to || !config_path_admitted(from, 1) || !config_path_admitted(to, 0)) goto done;
    /* The new private source already proves the selected parent incarnation.
       Atomic rename remains within that same directory. */
    WCHAR *from_separator = wcsrchr(from, L'\\'), *to_separator = wcsrchr(to, L'\\');
    WCHAR *from_forward = wcsrchr(from, L'/'), *to_forward = wcsrchr(to, L'/');
    if (!from_separator || (from_forward && from_forward > from_separator)) from_separator = from_forward;
    if (!to_separator || (to_forward && to_forward > to_separator)) to_separator = to_forward;
    if (!from_separator || !to_separator || from_separator - from != to_separator - to ||
        _wcsnicmp(from, to, (size_t)(from_separator - from)) != 0) goto done;
    if (MoveFileExW(from, to, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) result = 0;
done:
    if (source_pins) release_parent_pins(source_pins);
    if (destination_pins) release_parent_pins(destination_pins);
    free(from); free(to); return result;
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
int rc_host_write_private_config(const char *path, const unsigned char *bytes, size_t length) {
    (void)path; (void)bytes; (void)length; return 2;
}
int rc_host_replace_config(const char *source, const char *destination) {
    (void)source; (void)destination; return 2;
}
#endif
void rc_host_free(void *value) { free(value); }

#ifndef _WIN32
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
extern char **environ;

static int client_pipe(int descriptors[2]) {
    if (pipe(descriptors) != 0) return 2;
    for (int i = 0; i < 2; ++i) {
        if (descriptors[i] >= 3) continue;
        int elevated = fcntl(descriptors[i], F_DUPFD_CLOEXEC, 3);
        if (elevated < 0) { close(descriptors[0]); close(descriptors[1]); return 2; }
        close(descriptors[i]); descriptors[i] = elevated;
    }
    if (fcntl(descriptors[0], F_SETFD, FD_CLOEXEC) != 0 || fcntl(descriptors[1], F_SETFD, FD_CLOEXEC) != 0) {
        close(descriptors[0]); close(descriptors[1]); return 2;
    }
    return 0;
}
int rc_host_spawn_client(const char *executable, const char *const *argv,
    const char *const *environment, int input_pipe, int merge_error,
    int32_t *pid, int32_t *input_descriptor, int32_t *output_descriptor) {
    *pid = -1; *input_descriptor = -1; *output_descriptor = -1;
    if (!executable || executable[0] != '/' || !argv || !argv[0]) return 2;
    int input[2] = {-1, -1}, output[2] = {-1, -1}, null_file = -1;
    if (client_pipe(output) || (input_pipe && client_pipe(input))) goto failed;
    null_file = open("/dev/null", O_RDWR | O_CLOEXEC);
    if (null_file < 0) goto failed;
    if (null_file < 3) {
        int elevated = fcntl(null_file, F_DUPFD_CLOEXEC, 3);
        close(null_file); null_file = elevated;
        if (null_file < 0) goto failed;
    }
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    if (posix_spawn_file_actions_init(&actions) != 0) goto failed;
    if (posix_spawnattr_init(&attributes) != 0) { posix_spawn_file_actions_destroy(&actions); goto failed; }
    int status = posix_spawn_file_actions_adddup2(&actions, input_pipe ? input[0] : null_file, STDIN_FILENO);
    if (!status) status = posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO);
    if (!status) status = posix_spawn_file_actions_adddup2(&actions, merge_error ? output[1] : null_file, STDERR_FILENO);
    if (!status) status = posix_spawn_file_actions_addclose(&actions, output[0]);
    if (!status) status = posix_spawn_file_actions_addclose(&actions, output[1]);
    if (!status && input_pipe) status = posix_spawn_file_actions_addclose(&actions, input[0]);
    if (!status && input_pipe) status = posix_spawn_file_actions_addclose(&actions, input[1]);
    if (!status) status = posix_spawn_file_actions_addclose(&actions, null_file);
    if (!status) status = posix_spawnattr_setpgroup(&attributes, 0);
    if (!status) status = posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETPGROUP);
    pid_t child = -1;
    if (!status) status = posix_spawn(&child, executable, &actions, &attributes,
        (char *const *)argv, environment ? (char *const *)environment : environ);
    posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes);
    if (status != 0) goto failed;
    close(null_file); close(output[1]);
    if (input_pipe) close(input[0]);
    *pid = (int32_t)child; *input_descriptor = input_pipe ? input[1] : -1; *output_descriptor = output[0];
    return 0;
failed:
    if (null_file >= 0) close(null_file);
    if (input[0] >= 0) close(input[0]); if (input[1] >= 0) close(input[1]);
    if (output[0] >= 0) close(output[0]); if (output[1] >= 0) close(output[1]);
    return 2;
}
int rc_host_poll_client(int32_t pid, int32_t *status) {
    if (pid <= 0 || !status) return 2;
    siginfo_t information = {0};
    int result;
    do { result = waitid(P_PID, (id_t)pid, &information, WEXITED | WNOHANG | WNOWAIT); }
    while (result < 0 && errno == EINTR);
    if (result < 0) return 2;
    if (!information.si_pid) return 0;
    *status = information.si_code == CLD_EXITED ? information.si_status : 128 + information.si_status;
    return 1;
}
int rc_host_dispose_client(int32_t pid) {
    if (pid <= 0) return 2;
    /* Keep the direct child unreaped until group disposal; its PID cannot be
       reused for an unrelated process group while signals are issued. */
    kill(-(pid_t)pid, SIGTERM);
    struct timespec grace = {0, 20000000};
    while (nanosleep(&grace, &grace) < 0 && errno == EINTR) {}
    kill(-(pid_t)pid, SIGKILL);
    int status, result;
    do { result = waitpid((pid_t)pid, &status, 0); } while (result < 0 && errno == EINTR);
    return result == pid ? 0 : 2;
}
#else
int rc_host_spawn_client(const char *executable, const char *const *argv,
    const char *const *environment, int input_pipe, int merge_error,
    int32_t *pid, int32_t *input_descriptor, int32_t *output_descriptor) {
    (void)executable; (void)argv; (void)environment; (void)input_pipe; (void)merge_error;
    *pid = -1; *input_descriptor = -1; *output_descriptor = -1; return 2;
}
int rc_host_poll_client(int32_t pid, int32_t *status) { (void)pid; (void)status; return 2; }
int rc_host_dispose_client(int32_t pid) { (void)pid; return 2; }
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
