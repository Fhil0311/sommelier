// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Stand-in for a Chromium helper (Steam's steamwebhelper.exe, Rockstar's SocialClubHelper.exe). Under Wine on
// macOS, Chromium's out-of-process GPU compositing leaves its windows blank, so this program starts the vendor's
// binary, renamed to "<name>_real.exe", with GPU work kept in-process and software compositing switched on.
// Every process Chromium spawns goes through here too, so child processes get the same switches.
//
// Build: x86_64-w64-mingw32-gcc -O2 -Wall -municode -mwindows -static -o steamwebhelper-wrapper.exe wrapper.c

#include <windows.h>
#include <stdlib.h>
#include <wchar.h>

#ifndef CHROMIUM_SWITCHES
#define CHROMIUM_SWITCHES L" --disable-gpu --disable-gpu-compositing --in-process-gpu"
#endif

// Sommelier recognises this generic wrapper by this string (older engines shipped one that could only start
// steamwebhelper_real.exe). Kept in the binary even though nothing here reads it.
__attribute__((used)) static const char sommelier_wrapper_id[] = "sommelier-chromium-wrapper/2";

static const wchar_t real_suffix[] = L"_real.exe";

// Turns this program's own path ("...\Foo.exe") into its target's ("...\Foo_real.exe"), in place.
// Returns FALSE when the name has no ".exe" extension or the result would not fit in `capacity`.
static BOOL derive_target_path(wchar_t *path, size_t capacity) {
    wchar_t *last_sep = wcsrchr(path, L'\\');
    wchar_t *ext = wcsrchr(path, L'.');
    if (last_sep == NULL || ext == NULL || ext < last_sep) return FALSE;
    if (_wcsicmp(ext, L".exe") != 0) return FALSE;
    size_t suffix_len = wcslen(real_suffix);
    if ((size_t)(ext - path) + suffix_len >= capacity) return FALSE;
    wmemcpy(ext, real_suffix, suffix_len + 1);
    return TRUE;
}

// Points past the program name at the start of a Windows command line, leaving the arguments untouched
// (including their leading space).
static const wchar_t *arguments_after_program(const wchar_t *cmdline) {
    if (*cmdline == L'"') {
        const wchar_t *closing = wcschr(cmdline + 1, L'"');
        return closing ? closing + 1 : cmdline + wcslen(cmdline);
    }
    const wchar_t *cursor = cmdline;
    while (*cursor != L'\0' && *cursor != L' ') cursor++;
    return cursor;
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE unused, PWSTR args, int show) {
    (void)instance; (void)unused; (void)args; (void)show;

    wchar_t target[MAX_PATH];
    DWORD length = GetModuleFileNameW(NULL, target, MAX_PATH);
    if (length == 0 || length >= MAX_PATH) return 1;
    if (!derive_target_path(target, MAX_PATH)) return 1;

    const wchar_t *rest = arguments_after_program(GetCommandLineW());
    size_t size = wcslen(target) + wcslen(rest) + wcslen(CHROMIUM_SWITCHES) + 8;
    wchar_t *cmdline = calloc(size, sizeof *cmdline);
    if (cmdline == NULL) return 1;
    swprintf(cmdline, size, L"\"%ls\"%ls%ls", target, rest, CHROMIUM_SWITCHES);

    STARTUPINFOW startup;
    ZeroMemory(&startup, sizeof startup);
    startup.cb = sizeof startup;
    PROCESS_INFORMATION child;
    // Handles are inherited so Chromium's IPC pipes reach the real helper.
    BOOL started = CreateProcessW(target, cmdline, NULL, NULL, TRUE, 0, NULL, NULL, &startup, &child);
    free(cmdline);
    if (!started) return 1;

    WaitForSingleObject(child.hProcess, INFINITE);
    DWORD status = 1;
    if (!GetExitCodeProcess(child.hProcess, &status)) status = 1;
    CloseHandle(child.hThread);
    CloseHandle(child.hProcess);
    return (int)status;
}
