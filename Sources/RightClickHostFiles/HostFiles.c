#include "RightClickHostFiles.h"
#include <stdlib.h>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <aclapi.h>
#include <wchar.h>

static WCHAR *wide_path(const char *path) {
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
    if (readonly) information.FileAttributes |= FILE_ATTRIBUTE_READONLY;
    else information.FileAttributes &= ~FILE_ATTRIBUTE_READONLY;
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
    HANDLE file = CreateFileW(wide, READ_CONTROL | WRITE_DAC | FILE_WRITE_ATTRIBUTES, FILE_SHARE_READ, NULL, OPEN_EXISTING,
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
int rc_host_release_snapshot(const char *path) { (void)path; return 2; }
#endif
void rc_host_free(void *value) { free(value); }
