<p align="center">
  <img src="assets/icon.png" width="128" alt="System Data app icon">
</p>

<h1 align="center">System Data</h1>

<p align="center">
  A menu bar app that shows what is really inside macOS "System Data" and lets you delete it, item by item.<br>
  <a href="https://github.com/Jarvis322/macos-sysdata/actions/workflows/ci.yml"><img src="https://github.com/Jarvis322/macos-sysdata/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-black" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-6-orange" alt="Swift 6">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green" alt="MIT"></a>
</p>

---

Open System Settings > General > Storage on a developer Mac and "System
Data" is often the largest line, with no way to see inside it. Finder puts
everything it cannot attribute to an app, photos or documents in that bucket:
simulator runtimes, Xcode symbol caches, package-manager stores, virtual
machine disks, the unified log, per-app data folders.

This app opens the bucket. It is not a cache cleaner: `~/Library/Caches` is
one small line among fifty, and the app never deletes anything you did not
click.

## What it finds

| Category | Items | Badge |
| --- | --- | --- |
| Time Machine snapshots | local APFS snapshots (`tmutil`) | Safe |
| Simulator devices | per-device caches, unavailable devices, erase a device, system dyld cache | Safe / Review |
| Simulator runtimes | each installed runtime disk image | Review |
| Xcode | DerivedData, DeviceSupport, preview devices, caches, Archives, inactive Xcode.app copies | Safe / Review |
| Package managers | brew, npm, pnpm, yarn, pip, uv, CocoaPods, Gradle, Cargo, SwiftPM, Go, Cypress, Playwright; the whole Homebrew prefix | Safe / Manual |
| Developer tool data | Ollama and Hugging Face models, nvm/rustup/pyenv/rbenv/SDKMAN toolchains, conda, Maven, CocoaPods specs, Gradle distributions, Go modules, Bun, Deno, VS Code and Cursor extensions, Docker CLI, OrbStack, Lima, Colima, Claude Code, Codex; any other hidden home folder over 100 MB | Safe / Review |
| Logs & diagnostics | unified log store (`log erase`), crash reports, ASL, `~/Library/Logs` | Safe |
| Temporary files | `/private/var/folders` user cache and temp, files older than 3 days | Safe |
| Docker | `docker system prune` reclaimable space | Review |
| Trash | `~/.Trash` | Safe |
| iOS device backups | each MobileSync backup with device name and date | Review |
| Shared & other users | `/Users/Shared` app data (BlueStacks and friends), other accounts | Review / Manual |
| Android | AVD emulators, SDK system images, platforms, build tools, NDK, emulator, Android Studio caches | Review / Safe |
| Large app data | Claude VM bundles, Chrome on-device model, any Application Support / Containers / Group Containers folder over 200 MB, caches over 100 MB | Review / Safe |
| Project build folders | `node_modules`, `.build`, `Pods`, `DerivedData` under Desktop, Documents, Developer, Projects | Review |
| System | macOS installers, device firmware, Mail downloads, `/Library/Caches`, `/Library/Application Support`, Command Line Tools, cryptexes, Spotlight index, swap, iCloud local copies | Safe / Review / Manual |
| Other large folders | catch-all: every folder over 500 MB under `~`, `/Library`, `/private/var`, `/opt`, `/usr/local` and `/Users/Shared` that no category above explains, shown with its full path | Review |

**Safe** items are regenerated automatically. **Review** items are deletable
but cost you something (a simulator, a login, a re-download). **Manual**
items cannot be removed by the app; the info button shows the command or
settings path.

The catch-all pass runs last and takes the longest (it walks the home folder
once). The header shows which phase the scan is in. Folders Finder attributes
to Photos, Music, Movies, Messages, Mail, iCloud Drive and Applications are
skipped because they are not System Data.

## Deleting

- The trash button on a row deletes that item after a confirmation.
- Tick several rows and use **Delete N selected**. Everything that needs root
  is folded into one script, so the administrator password is asked once per
  batch. **Select safe** ticks everything that regenerates on its own.
- The folder button reveals the item in Finder. Every row shows the size
  measured on disk, not an estimate.

## Install

Build from source (Xcode 16 or later):

```bash
git clone https://github.com/Jarvis322/macos-sysdata.git
cd macos-sysdata
scripts/build-app.sh
open build/SysDataMenu.app
```

Move `build/SysDataMenu.app` to `/Applications` if you like; the app has a
**Launch at login** switch in its footer.

For development, `swift run SysDataMenu` starts it without a bundle and
`swift test` runs the probe tests against your machine (the log prints the
full inventory it found).

## Permissions, once

Two things can prompt, and both can be settled one time:

- **Folder access.** macOS asks per protected folder (Desktop, Documents,
  Downloads, …) and silently hides Mail, Safari and Time Machine data. Grant
  **Full Disk Access** to the app in System Settings > Privacy & Security
  instead; the app shows a banner with a button until that is done. macOS
  quits the app when the grant is toggled, so reopen it afterwards. The grant
  is remembered by code-signing identity, which is why `scripts/build-app.sh`
  signs with your Developer ID or Apple Development certificate when one is
  in the keychain. An ad-hoc signature changes on every build and macOS would
  forget the grant each time. Override with `CODESIGN_IDENTITY="..."`.
- **Administrator password.** Needed for root actions. Batch them (above) to
  be asked once per batch. Avoiding the prompt entirely would require a
  privileged helper daemon, which is deliberately out of scope for a small
  tool.

## How it works

`Sources/SysDataMenu/Probes` holds one `StorageProbe` per category. Each
probe measures its locations with a single filesystem enumeration
(allocated blocks, no symlink traversal, the same numbers Finder uses) and
returns `StorageItem`s with a name, a size, a safety level and a
`ReclaimAction`: remove paths, empty directories, prune by age, run a tool's
own clean command, or run a script as root through the system authorization
dialog. Probes never mutate anything; `Reclaimer` is the only place that
deletes.

The catch-all probe receives every path the other probes claimed and reports
whatever large folder is left, so the inventory stays complete on machines
with software the app has never heard of. Adding a category means adding one
probe and registering it in `ScanModel`.

## CLI

`sysdata` is a bash script covering the Safe categories only, for machines
where you would rather not run an app:

```bash
./sysdata              # scan
./sysdata clean        # dry run
./sysdata clean --yes  # apply
```

## Requirements

macOS 14 or later. Xcode 16 or later to build. Xcode command line tools for
the simulator and Xcode categories; other tools are optional and skipped when
absent.

## License

MIT. Made by [@yigitech](https://x.com/yigitech).
