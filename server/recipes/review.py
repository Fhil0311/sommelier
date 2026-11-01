#!/usr/bin/env python3 -I
# Copyright 2026 the Sommelier project.
# SPDX-License-Identifier: GPL-3.0-or-later
# Chooses which protonfixes candidates become recipes (server/fixes/recipes.json), by rule plus a hand-reviewed list.
#
# Linux and Mac differ: a fix for DXVK may be pointless on DXMT, and arguments like "-vulkan" are wrong here. So:
#   - SAFE actions go in by themselves: runtimes and components that are harmless when not needed, hiding Wine.
#   - RISKY actions (arguments, launcher bypass, DLL overrides, other variables) go in only for games in REVIEWED,
#     with the actions as written there.
#   - Candidates that still need something Sommelier can't do are left out.
#   python3 -I server/recipes/review.py [server/recipes/candidates.json] [server/fixes/recipes.json]
import json, os, sys

SAFE = {"installVCRuntime", "installDotNet", "installComponent"}
SAFE_ENV = {"SOMMELIER_HIDE_WINE"}

# Looked at by hand (22.10.2026): what the game's own community does on Windows too, or what Steam's Linux
# players found that applies on any Wine.
REVIEWED = {
    "steam:49520": [  # Borderlands 2: Launcher.exe hangs under Wine; the game itself starts fine. PhysX for effects.
        {"runExecutable": {"instead": "Launcher.exe", "run": "Borderlands2.exe"}}, {"addArguments": {"_0": ["-NoSplash"]}},
        {"installComponent": {"_0": "physx"}}],
    "steam:447040": [  # Watch_Dogs 2: skips Easy Anti-Cheat (online play stays closed on a Mac anyway) and the splash.
        {"addArguments": {"_0": ["-eac_launcher", "-nosplash"]}}],
    "steam:8980": [  # Borderlands GOTY: the launcher, as in Borderlands 2.
        {"runExecutable": {"instead": "Launcher.exe", "run": "BorderlandsGOTY.exe"}}],
    "steam:261640": [  # Borderlands: The Pre-Sequel: the launcher.
        {"runExecutable": {"instead": "Launcher.exe", "run": "BorderlandsPreSequel.exe"}}],
    "steam:1903340": [  # Expedition 33 (ours, 22.10): the quality levels live in its own save (cloud-synced) and are applied over the ini at start.
        {"editSave": {"file": "appdata:Sandfall/Saved/SaveGames/*/SharedGameUserSettings.sav", "structName": "EngineSettingsData", "values": {"OverallScalabilityLevel": "${level}", "ViewDistanceQuality": "${level}", "AntiAliasingQuality": "${level}", "ShadowQuality": "${level}", "GlobalIlluminationQuality": "${level}", "ReflectionQuality": "${level}", "PostProcessQuality": "${level}", "TextureQuality": "${level}", "EffectsQuality": "${level}", "FoliageQuality": "${level}", "ShadingQuality": "${level}"}}}],
    "steam:292030": [  # The Witcher 3 (ours, 23.10, was built into the app): its presets by level, DirectX 11 and 12 files; no HairWorks or ray tracing; Wine hidden (protonfixes).
        # 25.10: REDlauncher (Qt) crashes under Wine when its config request takes over 2 s, and the game is DirectX 12
        # only now: Steam's REDprelauncher is skipped for the game itself.
        {"runExecutable": {"instead": "REDprelauncher.exe", "run": "bin\\x64_dx12\\witcher3.exe"}},
        # 25.10: with ray tracing reported, the game builds ray tracing pipelines when a save loads (even with RT off
        # in its menu), and D3DMetal 4.0b3 crashes inside D3D12RaytracingStateObject::CreatePipelines: the load hangs.
        {"setEnvironment": {"_0": {"D3DM_SUPPORT_DXR": "0"}}},
        {"setEnvironment": {"_0": {"SOMMELIER_HIDE_WINE": "1"}}},
        {"editConfig": {"file": "documents:The Witcher 3/user.settings", "section": "Viewport", "key": "Resolution", "value": "\"${width}x${height}\""}},
        {"editConfig": {"file": "documents:The Witcher 3/user.settings", "section": "Engine", "key": "LimitFPS", "value": "${level:60,60,60,0}"}},
        {"editConfig": {"file": "documents:The Witcher 3/user.settings", "section": "Rendering", "key": "GrassDensity", "value": "${level:1200,1800,2400,3600}"}},
        {"editConfig": {"file": "documents:The Witcher 3/user.settings", "section": "Rendering", "key": "CascadeShadowmapSize", "value": "${level:1024,1024,2048,3072}"}},
        {"editConfig": {"file": "documents:The Witcher 3/user.settings", "section": "Rendering", "key": "CascadeShadowQuality", "value": "${level:0,0,1,1}"}},
        {"editConfig": {"file": "documents:The Witcher 3/user.settings", "section": "Rendering", "key": "MeshRenderingDistanceScale", "value": "${level:0.6,0.8,1,1.5}"}},
        {"editConfig": {"file": "documents:The Witcher 3/user.settings", "section": "Rendering", "key": "MeshLODDistanceScale", "value": "${level:0.6,0.8,1,1.3}"}},
        {"editConfig": {"file": "documents:The Witcher 3/user.settings", "section": "Rendering", "key": "MaxTextureAnizotropy", "value": "${level:4,8,16,16}"}},
        {"editConfig": {"file": "documents:The Witcher 3/user.settings", "section": "Rendering", "key": "HairWorksLevel", "value": "0"}},
        {"editConfig": {"file": "documents:The Witcher 3/user.settings", "section": "Rendering/RT", "key": "EnableRT", "value": "false"}},
        {"editConfig": {"file": "documents:The Witcher 3/user.settings", "section": "Rendering/RT", "key": "RTAOEnabled", "value": "false"}},
        {"editConfig": {"file": "documents:The Witcher 3/user.settings", "section": "Rendering/RT/PathTracer", "key": "PTEnable", "value": "false"}},
        {"editConfig": {"file": "documents:The Witcher 3/dx12user.settings", "section": "Viewport", "key": "Resolution", "value": "\"${width}x${height}\""}},
        {"editConfig": {"file": "documents:The Witcher 3/dx12user.settings", "section": "Engine", "key": "LimitFPS", "value": "${level:60,60,60,0}"}},
        {"editConfig": {"file": "documents:The Witcher 3/dx12user.settings", "section": "Rendering", "key": "GrassDensity", "value": "${level:1200,1800,2400,3600}"}},
        {"editConfig": {"file": "documents:The Witcher 3/dx12user.settings", "section": "Rendering", "key": "CascadeShadowmapSize", "value": "${level:1024,1024,2048,3072}"}},
        {"editConfig": {"file": "documents:The Witcher 3/dx12user.settings", "section": "Rendering", "key": "CascadeShadowQuality", "value": "${level:0,0,1,1}"}},
        {"editConfig": {"file": "documents:The Witcher 3/dx12user.settings", "section": "Rendering", "key": "MeshRenderingDistanceScale", "value": "${level:0.6,0.8,1,1.5}"}},
        {"editConfig": {"file": "documents:The Witcher 3/dx12user.settings", "section": "Rendering", "key": "MeshLODDistanceScale", "value": "${level:0.6,0.8,1,1.3}"}},
        {"editConfig": {"file": "documents:The Witcher 3/dx12user.settings", "section": "Rendering", "key": "MaxTextureAnizotropy", "value": "${level:4,8,16,16}"}},
        {"editConfig": {"file": "documents:The Witcher 3/dx12user.settings", "section": "Rendering", "key": "HairWorksLevel", "value": "0"}},
        {"editConfig": {"file": "documents:The Witcher 3/dx12user.settings", "section": "Rendering/RT", "key": "EnableRT", "value": "false"}},
        {"editConfig": {"file": "documents:The Witcher 3/dx12user.settings", "section": "Rendering/RT", "key": "RTAOEnabled", "value": "false"}},
        {"editConfig": {"file": "documents:The Witcher 3/dx12user.settings", "section": "Rendering/RT/PathTracer", "key": "PTEnable", "value": "false"}}],
    "steam:1262560": [  # Need For Speed Most Wanted 2012 (ours, 23.10, was built into the app): the display size and its detail by level.
        {"editConfig": {"file": "documents:Criterion Games/Need For Speed(TM) Most Wanted/config.NFS13Save", "section": "Display", "key": "Width", "value": "${width}"}},
        {"editConfig": {"file": "documents:Criterion Games/Need For Speed(TM) Most Wanted/config.NFS13Save", "section": "Display", "key": "Height", "value": "${height}"}},
        {"editConfig": {"file": "documents:Criterion Games/Need For Speed(TM) Most Wanted/config.NFS13Save", "section": "Display", "key": "SSAOLevel", "value": "${level:0,1,1,2}"}},
        {"editConfig": {"file": "documents:Criterion Games/Need For Speed(TM) Most Wanted/config.NFS13Save", "section": "Display", "key": "MotionBlurLevel", "value": "${level:0,1,1,1}"}},
        {"editConfig": {"file": "documents:Criterion Games/Need For Speed(TM) Most Wanted/config.NFS13Save", "section": "Display", "key": "ReflectionDetailLevel", "value": "${level:0,1,1,2}"}},
        {"editConfig": {"file": "documents:Criterion Games/Need For Speed(TM) Most Wanted/config.NFS13Save", "section": "Display", "key": "VfxDetail", "value": "${level:0,1,1,2}"}},
        {"editConfig": {"file": "documents:Criterion Games/Need For Speed(TM) Most Wanted/config.NFS13Save", "section": "Display", "key": "HiResTextures", "value": "${level:false,true,true,true}"}},
        {"editConfig": {"file": "documents:Criterion Games/Need For Speed(TM) Most Wanted/config.NFS13Save", "section": "Display", "key": "HeadlightShadows", "value": "${level:false,false,true,true}"}},
        {"editConfig": {"file": "documents:Criterion Games/Need For Speed(TM) Most Wanted/config.NFS13Save", "section": "Settings", "key": "ShadowMapLevel", "value": "${level}"}}],
    "steam:617290": [  # Remnant: From the Ashes (ours, 23.10): the game keeps its quality in its own [GameUserSettingsGunfire] section and rewrites the engine's sg.* from it at every start; Steam copy
        {"editConfig": {"file": "appdata:Remnant/Saved/Config/WindowsNoEditor/GameUserSettings.ini", "section": "GameUserSettingsGunfire", "key": "ShadowQuality", "value": "${level}"}},
        {"editConfig": {"file": "appdata:Remnant/Saved/Config/WindowsNoEditor/GameUserSettings.ini", "section": "GameUserSettingsGunfire", "key": "AntiAliasing", "value": "${level}"}},
        {"editConfig": {"file": "appdata:Remnant/Saved/Config/WindowsNoEditor/GameUserSettings.ini", "section": "GameUserSettingsGunfire", "key": "ViewDistance", "value": "${level}"}},
        {"editConfig": {"file": "appdata:Remnant/Saved/Config/WindowsNoEditor/GameUserSettings.ini", "section": "GameUserSettingsGunfire", "key": "TextureQuality", "value": "${level}"}},
        {"editConfig": {"file": "appdata:Remnant/Saved/Config/WindowsNoEditor/GameUserSettings.ini", "section": "GameUserSettingsGunfire", "key": "PostProcessing", "value": "${level}"}},
        {"editConfig": {"file": "appdata:Remnant/Saved/Config/WindowsNoEditor/GameUserSettings.ini", "section": "GameUserSettingsGunfire", "key": "EffectsQuality", "value": "${level}"}},
        {"editConfig": {"file": "appdata:Remnant/Saved/Config/WindowsNoEditor/GameUserSettings.ini", "section": "GameUserSettingsGunfire", "key": "FoliageQuality", "value": "${level}"}},
        {"editConfig": {"file": "appdata:Remnant/Saved/Config/WindowsNoEditor/GameUserSettings.ini", "section": "GameUserSettingsGunfire", "key": "ShadowDistance", "value": "${level:0.5,0.7,0.85,1.0}"}}],
    "epic:b4a0d2d15acb4db894a599b810297543": [  # Remnant: From the Ashes, Epic copy: same
        {"editConfig": {"file": "appdata:Remnant/Saved/Config/WindowsNoEditor/GameUserSettings.ini", "section": "GameUserSettingsGunfire", "key": "ShadowQuality", "value": "${level}"}},
        {"editConfig": {"file": "appdata:Remnant/Saved/Config/WindowsNoEditor/GameUserSettings.ini", "section": "GameUserSettingsGunfire", "key": "AntiAliasing", "value": "${level}"}},
        {"editConfig": {"file": "appdata:Remnant/Saved/Config/WindowsNoEditor/GameUserSettings.ini", "section": "GameUserSettingsGunfire", "key": "ViewDistance", "value": "${level}"}},
        {"editConfig": {"file": "appdata:Remnant/Saved/Config/WindowsNoEditor/GameUserSettings.ini", "section": "GameUserSettingsGunfire", "key": "TextureQuality", "value": "${level}"}},
        {"editConfig": {"file": "appdata:Remnant/Saved/Config/WindowsNoEditor/GameUserSettings.ini", "section": "GameUserSettingsGunfire", "key": "PostProcessing", "value": "${level}"}},
        {"editConfig": {"file": "appdata:Remnant/Saved/Config/WindowsNoEditor/GameUserSettings.ini", "section": "GameUserSettingsGunfire", "key": "EffectsQuality", "value": "${level}"}},
        {"editConfig": {"file": "appdata:Remnant/Saved/Config/WindowsNoEditor/GameUserSettings.ini", "section": "GameUserSettingsGunfire", "key": "FoliageQuality", "value": "${level}"}},
        {"editConfig": {"file": "appdata:Remnant/Saved/Config/WindowsNoEditor/GameUserSettings.ini", "section": "GameUserSettingsGunfire", "key": "ShadowDistance", "value": "${level:0.5,0.7,0.85,1.0}"}}],
}
# Reviewed entries that are ours, not protonfixes'.
TEAM = {"steam:617290", "epic:b4a0d2d15acb4db894a599b810297543", "steam:1903340", "steam:292030", "steam:1262560"}
# Candidates whose fix means something only on Linux (Vulkan, Steam Deck, EAC runtime, CPU topology).
EXCLUDED = {"steam:1174180", "steam:230410", "steam:1097150", "steam:252950", "steam:242760", "steam:271590", "steam:2246340", "steam:1222700"}


def safe_actions(actions):
    out = []
    for a in actions:
        kind = next(iter(a))
        if kind in SAFE: out.append(a)
        elif kind == "setEnvironment" and set(a["setEnvironment"]["_0"]) <= SAFE_ENV: out.append(a)
    return out


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else "server/recipes/candidates.json"
    dst = sys.argv[2] if len(sys.argv) > 2 else "server/fixes/recipes.json"
    candidates = json.load(open(src))["candidates"]
    recipes = []
    for c in candidates:
        if c["game"] in EXCLUDED: continue
        if c["game"] in REVIEWED:
            actions = REVIEWED[c["game"]]
        else:
            if c.get("needs"): continue
            actions = safe_actions(c["actions"])
        if not actions: continue
        recipe = {"game": c["game"], "actions": actions, "source": "team" if c["game"] in TEAM else "protonfixes"}
        if c.get("note"): recipe["note"] = c["note"][:200]
        recipes.append(recipe)
    for game, actions in REVIEWED.items():
        if not any(r["game"] == game for r in recipes):
            recipes.append({"game": game, "actions": actions, "source": "team" if game in TEAM else "protonfixes"})
    # The graphics layer each game runs best with, from highball-db (CC0; from-highball.py). Our own tested recipes
    # (TEAM) keep their choice; a recipe that already picks a layer keeps it; the others get the layer first.
    hb_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "highball.json")
    if os.path.exists(hb_path):
        by_game = {r["game"]: r for r in recipes}
        for game, h in json.load(open(hb_path))["games"].items():
            if game in TEAM or game in EXCLUDED: continue
            action = {"switchGraphics": {"_0": h["backend"]}}
            r = by_game.get(game)
            if r is None:
                r = {"game": game, "actions": [action], "source": "highball",
                     "note": ("graphics layer from highball-db (CC0), %s" % h["status"])[:200]}
                recipes.append(r); by_game[game] = r
            elif not any("switchGraphics" in a for a in r["actions"]):
                r["actions"] = [action] + r["actions"]
                r["source"] = r.get("source", "protonfixes") + "-highball"
    recipes.sort(key=lambda r: r["game"])
    json.dump({"version": 1, "recipes": recipes}, open(dst, "w"), ensure_ascii=False, indent=2)
    open(dst, "a").write("\n")
    kinds = {}
    for r in recipes:
        for a in r["actions"]: kinds[next(iter(a))] = kinds.get(next(iter(a)), 0) + 1
    print(f"{len(recipes)} recipes from {len(candidates)} candidates; actions: {kinds}")


if __name__ == "__main__":
    main()
