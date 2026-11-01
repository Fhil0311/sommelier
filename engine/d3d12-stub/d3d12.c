// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// A Direct3D 12 that isn't there, for games running on DXMT.
//
// DXMT runs Direct3D 10/11 only; the engine's d3d12.dll is Apple's D3DMetal, which works with D3DMetal's own dxgi
// and not DXMT's. A Direct3D 11 game that merely asks whether Direct3D 12 is available (Unity's FSR and DLSS
// plugins do, to offer their upscalers) hands D3DMetal a DXMT adapter and crashes inside D3D12CreateDevice.
// This d3d12.dll sits in lib/dxmt next to DXMT's DLLs, so only a game that opted into DXMT (SOMMELIER_DLL_PREPEND)
// loads it, and it answers every such question the way Windows does on a GPU without Direct3D 12:
// DXGI_ERROR_UNSUPPORTED from D3D12CreateDevice, no debug or SDK interfaces. The game then carries on with
// Direct3D 11, as it would there. Games that need Direct3D 12 run on D3DMetal and never see this file.
//
// Exports carry the same ordinals as Windows' d3d12.dll (and D3DMetal's); plugins import D3D12CreateDevice by its
// ordinal, 101. The build marks the file as a Wine builtin (engine/build-engine-d3dmetal.sh), which is what lets
// Wine pick it from lib/dxmt in place of the copy in System32.
#include <windows.h>

#ifndef DXGI_ERROR_UNSUPPORTED
#define DXGI_ERROR_UNSUPPORTED ((HRESULT)0x887A0004L)
#endif

HRESULT WINAPI D3D12CreateDevice(IUnknown *adapter, int minimum_feature_level, REFIID riid, void **device)
{
    (void)adapter; (void)minimum_feature_level; (void)riid;
    if (device) *device = NULL;
    return DXGI_ERROR_UNSUPPORTED;
}

HRESULT WINAPI D3D12GetDebugInterface(REFIID riid, void **debug)
{
    (void)riid;
    if (debug) *debug = NULL;
    return E_NOINTERFACE;
}

HRESULT WINAPI D3D12GetInterface(REFCLSID clsid, REFIID riid, void **out)
{
    (void)clsid; (void)riid;
    if (out) *out = NULL;
    return E_NOINTERFACE;
}

HRESULT WINAPI D3D12EnableExperimentalFeatures(UINT count, const IID *iids, void *configurations, UINT *sizes)
{
    (void)count; (void)iids; (void)configurations; (void)sizes;
    return E_NOINTERFACE;
}

HRESULT WINAPI D3D12SerializeRootSignature(const void *desc, int version, void **blob, void **error)
{
    (void)desc; (void)version;
    if (blob) *blob = NULL;
    if (error) *error = NULL;
    return E_NOTIMPL;
}

HRESULT WINAPI D3D12SerializeVersionedRootSignature(const void *desc, void **blob, void **error)
{
    (void)desc;
    if (blob) *blob = NULL;
    if (error) *error = NULL;
    return E_NOTIMPL;
}

HRESULT WINAPI D3D12CreateRootSignatureDeserializer(const void *data, SIZE_T size, REFIID riid, void **out)
{
    (void)data; (void)size; (void)riid;
    if (out) *out = NULL;
    return E_NOTIMPL;
}

HRESULT WINAPI D3D12CreateVersionedRootSignatureDeserializer(const void *data, SIZE_T size, REFIID riid, void **out)
{
    (void)data; (void)size; (void)riid;
    if (out) *out = NULL;
    return E_NOTIMPL;
}

HRESULT WINAPI D3D12CoreCreateLayeredDevice(const void *a, DWORD b, const void *c, REFIID riid, void **out)
{
    (void)a; (void)b; (void)c; (void)riid;
    if (out) *out = NULL;
    return E_NOTIMPL;
}

SIZE_T WINAPI D3D12CoreGetLayeredDeviceSize(const void *a, DWORD b)
{
    (void)a; (void)b;
    return 0;
}

HRESULT WINAPI D3D12CoreRegisterLayers(const void *layers, DWORD count)
{
    (void)layers; (void)count;
    return E_NOTIMPL;
}

DWORD WINAPI GetBehaviorValue(const char *name, void *value)
{
    (void)name; (void)value;
    return 0;
}

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, void *reserved)
{
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) DisableThreadLibraryCalls(instance);
    return TRUE;
}
