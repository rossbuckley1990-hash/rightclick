// Reuses the frozen native provider. Only test infrastructure can pause its
// STA message pump, so a real marshalled native RPC outlives the client deadline.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <filesystem>
#include <fstream>
static std::filesystem::path pauseDirectory;
static void proofSleep(DWORD milliseconds) {
    if (milliseconds == 10 && std::filesystem::exists(pauseDirectory / "pause") &&
        !std::filesystem::exists(pauseDirectory / "paused")) {
        std::ofstream(pauseDirectory / "paused") << "native STA paused";
        ::Sleep(10000);
        std::ofstream(pauseDirectory / "unpaused") << "native STA resumed";
    }
    ::Sleep(milliseconds);
}
#define Sleep proofSleep
#define wmain frozen_fixture_wmain
#include "windows-com-live.cpp"
#undef wmain
#undef Sleep
int wmain(int argc, wchar_t **argv) {
    if (argc == 6 && std::wstring(argv[1]) == L"serve") pauseDirectory = argv[2];
    return frozen_fixture_wmain(argc, argv);
}
