/* Native diagnostic: compile the exact production backend in one translation
   unit to observe its private gates, without a second file-authority engine. */
#include "../../Sources/RightClickHostFiles/HostFiles.c"
#include <stdio.h>

static int private_descriptor(SECURITY_DESCRIPTOR *descriptor, TOKEN_USER *user, PACL *acl) {
    EXPLICIT_ACCESS_W entry = {0};
    entry.grfAccessPermissions = FILE_ALL_ACCESS;
    entry.grfAccessMode = SET_ACCESS;
    entry.grfInheritance = SUB_CONTAINERS_AND_OBJECTS_INHERIT;
    entry.Trustee.TrusteeForm = TRUSTEE_IS_SID;
    entry.Trustee.TrusteeType = TRUSTEE_IS_USER;
    entry.Trustee.ptstrName = (LPWSTR)user->User.Sid;
    return SetEntriesInAclW(1, &entry, NULL, acl) == ERROR_SUCCESS &&
        InitializeSecurityDescriptor(descriptor, SECURITY_DESCRIPTOR_REVISION) &&
        SetSecurityDescriptorOwner(descriptor, user->User.Sid, FALSE) &&
        SetSecurityDescriptorDacl(descriptor, TRUE, *acl, FALSE);
}

/* Classify a path representation mismatch without exporting a host path. This
   is diagnostic only: production still checks its unchanged selected path. */
static int long_path_matches(HANDLE file, const WCHAR *path, int *changed, int *short_alias) {
    WCHAR expected[32768], expanded[32768], actual[32768];
    DWORD e = GetFullPathNameW(path, 32768, expected, NULL);
    DWORD a = GetFinalPathNameByHandleW(file, actual, 32768, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
    if (!e || e >= 32768 || !a || a >= 32768) return 0;
    *short_alias = wcschr(expected, L'~') != NULL;
    DWORD l = GetLongPathNameW(expected, expanded, 32768);
    if (!l || l >= 32768) return 0;
    *changed = _wcsicmp(expected, expanded) != 0;
    if (wcsncmp(actual, L"\\\\?\\UNC\\", 8) == 0) {
        WCHAR unc[32768] = L"\\\\";
        if (wcslen(actual + 8) + 3 >= 32768) return 0;
        wcscat(unc, actual + 8);
        return _wcsicmp(expanded, unc) == 0;
    }
    return _wcsicmp(expanded, wcsncmp(actual, L"\\\\?\\", 4) == 0 ? actual + 4 : actual) == 0;
}

static int report(const char *label, const WCHAR *path, int directory) {
    char utf8[32768];
    if (!WideCharToMultiByte(CP_UTF8, 0, path, -1, utf8, sizeof(utf8), NULL, NULL)) return 0;
    TOKEN_USER *user = current_user();
    HANDLE handle = CreateFileW(path, READ_CONTROL | FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING,
        FILE_FLAG_OPEN_REPARSE_POINT | (directory ? FILE_FLAG_BACKUP_SEMANTICS : 0), NULL);
    DWORD open_error = handle == INVALID_HANDLE_VALUE ? GetLastError() : 0;
    int final_matches = 0, owned = 0, protected = 0, disk = 0, native_directory = 0;
    int long_matches = 0, long_changed = 0, short_alias = 0;
    if (handle != INVALID_HANDLE_VALUE) {
        BY_HANDLE_FILE_INFORMATION info;
        final_matches = same_final_path(handle, path);
        long_matches = long_path_matches(handle, path, &long_changed, &short_alias);
        owned = user && current_owner(handle, user);
        protected = protected_authority(handle);
        disk = GetFileType(handle) == FILE_TYPE_DISK;
        if (GetFileInformationByHandle(handle, &info)) native_directory = !!(info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY);
        CloseHandle(handle);
    }
    int hardened = rc_host_harden_private(utf8, directory);
    int read_result = -1;
    unsigned char *bytes = NULL; size_t count = 0;
    if (!directory) read_result = rc_host_read_file(utf8, 128, 1, &bytes, &count);
    printf("{\"case\":\"%s\",\"openError\":%lu,\"disk\":%d,\"nativeDirectory\":%d,"
           "\"finalPathMatches\":%d,\"ownerMatchesCurrentUser\":%d,\"initialProtectedAuthority\":%d,"
           "\"hardenResult\":%d,\"protectedReadResult\":%d,\"bytesRead\":%zu,"
           "\"longPathMatches\":%d,\"longPathChanged\":%d,\"expectedHasShortAlias\":%d}\n",
           label, (unsigned long)open_error, disk, native_directory, final_matches, owned, protected,
           hardened, read_result, count, long_matches, long_changed, short_alias);
    if (bytes) rc_host_free(bytes);
    if (user) free(user);
    if (!directory) rc_host_release_snapshot(utf8);
    return final_matches && owned && protected && hardened == 0 &&
        (directory || (read_result == 0 && count == 15));
}

static int create_file(const WCHAR *path, SECURITY_ATTRIBUTES *attributes) {
    HANDLE file = CreateFileW(path, GENERIC_WRITE, FILE_SHARE_READ, attributes, CREATE_NEW,
                              FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) return 0;
    DWORD count = 0;
    int result = WriteFile(file, "private fixture", 15, &count, NULL) && count == 15;
    CloseHandle(file); return result;
}

static int absent(const WCHAR *path) {
    DWORD attributes = GetFileAttributesW(path);
    DWORD error = attributes == INVALID_FILE_ATTRIBUTES ? GetLastError() : 0;
    return attributes == INVALID_FILE_ATTRIBUTES && error == ERROR_FILE_NOT_FOUND;
}

static int redirect_creation_control(const WCHAR *root, const WCHAR *target) {
    /* All paths are generated inside this test's owned temporary directory. */
    WCHAR *paths = calloc(6 * 32768, sizeof(WCHAR));
    if (!paths) return 0;
    WCHAR *alias = paths, *command = paths + 32768, *file = paths + 2 * 32768;
    WCHAR *directory = paths + 3 * 32768, *actual_file = paths + 4 * 32768, *actual_directory = paths + 5 * 32768;
    swprintf_s(alias, 32768, L"%s\\redirect", root);
    swprintf_s(command, 32768, L"cmd.exe /d /c mklink /J \"%s\" \"%s\" > nul 2>&1", alias, target);
    int created = _wsystem(command) == 0;
    DWORD attributes = GetFileAttributesW(alias);
    int junction = created && attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_REPARSE_POINT);
    swprintf_s(file, 32768, L"%s\\must-not-exist", alias);
    swprintf_s(directory, 32768, L"%s\\directory-must-not-exist", alias);
    swprintf_s(actual_file, 32768, L"%s\\must-not-exist", target);
    swprintf_s(actual_directory, 32768, L"%s\\directory-must-not-exist", target);
    char utf8[32768];
    int rejected_file = 0, rejected_directory = 0;
    if (junction && WideCharToMultiByte(CP_UTF8, 0, file, -1, utf8, sizeof(utf8), NULL, NULL))
        rejected_file = rc_host_create_private_file(utf8, (const unsigned char *)"must not write", 14) != 0;
    if (junction && WideCharToMultiByte(CP_UTF8, 0, directory, -1, utf8, sizeof(utf8), NULL, NULL))
        rejected_directory = rc_host_create_private_directory(utf8) != 0;
    int file_absent = absent(actual_file), directory_absent = absent(actual_directory);
    int removed = junction && RemoveDirectoryW(alias);
    printf("{\"parentJunctionCreated\":%d,\"redirectedFileRejected\":%d,\"redirectedFileAbsent\":%d,"
        "\"redirectedDirectoryRejected\":%d,\"redirectedDirectoryAbsent\":%d,\"junctionRemovalAcknowledged\":%d}\n",
        junction, rejected_file, file_absent, rejected_directory, directory_absent, removed);
    free(paths);
    return junction && rejected_file && file_absent && rejected_directory && directory_absent && removed;
}

int main(void) {
    WCHAR temp[32768], root[32768], plain[32768], explicit[32768], plain_file[32768], explicit_file[32768];
    WCHAR runtime[32768], runtime_file[32768];
    DWORD count = GetTempPathW(32768, temp);
    if (!count || count >= 32700) return 1;
    swprintf_s(root, 32768, L"%srightclick-owner-probe-%lu-%llu", temp, (unsigned long)GetCurrentProcessId(),
               (unsigned long long)GetTickCount64());
    swprintf_s(plain, 32768, L"%s\\ordinary", root);
    swprintf_s(explicit, 32768, L"%s\\explicit", root);
    swprintf_s(plain_file, 32768, L"%s\\reference", plain);
    swprintf_s(explicit_file, 32768, L"%s\\reference", explicit);
    swprintf_s(runtime, 32768, L"%s\\runtime-created", root);
    swprintf_s(runtime_file, 32768, L"%s\\reference", runtime);
    TOKEN_USER *user = current_user();
    SECURITY_DESCRIPTOR descriptor; PACL acl = NULL;
    if (!user || !private_descriptor(&descriptor, user, &acl)) return 2;
    SECURITY_ATTRIBUTES attributes = {sizeof(SECURITY_ATTRIBUTES), &descriptor, FALSE};
    if (!CreateDirectoryW(root, NULL) || !CreateDirectoryW(plain, NULL) ||
        !CreateDirectoryW(explicit, &attributes) || !create_file(plain_file, NULL) ||
        !create_file(explicit_file, &attributes)) return 3;
    report("ordinary-directory", plain, 1);
    report("ordinary-file", plain_file, 0);
    int green = report("explicit-owner-directory", explicit, 1);
    green = report("explicit-owner-file", explicit_file, 0) && green;
    char runtime_utf8[32768], runtime_file_utf8[32768];
    if (!WideCharToMultiByte(CP_UTF8, 0, runtime, -1, runtime_utf8, sizeof(runtime_utf8), NULL, NULL) ||
        !WideCharToMultiByte(CP_UTF8, 0, runtime_file, -1, runtime_file_utf8, sizeof(runtime_file_utf8), NULL, NULL)) return 5;
    int created_directory = rc_host_create_private_directory(runtime_utf8);
    int created_file = rc_host_create_private_file(runtime_file_utf8, (const unsigned char *)"private fixture", 15);
    int overwrite = rc_host_create_private_file(runtime_file_utf8, (const unsigned char *)"changed fixture", 15);
    int adopt_directory = rc_host_create_private_directory(runtime_utf8);
    green = report("runtime-created-directory", runtime, 1) && green;
    green = report("runtime-created-file", runtime_file, 0) && green;
    printf("{\"createdDirectory\":%d,\"createdFile\":%d,\"overwriteRejected\":%d,\"existingDirectoryRejected\":%d}\n",
        created_directory, created_file, overwrite != 0, adopt_directory != 0);
    green = created_directory == 0 && created_file == 0 && overwrite != 0 && adopt_directory != 0 && green;
    int readonly_only = SetFileAttributesW(runtime_file, FILE_ATTRIBUTE_READONLY) != 0;
    int released = readonly_only ? rc_host_release_snapshot(runtime_file_utf8) : 2;
    DWORD after_release = GetFileAttributesW(runtime_file);
    int readonly_absent = after_release != INVALID_FILE_ATTRIBUTES && !(after_release & FILE_ATTRIBUTE_READONLY);
    printf("{\"readOnlyOnlyAssigned\":%d,\"readOnlyOnlyReleaseResult\":%d,\"readOnlyFlagAbsent\":%d}\n",
        readonly_only, released, readonly_absent);
    green = readonly_only && released == 0 && readonly_absent && green;
    green = redirect_creation_control(root, runtime) && green;
    /* Exact owned paths only; cleanup acknowledges are not acceptance evidence. */
    int cleanup = DeleteFileW(plain_file) && DeleteFileW(explicit_file) && DeleteFileW(runtime_file) &&
        RemoveDirectoryW(plain) && RemoveDirectoryW(explicit) && RemoveDirectoryW(runtime) && RemoveDirectoryW(root);
    printf("{\"cleanupCommandsSucceeded\":%d}\n", cleanup);
    LocalFree(acl); free(user);
    return cleanup && green ? 0 : 4;
}
