# BC125AT CPS

> [!WARNING]
> **This is Claudeslop.** Nearly all of this app — the code, the protocol work, and this README —
> was written by Claude, with a human pointing at things and plugging in the scanner. It works on my
> scanner and I use it, but it's lovingly vibe-coded, so keep a backup and set your expectations
> accordingly.

A native macOS app for programming the **Uniden BC125AT** handheld scanner over USB: read the
scanner, edit its 500 channels and settings, and write the changes back.

- **Read from Scanner** loads every channel, bank, search, Close Call and lockout setting in about 2 seconds.
- **Edit** in a spreadsheet-style table: type into cells, drag channels between slots and banks,
  bulk-edit selections, and copy and paste with Numbers or Excel. Every edit can be undone.
- **Write to Scanner** shows exactly what will change, backs up the scanner first, writes only
  the differences, then reads the scanner back to check every one.
- **Checks before writing.** The app knows the scanner's limits, such as 16-character names, one
  priority channel per bank, and 100 global lockouts. It also knows the scanner's channel step plan,
  so it tells you when a frequency will be stored differently (for example, 154.0062 MHz is stored
  as 154.0025).
- **Live bar** along the bottom of the window: what the scanner is receiving right now, the last
  transmission heard, **Scan** and **Hold** buttons, and volume and squelch sliders that change
  the scanner as you drag. Right-click a channel and choose **Listen on Scanner** to hold the
  scanner on it.
- **Compare with Scanner** (⇧⌘D) lists how the scanner differs from your document without writing.
- Saves configurations as `.bc125at` files, and imports and exports CSV (including bc125py's CSV).
- Opens and saves files from Uniden's own BC125AT software (`.bc125at_ss`, **File ▸ Import Uniden File…**
  and **Export as Uniden File…**), so you can move between the two.

Requires macOS 15 or later and a BC125AT connected with a USB data cable. No driver is needed.

## Installing

Download `BC125AT-CPS-<version>.zip` from the project's GitHub Releases page, unzip it, and
move **BC125AT CPS** to your Applications folder. The app is signed and notarized by Apple, so it
opens like any other.

## Using it

1. Connect the scanner. The toolbar shows **BC125AT** with a green dot.
2. Choose **Scanner ▸ Read from Scanner** (⇧⌘R). The scanner shows "Remote Mode" while it's read.
3. Edit channels in the table, or open the inspector (⌥⌘I) for the selected channel. The issues
   button in the toolbar lists anything the scanner would reject or change.
4. Choose **Scanner ▸ Write to Scanner** (⇧⌘U), review the changes, and click **Write**.
5. After reading or writing, the scanner goes back to what it was doing: scanning, or holding on
   the same channel.

Before every write, the scanner's current contents are saved as a `.bc125at` file. To find them,
choose **Scanner ▸ Show Backups in Finder**; open one and write it to go back. The newest 50 are
kept (change this in **Settings**). If the scanner is ever left showing "Remote Mode", choose
**Scanner ▸ Release Scanner**.

## Command-line tool

`bc125at-cli` (also on the releases page) reads and writes the same files from Terminal:

```sh
bc125at-cli info                       # model and firmware
bc125at-cli read my-scanner.bc125at    # save the scanner's configuration
bc125at-cli write my-scanner.bc125at   # show what would change
bc125at-cli write my-scanner.bc125at --yes --backup before.bc125at
bc125at-cli write my-scanner.bc125at_ss    # Uniden's files work too
bc125at-cli convert my-scanner.bc125at_ss my-scanner.bc125at   # convert formats
bc125at-cli release                    # take a stuck scanner out of program mode
bc125at-cli mode                       # scanning, or holding on which channel
bc125at-cli scan                       # resume scanning
bc125at-cli hold 133                   # hold on channel 133
```

## Building from source

```sh
cd BC125ATKit && swift test            # the protocol and model library, with 74 tests
open "BC125AT CPS.xcodeproj"           # the app
scripts/release.sh                     # from a clean checkout of HEAD: test, archive, sign with a Developer ID, notarize, zip into dist/
scripts/release-unsigned.sh            # the same, but signed ad hoc and not notarized
```

Pushing a version tag (`git tag -s v1.1.0 && git push origin v1.1.0`) runs the same script on GitHub
Actions and attaches the zips to that tag's release. The tag has to be `v` plus the app's three-field version (`MARKETING_VERSION`, e.g. `1.1.0`).

`SPEC.md` describes the design and the BC125AT's serial protocol as measured on real hardware,
including the quirks Uniden's documentation gets wrong. `phase0/` has the raw measurements.

## Acknowledgements

The protocol notes start from Uniden's *BC125AT Operation Specification* and were cross-checked
against [bc125py](https://github.com/itsmaxymoo/bc125py) by Max Loiacono (MIT); see `NOTICE`.
Not affiliated with or endorsed by Uniden.

## License

MIT. See `LICENSE`.
