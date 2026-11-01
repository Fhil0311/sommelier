#!/usr/bin/env python3
# Copyright 2026 the Sommelier project.
# SPDX-License-Identifier: GPL-3.0-or-later
"""The cellar's builder: turns the packs players shared for a game into Metal binary archives for every Mac.

Runs on any Mac with Xcode's Metal toolchain and Sommelier's DXMT `cellar` tool (no GPU of each family is needed:
`metal-tt` compiles for all of them). For each executable of the game it
  1. downloads the shaders and pipelines packs from the decanter and lays them out as DXMT's files,
  2. builds them with `cellar cook` (an archive for this Mac, the libraries, and the function table),
  3. harvests the pipeline script from that archive with `metal-source` and points it at the libraries,
  4. compiles one archive per macOS major version and GPU architecture with `metal-tt`,
  5. uploads them (PUT /v1/cellar/…, bearer token).

    build.py --tool <engine>/wine/lib/dxmt/x86_64-unix/cellar --token … steam 1538550 [epic:Sage …]
    build.py --tool … --local shaders_320.db pipelines_320.bin --out DIR     (no service: build from files)
"""
import argparse, json, os, re, shutil, sqlite3, struct, subprocess, sys, tempfile, urllib.request, zlib

DECANTER = os.environ.get("SOMMELIER_DECANTER_URL", "https://decanter.playsommelier.com")
LAUNCHERS = {"Steam.exe", "steamwebhelper.exe", "steamwebhelper_real.exe", "GameOverlayUI.exe", "start.exe", "EADesktop.exe",
             "EACefSubProcess.exe", "EABackgroundService.exe", "IGOProxy32.exe", "IGOProxy64.exe", "upc.exe", "UplayWebCore.exe",
             "UbisoftGameLauncher.exe", "Battle.net.exe", "Agent.exe"}
# Apple GPU architectures by chip: M1 g13, M2 g14, M3 g15, M4 g16, M5 g17; g = base, s = Pro/Max, d = Ultra.
ARCHS = ["applegpu_g13g", "applegpu_g13s", "applegpu_g13d", "applegpu_g14g", "applegpu_g14s", "applegpu_g14d",
         "applegpu_g15g", "applegpu_g15s", "applegpu_g15d", "applegpu_g16g", "applegpu_g16s", "applegpu_g17g", "applegpu_g17s"]
OSES = ["15", "26"]


SIGN = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "scripts", "sign.sh")


def signature(path):
    """The update key's signature of a file (scripts/sign.sh): apps take only archives the owner signed."""
    return subprocess.run([SIGN, path], check=True, capture_output=True, text=True).stdout.strip()


def http(method, path, body=None, headers=None, token=None):
    req = urllib.request.Request(DECANTER + "/" + path, data=body, method=method)
    req.add_header("X-Sommelier-Client", "Sommelier-cellar/1")
    for k, v in (headers or {}).items(): req.add_header(k, v)
    if token: req.add_header("Authorization", "Bearer " + token)
    with urllib.request.urlopen(req, timeout=600) as r: return r.read()


def decode_pack(data):
    """SMLR packs, as pack.js / ShaderPack.swift lay them out."""
    if data[:4] != b"SMLR" or data[4] != 2: raise ValueError("not a pack")
    kind, metal, table, count = data[5], *struct.unpack_from("<III", data, 6)
    body = zlib.decompress(data[18:], -15) if count else b""
    entries, p = {}, 0
    for _ in range(count):
        kl, = struct.unpack_from("<H", body, p); p += 2
        key = body[p:p + kl]; p += kl
        vl, = struct.unpack_from("<I", body, p); p += 4
        entries[key] = body[p:p + vl]; p += vl
    return kind, metal, table, entries


def write_dxmt_files(folder, shaders, pipelines):
    """DXMT's shaders_<metal>.db and pipelines_<metal>.bin from the two packs."""
    os.makedirs(folder, exist_ok=True)
    _, metal, table, entries = shaders
    db = os.path.join(folder, f"shaders_{metal}.db")
    con = sqlite3.connect(db)
    con.execute(f"CREATE TABLE IF NOT EXISTS cache_{table} (key BLOB PRIMARY KEY, value BLOB NOT NULL)")
    con.executemany(f"INSERT OR IGNORE INTO cache_{table} (key, value) VALUES (?, ?)", list(entries.items()))
    con.commit(); con.close()
    _, pmetal, pversion, records = pipelines
    out = bytearray(b"DXPL") + struct.pack("<I", pversion)
    for value in records.values():
        out += value[:4] + struct.pack("<I", len(value) - 4) + value[4:]
    binp = os.path.join(folder, f"pipelines_{pmetal}.bin")
    open(binp, "wb").write(out)
    return db, binp


def run(cmd, **kw):
    r = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if r.returncode != 0: raise RuntimeError(f"{' '.join(cmd[:3])}… failed: {r.stderr.strip()[-400:]}")
    return r.stdout


def cook(tool, db, binp, out):
    """`cellar cook`: the archive for this Mac, libs/ and functions.tsv. Returns the pipeline count."""
    line = run(["/usr/bin/nice", "-n", "10", tool, "cook", db, binp, out]).strip()
    fields = dict(f.split("=", 1) for f in line.split(" ") if "=" in f)
    return int(fields.get("built", 0))


def harvest_script(cook_dir):
    """The pipeline script metal-tt needs, from the device-built archive, with its libraries pointed at ours."""
    harvest = os.path.join(cook_dir, "harvest")
    shutil.rmtree(harvest, ignore_errors=True)
    run(["xcrun", "-sdk", "macosx", "metal-source", "-flatbuffers=json", os.path.join(cook_dir, "device.metallib"), "-o", harvest])
    scripts = [os.path.join(r, f) for r, _, fs in os.walk(harvest) for f in fs if f.endswith(".mtlp-json")]
    if not scripts: raise RuntimeError("no pipeline script in the harvested archive")
    script = json.load(open(scripts[0]))
    functions = {}
    for line in open(os.path.join(cook_dir, "functions.tsv")):
        name, path = line.rstrip("\n").split("\t")
        functions[name] = os.path.join(cook_dir, path)
    label_path = {}
    for group in script.get("pipelines", {}).values():
        for p in group:
            for field in ("vertex_function", "fragment_function", "compute_function", "object_function", "mesh_function"):
                ref = p.get(field)
                if not ref: continue
                m = re.match(r"alias:([0-9A-Fa-f]+)#(.+)$", ref)
                if m and m.group(2) in functions: label_path[m.group(1)] = functions[m.group(2)]
    for lib in script["libraries"]["paths"]:
        if lib["label"] in label_path: lib["path"] = label_path[lib["label"]]
        else: raise RuntimeError(f"no library for {lib['label']}")
    path = os.path.join(cook_dir, "pipelines.mtlp-json")
    json.dump(script, open(path, "w"))
    return path


def press(script, os_major, arch, out):
    """metal-tt: the archive for one macOS major version and one GPU architecture."""
    sdk = os_major if int(os_major) >= 26 else "26"
    run(["xcrun", "-sdk", "macosx", "metal-tt", "-platform_version", "macos", f"{os_major}.0", f"{sdk}.0", "-arch", arch, script, "-o", out])
    return os.path.getsize(out)


def build_exe(tool, exe, db, binp, work, oses, archs):
    """Every archive for one executable: {(os, arch): (path, pipelines)}."""
    cook_dir = os.path.join(work, "cook")
    shutil.rmtree(cook_dir, ignore_errors=True)
    built = cook(tool, db, binp, cook_dir)
    if not built: return {}
    script = harvest_script(cook_dir)
    archives = {}
    for os_major in oses:
        for arch in archs:
            out = os.path.join(work, f"{exe}-{os_major}-{arch}.metallib")
            size = press(script, os_major, arch, out)
            archives[(os_major, arch)] = (out, built)
            print(f"  {exe} macOS {os_major} {arch}: {built} pipelines, {size // 1024} KB", flush=True)
    return archives


def build_game(args, store, game):
    manifest = json.loads(http("GET", f"v1/pack/{store}/{game}"))
    have = json.loads(http("GET", f"v1/cellar/{store}/{game}")).get("archives", []) if not args.force else []
    packs = {}
    for p in manifest.get("packs", []):
        if p["exe"] in LAUNCHERS: continue
        packs.setdefault(p["exe"], {})[p["kind"]] = p
    for exe, kinds in packs.items():
        if "shaders" not in kinds or "pipelines" not in kinds: continue
        pipelines = kinds["pipelines"]["count"]
        todo = [(o, a) for o in args.os for a in args.archs
                if not any(h["exe"] == exe and h["os"] == o and h["arch"] == a and h["pipelines"] >= pipelines for h in have)]
        if not todo:
            print(f"{store}:{game} {exe}: up to date ({pipelines} pipelines)"); continue
        print(f"{store}:{game} {exe}: {pipelines} pipelines → {len(todo)} archives", flush=True)
        work = os.path.join(args.work, store, game, exe)
        os.makedirs(work, exist_ok=True)
        shaders = decode_pack(http("GET", f"v1/pack/{store}/{game}/{exe}/shaders/{kinds['shaders']['metal']}/{kinds['shaders']['table']}"))
        records = decode_pack(http("GET", f"v1/pack/{store}/{game}/{exe}/pipelines/{kinds['pipelines']['metal']}/{kinds['pipelines']['table']}"))
        db, binp = write_dxmt_files(work, shaders, records)
        archives = build_exe(args.tool, exe, db, binp, work, sorted({o for o, _ in todo}), sorted({a for _, a in todo}))
        for (o, a), (path, built) in archives.items():
            if (o, a) not in todo: continue
            if args.no_upload: continue
            http("PUT", f"v1/cellar/{store}/{game}/{exe}/{o}/{a}", body=open(path, "rb").read(),
                 headers={"Content-Type": "application/octet-stream", "X-Sommelier-Pipelines": str(built),
                          "X-Sommelier-Signature": signature(path)}, token=args.token)
            print(f"  uploaded {exe} {o} {a}", flush=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tool", required=True, help="the engine's cellar tool")
    ap.add_argument("--token", default=os.environ.get("SOMMELIER_CELLAR_TOKEN"), help="the service's CELLAR_TOKEN")
    ap.add_argument("--os", nargs="+", default=OSES, help="macOS major versions")
    ap.add_argument("--archs", nargs="+", default=ARCHS, help="Apple GPU architectures")
    ap.add_argument("--work", default=os.path.join(tempfile.gettempdir(), "sommelier-cellar"))
    ap.add_argument("--force", action="store_true", help="build even what the service already holds")
    ap.add_argument("--no-upload", action="store_true")
    ap.add_argument("--local", nargs=2, metavar=("SHADERS_DB", "PIPELINES_BIN"), help="build from DXMT's files instead of the service")
    ap.add_argument("--out", help="with --local: where the archives go")
    ap.add_argument("games", nargs="*", help="store:id, e.g. steam:1538550")
    args = ap.parse_args()
    if args.local:
        work = args.out or os.path.join(args.work, "local")
        os.makedirs(work, exist_ok=True)
        build_exe(args.tool, "local", args.local[0], args.local[1], work, args.os, args.archs)
        return
    if not args.games: ap.error("no games given")
    if not args.token and not args.no_upload: ap.error("--token (or SOMMELIER_CELLAR_TOKEN) is needed to upload")
    for g in args.games:
        store, game = g.split(":", 1)
        try: build_game(args, store, game)
        except Exception as e: print(f"{g}: {e}", file=sys.stderr)


if __name__ == "__main__":
    main()
