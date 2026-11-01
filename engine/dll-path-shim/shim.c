// Sommelier DLL path shim. Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Wine built from CodeWeavers' CrossOver source dlopens `<ntdll dir>/cxcompatdb.so` once at process start
// (CW Hack 24067) and exports `prepend_dll_path`, which puts a folder in front of Wine's own DLL folders.
// CrossOver's own cxcompatdb.so is proprietary and not part of the source; this file is ours.
//
// It reads SOMMELIER_DLL_PREPEND, a ':'-separated list of folders laid out like Wine's lib/wine
// (x86_64-windows, i386-windows, x86_64-unix), and prepends them, first entry first. That lets one game in a
// bottle load DXMT's Direct3D DLLs as builtins while every other program keeps the engine's (D3DMetal or Wine's).
// Without the variable it does nothing.
#include <dlfcn.h>
#include <libgen.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef void (*prepend_fn)(const char *path);

static prepend_fn find_prepend(void) {
    prepend_fn fn = (prepend_fn)dlsym(RTLD_DEFAULT, "prepend_dll_path");
    if (fn) return fn;
    // Fall back to ntdll.so next to this file, if it is loaded but not global.
    Dl_info info;
    if (!dladdr((void *)find_prepend, &info) || !info.dli_fname) return NULL;
    char self[PATH_MAX], ntdll[PATH_MAX];
    strncpy(self, info.dli_fname, sizeof(self) - 1);
    self[sizeof(self) - 1] = 0;
    snprintf(ntdll, sizeof(ntdll), "%s/ntdll.so", dirname(self));
    void *handle = dlopen(ntdll, RTLD_NOLOAD | RTLD_LAZY);
    return handle ? (prepend_fn)dlsym(handle, "prepend_dll_path") : NULL;
}

__attribute__((constructor)) static void sommelier_prepend_dll_paths(void) {
    const char *list = getenv("SOMMELIER_DLL_PREPEND");
    if (!list || !*list) return;
    prepend_fn prepend = find_prepend();
    if (!prepend) {
        fprintf(stderr, "sommelier: prepend_dll_path not found, SOMMELIER_DLL_PREPEND ignored\n");
        return;
    }
    // Wine keeps the pointers, so every entry is its own allocation that is never freed.
    char *copy = strdup(list);
    if (!copy) return;
    char *entries[16];
    int count = 0;
    for (char *p = strtok(copy, ":"); p && count < 16; p = strtok(NULL, ":")) entries[count++] = p;
    for (int i = count - 1; i >= 0; i--) {   // prepend in reverse, so the first entry ends up first
        char *path = strdup(entries[i]);
        if (path) prepend(path);
    }
    free(copy);
}
