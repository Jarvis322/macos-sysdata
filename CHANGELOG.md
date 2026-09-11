# Changelog

What changed in each release, and where it is worth saying, why.

Versions up to and including v0.3.7 were released under the MIT License; see
[LICENSE](LICENSE).

## v1.1.0 — 2026-09-12

- **The folded list is now a map of the disk.** Categories start folded and,
  once a scan finishes, are listed largest first. Each header carries a bar:
  the category's size next to the largest one, split into Safe, Review and
  Manual in the badges' own colours. A category that has grown well past its
  recent size gets an amber mark with the amount. A single line above the list
  sums up System Data, free space and the change over the past week. This
  replaces the multicoloured bar from 1.0, whose colours meant nothing beyond
  telling categories apart.
- **Unusual growth notification**, optional: after the daily scan, a
  notification when a category is at least 50% and 2 GB above its median over
  its last 14 scans, and not again for that category until it has grown another
  2 GB.
- **Expand all / Collapse all** beside the sort control. Categories fold shut
  on the first scan only, so a background scan never closes what you opened.
- **Select safe** opens the categories it selects in, rather than ticking rows
  inside folded groups where nobody can see them.

## v1.0.6 — 2026-09-11

- **Updating from 1.0.4 or earlier left the app hidden.** The 1.0.5 image
  carries a hidden copy under the old name for updaters from before the
  rename, and those updaters copied the hidden flag along with it: the app
  relaunched, but no longer appeared in Applications, Launchpad or Spotlight,
  and once quit it looked like it would not open. The app now clears the flag
  on itself at launch. An install already hidden by 1.0.5 is replaced by a
  visible one on its next update. To fix one now:
  `chflags nohidden /Applications/SysDataMenu.app`.

## v1.0.5 — 2026-09-11

- **The app is now called System Data Unpacked**, Unpacked for short.
  "SysDataMenu" was a working name that stuck. The bundle identifier, the
  Homebrew cask (`jarvis322/tap/sysdata`) and the `SysDataMenu` command-line
  binary are unchanged, so Full Disk Access, settings, history and scripts
  carry over. `brew upgrade` swaps the old app for the new one.
- The updater finds the app in a downloaded image by bundle identifier rather
  than by its own file name, and installs it under the new name. Versions up
  to 1.0.4 still look for `SysDataMenu.app`, so the image carries a hidden copy
  under that name for them; their next update after this one moves them to the
  new name.
- The README says how to fix `brew install` stopping with "It seems there is
  already an App" after a disk-image install: `--adopt`.

## v1.0.4 — 2026-09-11

- **A crash when scrolling the list during a scan.** On macOS 26.5.2 the panel
  could quit with `NSGenericException` while rows were still arriving: a
  reproduction and the original crash report in
  [#18](https://github.com/Jarvis322/macos-sysdata/pull/18) by @dzy1997 showed
  SwiftUI's `List`, an NSTableView underneath, re-measuring its rows inside the
  window's constraint pass until AppKit gave up. The list is now built from a
  lazy stack with the same insets and separators, so that table path is gone.
  It could not be reproduced on macOS 26.6 or later, so the fix is not yet
  confirmed on an affected machine.

## v1.0.3 — 2026-09-11

- **A batch now reports every item that failed, not only the last.** Two
  simulators failed to erase in a batch that otherwise worked; the footer
  showed at most one of them, and both came back on the next scan as if the
  click had been ignored.
- **Erasing a simulator shuts down only that device**, then erases it, and
  retries once if it was booted again in between. When it still refuses, the
  message says the simulator is running and to quit Simulator and Xcode.
  Before, every open simulator was shut down for each erase.
- An erased simulator no longer comes back as a row. Erasing keeps the device
  at a few megabytes, which read as a delete that had not happened; devices
  under 100 MB are no longer listed.

## v1.0.2 — 2026-09-11

- `~/Library/Daemon Containers`, where macOS's own background services keep
  their data, was listed by the catch-all with a Review badge. It is now a
  named System row, "macOS service data", shown with its size and marked
  Manual, the same as Apple's app containers since 1.0.1.

## v1.0.1 — 2026-09-11

- **Apple's own app data is no longer offered for deletion.** With Full Disk
  Access, the scan listed every folder in `~/Library/Containers` and
  `~/Library/Group Containers` with a Review badge, Apple's included — and
  those hold the local copy of what syncs with iCloud: Notes, Reminders,
  Messages. A user noticed their iCloud data in the list. Apple's containers
  are now shown with their size but marked Manual: the app will not delete
  them, and says to clear them from the app that owns them.
- The "anything over 500 MB" scan no longer walks `~/Library/CloudStorage`,
  where Dropbox, OneDrive, Google Drive and other sync services keep their
  files. A delete there is a delete in the cloud account too.

## v1.0.0 — 2026-09-10

The app has found what is in System Data for a while. 1.0 is about what
happens after the first clean.

- **Weekly summary.** Optional: once a week, if System Data has grown by more
  than 2 GB, a notification says by how much and which item grew most.
- **A trend on every row.** A small line beside the size shows where each item
  has been heading over recent scans, drawn only once there are three points.
- **One tap when space runs low.** Below the warning threshold the window
  offers to free the safe items — regenerating caches that need no password —
  in one press.
- **Automatic clean, opt-in.** Once a week, delete the Safe items and say what
  was freed. The narrowest exception the app allows to its rule of never
  deleting what you did not click: nothing marked Review, nothing that needs a
  password, never on a scan you are watching.
- **Safe items to the Trash, if you prefer.** An undo window for the items that
  are normally deleted outright.
- **Choose what the menu bar shows:** System Data size, free space, or the icon
  alone.
- **A breakdown bar** above the list: how the total splits across categories,
  at a glance.
- **Nine languages.** German, French, Spanish, Korean and Russian join English,
  Turkish, Simplified Chinese and Japanese. The five new ones are
  machine-assisted; native corrections are welcome.
- A [website](https://jarvis322.github.io/macos-sysdata/), a contributing
  guide, and issue and pull request templates.

## v0.5.2 — 2026-09-08

- **The "over 500 MB" scan could run for a day and never finish.** The
  catch-all walked every mounted volume it could reach — an external drive, a
  Time Machine backup with millions of hard-linked files, a home folder
  relocated onto a large disk. On a Mac mini with a 10 TB HDD and a Time
  Machine volume it ran 24+ hours, and until it finished the list and its
  controls never became usable. It now stays on the startup volume: a root
  that lives on another disk is skipped, and the walk never crosses onto one.
  The targeted probes still measure known caches wherever they are.

## v0.5.1 — 2026-09-08

- The footer button beside **Delete N selected** was called **Clear**, which
  in a cleaner reads as the app's own verb rather than "untick the selection".
  It is now **Deselect**, in all four languages, with a tooltip saying it
  deletes nothing. The button that frees space is, and always was, the red one.

## v0.5.0 — 2026-09-08

- **Simplified Chinese and Japanese.** The app now ships in four languages —
  English, Turkish, Simplified Chinese and Japanese — each covering all 135
  interface strings, with format placeholders preserved (including the ones
  the two new languages reorder). Chinese is from [#19](https://github.com/Jarvis322/macos-sysdata/pull/19)
  by @Mavlan, a native speaker; Japanese follows the same terminology
  conventions macOS itself uses.
- Recorded a scroll-during-scan crash investigation from
  [#18](https://github.com/Jarvis322/macos-sysdata/pull/18) by @dzy1997 in
  `docs/`; no code change, since it does not reproduce on macOS 26.6 and the
  List, its styling and virtualization are worth keeping until there is a
  failing case to fix against.

## v0.4.7 — 2026-09-07

- The Homebrew cask's `zap` removed the preferences file and left the other
  three, including the scan history — the one artefact that records paths, so
  the one worth being thorough about. It now removes everything.
- The README says how to uninstall, what the four files are, and which two
  grants outlive the app because macOS keeps them rather than the app.

## v0.4.6 — 2026-09-07

- This changelog. Releases now refuse to go out without a section, and use it
  as their notes: a list of commit subjects says what was touched, not what
  changed for anyone using the app.

## v0.4.5 — 2026-09-07

- Put back the explanations that moving the preferences into a menu had
  silently dropped, including the one saying the update check is the only
  request the app makes. A catalogue key nothing references is invisible to
  the compiler and to every test; there is now a test that fails on one.

## v0.4.4 — 2026-09-07

- **Copy** on the confirmation puts the whole plan on the pasteboard. A list
  that scrolls inside 120pt usually has to be read somewhere else, and
  selecting fifty lines by hand inside a scroll view is not a way to do that.
  ([#17](https://github.com/Jarvis322/macos-sysdata/pull/17) by
  @peechycreation)
- The confirmation counted "N items need root" from actions whose *type* was
  a privileged script, which is not the set that prompts: a plain delete of a
  root-owned path falls back to `rm -rf` as root and asks too. It also
  promised the password would be asked once, which is true of the scripts —
  they are folded into one — and not of those deletes, which each ask again.
  Both fixed.

## v0.4.3 — 2026-09-07

- The selection survives the filter. Ticking **Select safe** and then
  filtering to untick two of them is how the two controls are meant to work
  together, and clearing on the first keystroke made it impossible. The
  danger it was guarding against is answered where it lives: the footer says
  how many selected rows are not on screen, beside the button that would take
  them. ([#16](https://github.com/Jarvis322/macos-sysdata/pull/16) by
  @peechycreation, walking back their own guard from #8)
- Folding a category keeps its selection too, and counts toward the same
  figure. A fold and a filter do the same thing to a row, so they answer for
  it the same way.
- **Select safe** unticks on a second press, and the button says which way it
  will go.

## v0.4.2 — 2026-09-07

- Stopped asking for permissions that one grant covers. Reading another app's
  container is one dialog per app, and the scan walked `~/Library/Containers`
  on launch — so a first run produced a queue of them naming Music, Photos
  and everything else, for a grant that would have covered them at once.
  Every protected location is left alone until Full Disk Access exists, and
  the banner says so. Reported by a user on the day it shipped.
- The window fills as the scan runs. Every probe's findings used to be
  assigned in one go at the end, so a slow first scan could not be told apart
  from a stuck one.

## v0.4.1 — 2026-09-07

- Rows carry one icon at rest instead of four; reveal, hide and the breakdown
  chevron appear on hover, and right-click reaches them without a pointer.
  ([#12](https://github.com/Jarvis322/macos-sysdata/pull/12) by
  @peechycreation)
- A category whose sizes are all unmeasurable shows "—" rather than "0 bytes"
  — it was the only place in the window where a header contradicted its rows.
  ([#13](https://github.com/Jarvis322/macos-sysdata/pull/13) by
  @peechycreation)
- A pnpm store left behind by an uninstalled pnpm is found by its default
  path, since `pnpm store path` is exactly what is missing then.
  ([#11](https://github.com/Jarvis322/macos-sysdata/pull/11) by
  @peechycreation). It is marked Review rather than Safe: not finding the
  command is not the same as it not being installed, and when the app is
  inferring, the reversible option is the correct one. `Shell.which` also
  learned about Volta, asdf, mise, fnm, nvm, bun and deno, which every other
  package cache benefits from.

## v0.4.0 — 2026-09-07

- **Idle time.** Rows past a fortnight say how long they have sat untouched,
  and the list can be sorted by it. Size cannot tell a build folder for
  today's work apart from one for a project abandoned two years ago.
- **History.** Each scan and deletion is recorded locally, so the list shows
  growth beside each size and a history view can answer what came back, what
  grew most, and what was deleted. Off-switch deletes the file.
- **Low space warning.** Optional and off by default. It only ever tells you.
- **The confirmation shows every command verbatim** before anything runs,
  including the ones that will run as root.
- Measured the purgeable pool rather than building a feature on it, and
  explained the figure instead. Writing 6.44 GB cost 6.44 GB of real free
  space and took nothing from the 3.55 GB pool, which then refilled itself.
  See [docs/purgeable-measurement.md](docs/purgeable-measurement.md).
- The preferences moved from a row of switches into a menu; a fourth switch
  did not fit at this width.

## v0.3.13 — 2026-09-07

- The release-download test, which is the only way the updater's redirect
  handling can be exercised at all.

## v0.3.12 — 2026-09-07

- **The updater could not install anything.** GitHub answers a release
  download with a redirect to `release-assets.githubusercontent.com`, which
  is not a `github.com` subdomain, so the post-redirect check refused every
  real update: the banner appeared, the button was pressed, and it failed.
  Present in 0.3.10 and 0.3.11 — those cannot install this one; use
  `brew upgrade --cask sysdata` or the disk image.
- The host check accepted lookalike domains such as `notgithub.com`, on the
  one code path whose job is to replace the running application.
  ([#10](https://github.com/Jarvis322/macos-sysdata/pull/10) by
  @MehmetFurkanAyd1n)

## v0.3.11 — 2026-09-07

- Shift-click range selection, a checkbox on each category header, and
  collapsible categories.
  ([#9](https://github.com/Jarvis322/macos-sysdata/pull/9) by @emreertunc)

## v0.3.10 — 2026-09-06

- The update banner installs the new version rather than linking to it. The
  download is checked three ways before anything is moved: the host, the
  Gatekeeper assessment, and the team identifier.

## v0.3.9 — 2026-09-06

- A filter under the header.
  ([#8](https://github.com/Jarvis322/macos-sysdata/pull/8) by @peechycreation)

## v0.3.8 — 2026-09-06

Seven pull requests, all by @peechycreation:

- **The scan offered the user's own files for deletion** — `~/Desktop` at
  102 GB with a Delete button beside it. Desktop, Documents and Downloads are
  out; the things under them that genuinely are reclaimable each get their
  own named row.
  ([#2](https://github.com/Jarvis322/macos-sysdata/pull/2))
- Trashed bytes were counted as freed space, which they are not until the
  Trash is emptied.
  ([#7](https://github.com/Jarvis322/macos-sysdata/pull/7))
- The web frameworks' build folders.
  ([#3](https://github.com/Jarvis322/macos-sysdata/pull/3))
- The catch-all no longer walks what it will not report.
  ([#4](https://github.com/Jarvis322/macos-sysdata/pull/4))
- Tests for the code that deletes.
  ([#5](https://github.com/Jarvis322/macos-sysdata/pull/5))
- The signing-identity fallback.
  ([#6](https://github.com/Jarvis322/macos-sysdata/pull/6))
- A daily update check, off unless switched on.
- `scripts/ci.sh` runs the same checks locally, since this account's Actions
  are billing-locked.

## v0.3.7 — 2026-09-06

- Universal binary, so Intel Macs can run it.
- Relicensed as proprietary from this version onwards.

## v0.3.6 — 2026-09-06

- Named the AI coding tools' folders rather than reporting them as unknown.

## v0.3.5 — 2026-09-06

- Releases ship a disk image.

## v0.3.4 — 2026-09-06

- Dismissing the password prompt stops the whole batch rather than carrying
  on down the list.

## v0.3.3 — 2026-09-06

- One-command release.

## v0.3.2 — 2026-09-06

First public release: the menu bar total, per-item sizes with safety badges,
trash-first deletes, the breakdown, hidden items, `--json`, a Turkish
interface, and shutting simulators down at power off.
