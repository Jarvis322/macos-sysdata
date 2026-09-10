# Contributing

Thanks for wanting to help. This project is small and opinionated, and the bar
for a change is not "does it work" but "does it fit" — the app values honesty
over feature count, and never deletes anything the person did not choose.

## Before you open a pull request

- **Group your changes.** One pull request per idea, but if you have several
  small fixes, a single pull request with a few commits is far easier to review
  than a stream of separate ones.
- **Run the checks.** `scripts/ci.sh` runs the same universal build, the
  string-catalog consistency check, and the tests that CI would. It must pass.
  Add `SYSDATA_SCAN_TESTS=1` to also run the disk-walking tests.
- **Keep the character.** No feature should delete something the user did not
  click, overstate what it reclaims, or send anything off the Mac. If a change
  measures space, it measures it — it does not estimate and present the estimate
  as fact.

## Code

- Swift 6, SwiftUI, a menu-bar (`MenuBarExtra`) app plus a `--json` CLI mode.
- English only in code, comments, and commits. The interface is localized; the
  code is not.
- Comments explain *why*, not *what*. Match the surrounding style.
- Conventional commit subjects: `fix(scan): keep the catch-all on the boot volume`.

## Translations

The interface lives in `Sources/SysDataMenu/Resources/Localizable.xcstrings`,
which is the single source of truth. The `.lproj` files are generated from it by
`scripts/compile-strings.sh` and checked by `scripts/ci.sh` — never edit a
`.lproj` by hand.

To add or fix a language, edit the catalog (Xcode opens `.xcstrings` with a
translation editor), keep every format specifier (`%@`, `%lld`, and the
positional `%1$@` forms where a language reorders them), run
`scripts/compile-strings.sh`, and commit both the catalog and the regenerated
`.lproj`. Native-speaker corrections to the existing machine-assisted languages
are especially welcome.

## Reporting a bug

Open an issue with your macOS version, what you did, and what happened. If the
app found something it should not offer to delete, or offered a wrong size, a
screenshot of that row tells the whole story.

## License

The project is proprietary; see [LICENSE](LICENSE). By contributing you agree
that your contribution may be included under the project's license.
