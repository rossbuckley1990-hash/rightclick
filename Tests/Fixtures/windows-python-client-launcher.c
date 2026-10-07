/* Controlled native fixture launcher. No shell, network or provider-specific
   behavior: preserve argv/stdin/stdout while selecting the installed Python
   and owned script frozen into this test executable by its host fixture. */
#include <windows.h>
#include <stdint.h>
#include <wchar.h>

#include "windows-python-client-paths.h"

static int put(WCHAR *command, size_t *length, WCHAR value) {
    if (*length >= 32766) return 0;
    command[(*length)++] = value;
    return 1;
}
static int quoted(WCHAR *command, size_t *length, const WCHAR *argument) {
    if (*length && !put(command, length, L' ')) return 0;
    if (!put(command, length, L'"')) return 0;
    size_t slashes = 0;
    for (const WCHAR *p = argument; ; ++p) {
        if (*p == L'\\') { ++slashes; continue; }
        size_t count = slashes * ((*p == L'"' || !*p) ? 2 : 1);
        while (count--) if (!put(command, length, L'\\')) return 0;
        slashes = 0;
        if (!*p) break;
        if (*p == L'"' && !put(command, length, L'\\')) return 0;
        if (!put(command, length, *p)) return 0;
    }
    return put(command, length, L'"');
}
int wmain(int argc, WCHAR **argv) {
    WCHAR command[32768] = {0}; size_t length = 0;
    if (argc > 128 || !quoted(command, &length, RIGHTCLICK_FIXTURE_PYTHON) ||
        !quoted(command, &length, RIGHTCLICK_FIXTURE_SCRIPT)) return 3;
    for (int i = 1; i < argc; ++i) if (!quoted(command, &length, argv[i])) return 3;
    command[length] = 0;
    STARTUPINFOW startup = {0}; PROCESS_INFORMATION process = {0};
    startup.cb = sizeof(startup); startup.dwFlags = STARTF_USESTDHANDLES;
    startup.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
    startup.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE);
    startup.hStdError = GetStdHandle(STD_ERROR_HANDLE);
    if (!CreateProcessW(RIGHTCLICK_FIXTURE_PYTHON, command, NULL, NULL, TRUE, 0, NULL, NULL, &startup, &process)) return 4;
    DWORD status = 5;
    if (WaitForSingleObject(process.hProcess, INFINITE) == WAIT_OBJECT_0) GetExitCodeProcess(process.hProcess, &status);
    CloseHandle(process.hThread); CloseHandle(process.hProcess);
    return (int)status;
}
