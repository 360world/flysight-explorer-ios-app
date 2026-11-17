# FlySight Explorer

[![CI](https://github.com/360world/flysight-explorer-ios-app/actions/workflows/ci.yml/badge.svg)](https://github.com/360world/flysight-explorer-ios-app/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

An iOS app for the FlySight 2 GPS logger: download jumps over Bluetooth,
analyse them, show a live HUD and configure the device — all from your phone,
no card reader or computer needed.

*iOS alkalmazás a FlySight 2 GPS-loggerhez: ugrásadatok letöltése Bluetooth-on,
elemzés, HUD-megjelenítés és az eszköz konfigurálása — mindezt a telefonról,
kártyaolvasó és számítógép nélkül.*

## Documentation

- **User guide:** [English](docs/user-guide.md) · [Magyar](docs/user-guide.hu.md)
- **Technical overview** (Hungarian): [ARCHITEKTURA.md](ARCHITEKTURA.md)

## Building

Requirements: Xcode 26.5 or newer, iOS 26.5 SDK.

1. Clone the repo and open `FlysightExplorer_ios.xcodeproj`.
2. **Simulator:** select the `FlysightExplorer_ios` scheme and run. No signing setup needed.
3. **Your own iPhone** (needed for Bluetooth):
   ```bash
   cp Config/Local.xcconfig.example Config/Local.xcconfig
   ```
   Edit `Config/Local.xcconfig` and set your own `DEVELOPMENT_TEAM` and a unique
   `APP_BUNDLE_ID`. This file is git-ignored, so you never have to touch the
   Xcode project's signing settings (please don't commit changes to them).

Run the unit tests with **⌘U** in Xcode, or:

```bash
xcodebuild test -project FlysightExplorer_ios.xcodeproj -scheme FlysightExplorer_ios \
  -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO
```

## Contributing

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).
Security issues: see [SECURITY.md](SECURITY.md).

## Releases

The App Store version is built and signed by 360world from tagged commits on
`main`; see [RELEASING.md](RELEASING.md). Signing credentials are never stored
in this repository.

## License

[Apache License 2.0](LICENSE). "FlySight" is a trademark of its respective
owner; this project is not affiliated with or endorsed by the FlySight project.
