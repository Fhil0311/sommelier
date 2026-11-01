# Sommelier

A Mac app that plays Windows games from Steam, Epic, GOG and other stores on Apple Silicon and Intel Macs.

**[Download Sommelier](https://playsommelier.com/download)**, signed and notarized by Apple, or read more at
[playsommelier.com](https://playsommelier.com). Which games run: [playsommelier.com/games](https://playsommelier.com/games/).

This repository holds the core that decides *how* a game runs: the Wine engines, the graphics backends (DXVK,
D3DMetal, WineD3D, DXMT), the environment each game gets, the store integrations, saves and controllers.

The app is in `App/`; the core it is built on is the Swift package `SommelierKit` in `Sources/`.

## Repository layout

| Folder | What it is |
|---|---|
| `Sources/SommelierKit/Wine` | Engines, environments ("bottles"), graphics backends, the launch environment (`WineRunner`) |
| `Sources/SommelierKit/Library` | Game detection, including what a game's files say about its graphics (`GraphicsProbe`) |
| `Sources/SommelierKit/Stores` | Steam, Epic (via Legendary), GOG, Ubisoft Connect and EA app |
| `Sources/SommelierKit/Engine` | Engine download and checks, D3DMetal set-up |
| `server/api`, `server/decanter` | The service (Cloudflare Workers): compatibility reports, lists, shared shaders |
| `Sources/SommelierKit/Saves`, `Playtime`, `Shortcuts` | Save backups, play time, game links |
| `engine/` | How the engines are built from pinned upstream releases, and their license texts |

## Build

Needs macOS 15 and Xcode 16 or later (the Command Line Tools alone can build the package but not run its tests).

```bash
brew install xcodegen
swift test                     # SommelierKit's unit tests
xcodegen generate              # the app's Xcode project from project.yml
xcodebuild -project Sommelier.xcodeproj -scheme Sommelier -configuration Debug -derivedDataPath build/DerivedData build
cd server/api && npm install && npm test    # the API's tests (Node 22)
```

A Debug build is "Sommelier Dev": its own bundle identifier, data folder (`~/Library/Application Support/Sommelier Dev`)
and link scheme, so it runs beside an installed Sommelier without touching its games or settings. It signs to run on
this Mac only; to sign with your own Developer ID, put it in `Config/Signing.local.xcconfig` (see
`Config/Sommelier.xcconfig`). The Debug build reads engines and updates from a local API (`npx wrangler@4 dev --port
8788` in `server/api`).

The engines are built separately:

```bash
brew install mingw-w64 bison pkgconf freetype gnutls sdl2
./engine/build-engine-d3dmetal.sh   # Wine from CrossOver's published source, DXMT, the runtimes
```

Game art (the covers on the signed-out pages) is not in this repository; see NOTICE.

## Contributing

Issues and pull requests are welcome; read [CONTRIBUTING.md](CONTRIBUTING.md) first. Every commit needs a
`Signed-off-by` line (the Developer Certificate of Origin). Security problems go privately, see
[SECURITY.md](SECURITY.md).

## License

Sommelier is free software under the GNU General Public License, version 3 or later ([LICENSE](LICENSE)); the small
programs in `engine/` that run inside Wine are under the LGPL 2.1 or later, as Wine is. The name and the logo are not
covered: a version you share must use its own ([TRADEMARKS.md](TRADEMARKS.md)). Third-party software and data are
listed in [NOTICE](NOTICE) and `engine/licenses`.
