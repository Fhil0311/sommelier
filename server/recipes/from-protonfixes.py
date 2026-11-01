#!/usr/bin/env python3 -I
# Copyright 2026 the Sommelier project.
# SPDX-License-Identifier: GPL-3.0-or-later
# Turns the protonfixes database (Open-Wine-Components/umu-protonfixes, BSD-2-Clause) into recipe candidates for
# Sommelier: what each fix does, re-expressed as the app's own actions, with what it needs that Sommelier can't do
# yet. Facts only; none of protonfixes' code is kept. The candidates are reviewed by hand and the chosen ones go
# into server/fixes/recipes.json.
#
#   python3 -I server/recipes/from-protonfixes.py /path/to/umu-protonfixes [--out server/recipes/candidates.json]
import ast, json, os, re, sys

STORES = {"gamefixes-steam": "steam", "gamefixes-gog": "gog", "gamefixes-egs": "epic", "gamefixes-ubisoft": "ubisoft", "gamefixes-ea": "ea",
          "gamefixes-battlenet": "battlenet"}
# winetricks verbs Sommelier already covers, and what covers them.
VC = {"vcrun2005", "vcrun2008", "vcrun2010", "vcrun2012", "vcrun2013", "vcrun2015", "vcrun2017", "vcrun2019", "vcrun2022", "mfc42", "mfc80", "mfc90",
      "mfc100", "mfc110", "mfc120", "mfc140", "ucrtbase2019"}
DOTNET = {"dotnet20", "dotnet35", "dotnet35sp1", "dotnet40", "dotnet45", "dotnet452", "dotnet46", "dotnet461", "dotnet462", "dotnet472", "dotnet48"}
# Verbs the DirectX 9 June 2010 runtime covers (D3DX 9/10/11, the older shader compilers, XACT, XAudio).
DIRECTX = {f"d3dx9_{n}" for n in range(24, 44)} | {"d3dx9", "d3dx10", "d3dx10_43", "d3dx11_42", "d3dx11_43", "d3dcompiler_42", "d3dcompiler_43",
           "d3dcompiler_46", "xact", "xact_x64", "xaudio29", "xinput"}
DIRECTMUSIC = {"directmusic", "dmband", "dmcompos", "dmime", "dmloader", "dmscript", "dmstyle", "dmsynth", "dmusic", "dswave"}
COREFONTS = {"corefonts", "andale", "arial", "comicsans", "courier", "georgia", "impact", "times", "trebuchet", "verdana", "webdings"}
WINVER = {"winxp": "winxp", "winxp64": "winxp64", "vista": "vista", "win7": "win7", "win8": "win8", "win81": "win81", "win10": "win10", "win11": "win11"}
# Environment variables that only mean something on Linux (Proton, Mesa, PulseAudio, X11).
LINUX_ENV = re.compile(r"^(PROTON_|PULSE_|UMU_|MESA_|__GL_|radeonsi|AMD_DEBUG|ENABLE_GAMESCOPE|vk_|SDL_VIDEODRIVER|DXVK_|VKD3D_|WINE_DISABLE_VULKAN|taskset|LD_|DISPLAY)")
OVERRIDE_MODES = {"DISABLED": "", "NATIVE": "n", "BUILTIN": "b", "NATIVE_BUILTIN": "n,b", "BUILTIN_NATIVE": "b,n"}


def literal(node):
    try:
        return ast.literal_eval(node)
    except Exception:
        return None


class Fix:
    def __init__(self):
        self.actions, self.needs, self.notes = [], [], []

    def action(self, a):
        if a not in self.actions: self.actions.append(a)

    def need(self, what):
        if what not in self.needs: self.needs.append(what)


def visit_call(call, fix):
    """One util.<name>(...) call: an action, a need, or nothing (Linux-only)."""
    func = call.func
    name = func.attr if isinstance(func, ast.Attribute) else getattr(func, "id", None)
    args = [literal(a) for a in call.args]
    if name == "protontricks" and args and isinstance(args[0], str):
        for verb in args[0].split():
            if verb.startswith("sound="): fix.notes.append(f"linux {verb} skipped")
            elif verb in VC: fix.action({"installVCRuntime": {}})
            elif verb in DOTNET: fix.action({"installDotNet": {}})
            elif verb == "hidewineexports=enable": fix.action({"setEnvironment": {"_0": {"SOMMELIER_HIDE_WINE": "1"}}})
            elif verb in WINVER: fix.need(f"windows version {WINVER[verb]} (needs the game's exe)")
            elif verb in DIRECTX: fix.action({"installComponent": {"_0": "directx"}})
            elif verb == "d3dcompiler_47": fix.action({"installComponent": {"_0": "d3dcompiler47"}})
            elif verb == "physx": fix.action({"installComponent": {"_0": "physx"}})
            elif verb == "directplay": fix.action({"installComponent": {"_0": "directplay"}})
            elif verb == "dsound": fix.action({"installComponent": {"_0": "dsound"}})
            elif verb in DIRECTMUSIC: fix.action({"installComponent": {"_0": "directmusic"}})
            elif verb in COREFONTS: fix.action({"installComponent": {"_0": "corefonts"}})
            elif verb == "ubisoftconnect": pass                      # Sommelier sets Ubisoft Connect up itself
            else: fix.need(f"component {verb}")
    elif name == "set_environment" and len(args) >= 2 and isinstance(args[0], str) and isinstance(args[1], str):
        if LINUX_ENV.match(args[0]): fix.notes.append(f"linux env {args[0]} skipped")
        elif args[0] == "SteamDeck": fix.action({"setEnvironment": {"_0": {"SteamDeck": args[1]}}})
        else: fix.action({"setEnvironment": {"_0": {args[0]: args[1]}}})
    elif name == "winedll_override" and len(args) >= 1 and isinstance(args[0], str):
        mode = call.args[1]
        mode_name = mode.attr if isinstance(mode, ast.Attribute) else None
        if mode_name in OVERRIDE_MODES: fix.action({"overrideDLL": {"_0": args[0], "_1": OVERRIDE_MODES[mode_name]}})
        else: fix.need(f"dll override {args[0]} (mode unknown)")
    elif name == "replace_command" and len(args) >= 2 and isinstance(args[0], str) and isinstance(args[1], str):
        src, dst = args
        if dst == "": fix.need(f"drop argument {src}")
        elif src.lower().endswith(".exe") and dst.lower().endswith(".exe"):
            fix.action({"runExecutable": {"instead": src.replace("\\.", ".").lstrip("^").rstrip("$"), "run": dst}})
        else: fix.need(f"replace {src!r} with {dst!r}")
    elif name == "append_argument" and args and isinstance(args[0], str):
        fix.action({"addArguments": {"_0": args[0].split()}})
    elif name in ("disable_esync",): fix.action({"setEnvironment": {"_0": {"WINEESYNC": "0"}}})
    elif name in ("disable_fsync", "disable_ntsync"): fix.action({"setEnvironment": {"_0": {"WINEMSYNC": "0"}}})
    elif name == "regedit_add": fix.need("registry " + (args[0] if args and isinstance(args[0], str) else "?"))
    elif name in ("set_cpu_topology_limit", "set_cpu_topology", "set_cpu_topology_nosmt"): fix.need("cpu topology")
    elif name in ("set_ini_options", "set_xml_options"): fix.need("game config edit")
    elif name in ("install_eac_runtime", "install_battleye_runtime", "patch_libcuda", "create_dosbox_conf"): fix.notes.append(f"linux-only {name}")
    elif name in ("import_saves_folder", "create_dos_device", "set_game_drive", "disable_nvapi", "install_from_zip", "install_all_from_tgz",
                  "move", "copy", "copy2", "copytree", "rmtree"): fix.need(name.replace("_", " "))


def convert(path, store, game_id):
    src = open(path, encoding="utf-8", errors="replace").read()
    try:
        tree = ast.parse(src)
    except SyntaxError:
        return None
    fix = Fix()
    for node in ast.walk(tree):
        if isinstance(node, ast.Call):
            visit_call(node, fix)
    doc = ast.get_docstring(tree) or ""
    main = next((n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "main"), None)
    note = (ast.get_docstring(main) if main else "") or doc
    note = " ".join(note.split())[:300]
    if not fix.actions and not fix.needs:
        return None
    out = {"game": f"{store}:{game_id}", "actions": fix.actions, "source": "protonfixes", "enabled": False}
    if fix.needs: out["needs"] = fix.needs
    if note: out["note"] = note
    if fix.notes: out["skipped"] = fix.notes
    return out


def main():
    root = sys.argv[1]
    out_path = sys.argv[sys.argv.index("--out") + 1] if "--out" in sys.argv else "server/recipes/candidates.json"
    candidates = []
    for folder, store in STORES.items():
        d = os.path.join(root, folder)
        if not os.path.isdir(d): continue
        for f in sorted(os.listdir(d)):
            m = re.fullmatch(r"([A-Za-z0-9_\-]+)\.py", f)
            if not m or f.startswith("__") or f == "default.py": continue
            c = convert(os.path.join(d, f), store, m.group(1))
            if c: candidates.append(c)
    ready = [c for c in candidates if c["actions"] and "needs" not in c]
    json.dump({"version": 1, "from": "umu-protonfixes", "license": "BSD-2-Clause", "candidates": candidates},
              open(out_path, "w"), ensure_ascii=False, indent=2)
    print(f"{len(candidates)} candidates, {len(ready)} fully expressible, written to {out_path}")


if __name__ == "__main__":
    main()
