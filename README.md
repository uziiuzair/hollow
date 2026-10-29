# Hollow

Hollow is a menu bar disk-space app for macOS. It shows how much space is free as a ring in the menu bar, and opens a dropdown that lists what changed on your disk since you last looked. A full-window treemap with a side list shows where the space went. Cleanup suggestions collect items into a basket, and nothing moves to the Trash until you have reviewed it.

## Why

Hollow is fast, never freezes, and stays live. It reads the disk once, then follows changes through FSEvents, so the numbers stay current without rescanning.

## Requirements

macOS 14 or later.

## Install

Download Hollow from the home page: https://uziiuzair.com/software/hollow

## Full Disk Access

macOS keeps Mail, Messages, Safari and some app data private until you allow Full Disk Access. Hollow asks for it so it can measure those folders. Without it the app still works, but those folders show as "Can't read" and their space counts as Other. You can grant it in System Settings, under Privacy & Security, Full Disk Access.

## Privacy

Hollow makes no network connections. The source has no networking code (no URLSession, NWConnection or similar, and no http URLs). The only URL it opens is the System Settings link for Full Disk Access, which is handled by macOS.

## Build from source

You need Swift 6 and macOS 14 or later.

```
scripts/make-app.sh debug      # or: release
swift test
```

`make-app.sh` builds `.build/Hollow.app`. The package also contains the `DiskEngine` and `DiskApp` libraries and the `diskscan` command line tool.

## Releasing

See [docs/release.md](docs/release.md).

## License

GPLv3 (GPL-3.0-or-later). See [LICENSE](LICENSE). Home page: https://uziiuzair.com/software/hollow

Copyright 2026 Uzair Hayat
