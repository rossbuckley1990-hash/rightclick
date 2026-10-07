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

static void report(const char *label, const WCHAR *path, int directory) {
    char utf8[32768];
    if (!WideCharToMultiByte(CP_UTF8, 0, path, -1, utf8, sizeof(utf8), NULL, NULL)) return;
    TOKEN_USER *user = current_user();
    HANDLE handle = CreateFileW(path, READ_CONTROL | FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING,
        FILE_FLAG_OPEN_REPARSE_POINT | (directory ? FILE_FLAG_BACKUP_SEMANTICS : 0), NULL);
    DWORD open_error = handle == INVALID_HANDLE_VALUE ? GetLastError() : 0;
    int final_matches = 0, owned = 0, protected = 0, disk = 0, native_directory = 0;
    if (handle != INVALID_HANDLE_VALUE) {
        BY_HANDLE_FILE_INFORMATION info;
        final_matches = same_final_path(handle, path);
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
           "\"hardenResult\":%d,\"protectedReadResult\":%d,\"bytesRead\":%zu}\n",
           label, (unsigned long)open_error, disk, native_directory, final_matches, owned, protected,
           hardened, read_result, count);
    if (bytes) rc_host_free(bytes);
    if (user) free(user);
    if (!directory) rc_host_release_snapshot(utf8);
}

static int create_file(const WCHAR *path, SECURITY_ATTRIBUTES *attributes) {
    HANDLE file = CreateFileW(path, GENERIC_WRITE, FILE_SHARE_READ, attributes, CREATE_NEW,
                              FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) return 0;
    DWORD count = 0;
    int result = WriteFile(file, "private fixture", 15, &count, NULL) && count == 15;
    CloseHandle(file); return result;
}

int main(void) {
    WCHAR temp[32768], root[32768], plain[32768], explicit[32768], plain_file[32768], explicit_file[32768];
    DWORD count = GetTempPathW(32768, temp);
    if (!count || count >= 32700) return 1;
    swprintf_s(root, 32768, L"%srightclick-owner-probe-%lu-%llu", temp, (unsigned long)GetCurrentProcessId(),
               (unsigned long long)GetTickCount64());
    swprintf_s(plain, 32768, L"%s\\ordinary", root);
    swprintf_s(explicit, 32768, L"%s\\explicit", root);
    swprintf_s(plain_file, 32768, L"%s\\reference", plain);
    swprintf_s(explicit_file, 32768, L"%s\\reference", explicit);
    TOKEN_USER *user = current_user();
    SECURITY_DESCRIPTOR descriptor; PACL acl = NULL;
    if (!user || !private_descriptor(&descriptor, user, &acl)) return 2;
    SECURITY_ATTRIBUTES attributes = {sizeof(SECURITY_ATTRIBUTES), &descriptor, FALSE};
    if (!CreateDirectoryW(root, NULL) || !CreateDirectoryW(plain, NULL) ||
        !CreateDirectoryW(explicit, &attributes) || !create_file(plain_file, NULL) ||
        !create_file(explicit_file, &attributes)) return 3;
    report("ordinary-directory", plain, 1);
    report("ordinary-file", plain_file, 0);
    report("explicit-owner-directory", explicit, 1);
    report("explicit-owner-file", explicit_file, 0);
    /* Exact owned paths only; cleanup acknowledges are not acceptance evidence. */
    int cleanup = DeleteFileW(plain_file) && DeleteFileW(explicit_file) &&
        RemoveDirectoryW(plain) && RemoveDirectoryW(explicit) && RemoveDirectoryW(root);
    printf("{\"cleanupCommandsSucceeded\":%d}\n", cleanup);
    LocalFree(acl); free(user);
    return cleanup ? 0 : 4;
}
