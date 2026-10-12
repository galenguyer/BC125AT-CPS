# BC125AT CPS — Native macOS Programming Software

**Status:** Draft v0.3 · 2026-10-12  
**License:** MIT  
**Platform:** macOS 15+  
**Bundle ID:** `net.k9fgt.bc125at`

## 1. Summary

A native SwiftUI app for macOS that reads, edits, and writes the configuration of a Uniden BC125AT handheld scanner over USB. It replaces Uniden's Windows-only BC125AT Sentinel/"SS" software. It should feel like a Mac app: it opens documents, has undo, works with the keyboard, and lets you copy and paste channels between files and spreadsheets.

### Goals
- Read the scanner's full configuration (channels, banks, search/close-call, global lockouts, and system settings) and write it back.
- Edit 500 channels quickly in a spreadsheet-style table.
- Save and open configurations as files, so a user can keep several setups and send them to other people.
- Import and export CSV.
- Show where a file and the connected scanner differ before writing, and write only the changes.
- Stop invalid data at the moment it's entered, so nothing invalid reaches the radio.

### Non-goals (v1)
- Other Uniden models (BC75XLT, BCD436HP, and so on). The protocol layer should still leave room for them (see §6.2).
- Firmware updates.
- RadioReference database lookup (a candidate for v2).
- iOS or iPadOS. USB serial there needs DriverKit or MFi, which is out of scope for now.
- Live remote control or audio. The BC125AT has no status or remote-key commands; a volume/squelch panel is a stretch goal (§8.6).

## 2. Hardware & Connection

| Item | Value |
|---|---|
| Interface | USB CDC-ACM (virtual serial port) |
| USB VID / PID | `0x1965` / `0x0017` (bc125py matches on PID 23 = `0x0017`) |
| Serial | 115200 baud, 8N1, no flow control (**verify**: bc125py uses pySerial's defaults and never sets a baud rate, which suggests the setting is ignored over USB CDC) |
| Framing | ASCII commands ending in `\r`; responses end in `\r` |
| Flow | Strictly one command at a time. Uniden's spec says to wait for each response before sending the next command |
| macOS device | Expected `/dev/cu.usbmodem*`, **unconfirmed and the biggest Phase 0 risk** |

**Driver risk.** On Linux, the kernel's `cdc_acm` driver won't claim the scanner automatically. bc125py works around this by writing `1965 0017 2 076d 0006` to `/sys/bus/usb/drivers/cdc_acm/new_id`. That suggests the scanner's USB descriptors aren't fully standard, so macOS's AppleUSBCDC driver may not claim it either. If no `/dev/cu.*` node appears, the fallback is to talk to the scanner's bulk endpoints directly from user space with IOUSBHost (sandbox entitlement `com.apple.security.device.usb`). That needs no kernel driver. The transport layer is a protocol so either backend can be plugged in.

The app finds the scanner by watching IOKit for the VID/PID pair, so the user never has to choose a port. If several scanners are plugged in, the app shows a picker.

## 3. Protocol Reference

> **Source:** Uniden's *BC125AT Operation Specification*, Appendix C "PC programming Command" (pp. 54–63; a copy is in the bc125py repo at `docs/BC125AT_Protocol.pdf`), cross-checked against bc125py (MIT, commit `b9454ca`, 2026-01-03). Items marked **verify** are either not covered by the spec or contradicted by it, and are checked on hardware in Phase 0 (§10).

Commands marked **P** only work in program mode. Uniden's official list has exactly 24 commands, all in the table below. There is **no** `STS`, `GLG`, `KEY`, or `PWR` on the BC125AT.

| Cmd | Mode | Get → response | Set | Notes |
|---|---|---|---|---|
| `PRG` | – | `PRG` → `PRG,OK` / `PRG,NG` | – | `NG` if the scanner is in Menu mode, Direct Entry, or Quick Save. The display shows "Remote Mode" / "Keypad Lock" |
| `EPG` | – | `EPG` → `EPG,OK` | – | The scanner then goes to **Scan Hold**, not Scan |
| `MDL` | – | `MDL` → `MDL,BC125AT` | – | |
| `VER` | – | `VER` → `VER,Version 1.00.00` | – | |
| `BLT` | P | `BLT` → `BLT,evnt,` | `BLT,evnt` | `AO` always on · `AF` always off · `KY` keypress · `SQ` squelch · `KS` key+squelch. **The response has a trailing comma** |
| `BSV` | P | `BSV` → `BSV,hrs` | `BSV,hrs` | Battery charge time, 1–16 h |
| `CLR` | P | – | `CLR` → `CLR,OK` | Factory-clears all memory. **Takes "dozens of seconds"**, so it needs a long timeout |
| `KBP` | P | `KBP` → `KBP,level,lock` | `KBP,level,lock` | Beep level `0` auto / `99` off; key lock `0`/`1` |
| `PRI` | P | `PRI` → `PRI,mode` | `PRI,mode` | `0` off · `1` on · `2` plus on · `3` DND |
| `SCG` | P | `SCG` → `SCG,##########` | `SCG,##########` | Bank scan enable. **`0` = enabled, `1` = disabled**. Digits in bank order 1…10. The scanner rejects all ten disabled |
| `DCH` | P | – | `DCH,idx` | Delete channel 1–500 |
| `CIN` | P | `CIN,idx` → `CIN,idx,name,frq,mod,tone,dly,lout,pri` | same as response | See §3.1 |
| `SCO` | P | `SCO` → `SCO,dly,code_srch` | `SCO,dly,code_srch` | Search/Close Call delay (same values as channel delay); code search `0` off / `1` CTCSS/DCS |
| `GLF` | P | `GLF` → `GLF,frq` … `GLF,-1` | `GLF,x` → `GLF,OK` | Call repeatedly until `-1`. See §3.3 for how to reset the walk |
| `ULF` | P | – | `ULF,frq` | Remove a global lockout |
| `LOF` | P | – | `LOF,frq` | Add a global lockout |
| `CLC` | P | `CLC` → `CLC,mode,altb,altl,band,lout` | same | Mode `0` off · `1` CC priority · `2` CC DND; alert beep and alert light `0`/`1`; band is 5 digits (§3.4); `lout` = "lockout for CC hits with scan" `0`/`1` |
| `SSG` | P | `SSG` → `SSG,##########` | same | Service search groups, **`0` = enabled**. Order: Police, Fire/Emergency, Ham, Marine, Railroad, Civil Air, Military Air, CB, FRS/GMRS/MURS, Racing |
| `CSG` | P | `CSG` → `CSG,##########` | same | Custom search ranges 1…10, **`0` = enabled** |
| `CSP` | P | `CSP,idx` → `CSP,idx,lo,hi,` | `CSP,idx,lo,hi` | Range index 1–10. **The response has a trailing comma** |
| `WXS` | P | `WXS` → `WXS,pri` | `WXS,pri` | Weather alert priority `0`/`1` |
| `CNT` | P | `CNT` → `CNT,lvl` | `CNT,lvl` | Contrast 1–15. **Out-of-range values are silently replaced with the default**, so validation must catch them |
| `VOL` | – | `VOL` → `VOL,lvl` | `VOL,lvl` | 0–15 |
| `SQL` | – | `SQL` → `SQL,lvl` | `SQL,lvl` | `0` open · 1–14 · `15` closed |

Set commands reply `<CMD>,OK`.

**General rules from the spec:**
- **An empty field in a set command means "leave unchanged".** For example, `CIN,5,,1625500,,,,,` changes only the frequency. Because of this, *clearing* a channel name needs a single space (`CIN,5, ,…`). bc125py fixed exactly this bug in v0.9.
- The scanner rejects the whole set command if any field is malformed. Nothing is partly applied.
- **Errors:** `ERR` means a format or value error, and `NG` means the command isn't allowed right now. The spec shows them as bare `ERR\r` and `NG\r`, but `PRG,NG` has the command prefix. The parser accepts both forms.
- The parser tolerates trailing empty fields (`BLT`, `CSP`).

### 3.1 Channel fields (`CIN`)

| Field | Encoding | Values |
|---|---|---|
| `idx` | int | 1–500 (bank = `(idx-1)/50 + 1`) |
| `name` | ASCII | ≤ 16 chars. **Commas are forbidden** because they're the field separator. Send a single space to clear a name (see above). **Verify:** which characters the scanner accepts and whether it returns a cleared name as `""` or `" "` |
| `frq` | int, **units of 100 Hz, no padding** | `1625500` = 162.5500 MHz (the spec's example is `290000` = 29.0 MHz); `0` = empty channel. Writes send no leading zeros, as bc125py does. The parser accepts any number of leading zeros (**verify** whether responses are zero-padded) |
| `mod` | enum | `AUTO` `AM` `FM` `NFM` |
| `tone` | int code | see §3.2 |
| `dly` | int | `-10 -5 0 1 2 3 4 5` seconds. Negative values are Uniden's "minus delay" modes |
| `lout` | bool | `0` unlocked / `1` locked out |
| `pri` | bool | `0`/`1` (**verify**: whether the scanner allows more than one priority channel per bank. Neither the spec nor bc125py says) |

Being careful, the `CIN` parser reads `idx` from the left and the last 7 fields from the right. Anything in between is the name. So if a name entered on the keypad ever contains a comma, it still parses correctly.

### 3.2 CTCSS/DCS codes (confirmed from the spec, p. 63)

| Code | Meaning |
|---|---|
| `0` | None / All (open squelch) |
| `127` | Search |
| `240` | No tone |
| `64–113` | CTCSS, in order: 67.0, 69.3, 71.9, 74.4, 77.0, 79.7, 82.5, 85.4, 88.5, 91.5, 94.8, 97.4, 100.0, 103.5, 107.2, 110.9, 114.8, 118.8, 123.0, 127.3, 131.8, 136.5, 141.3, 146.2, 151.4, 156.7, 159.8, 162.2, 165.5, 167.9, 171.3, 173.8, 177.3, 179.9, 183.5, 186.2, 189.9, 192.8, 196.6, 199.5, 203.5, 206.5, 210.7, 218.1, 225.7, 229.1, 233.6, 241.8, 250.3, 254.1 Hz |
| `128–231` | DCS, in order: 023 025 026 031 032 036 043 047 051 053 054 065 071 072 073 074 114 115 116 122 125 131 132 134 143 145 152 155 156 162 165 172 174 205 212 223 225 226 243 244 245 246 251 252 255 261 263 265 266 271 274 306 311 315 325 331 332 343 346 351 356 364 365 371 411 412 413 423 431 432 445 446 452 454 455 462 464 465 466 503 506 516 523 526 532 546 565 606 612 624 627 631 632 654 662 664 703 712 723 731 732 734 743 754 |

Any other value, such as `1–63`, `114–126`, or `232–239`, is invalid. bc125py's mapping table matches the spec exactly.

### 3.3 Global lockout list
- `GLF` is a cursor: each call returns the next locked-out frequency, then `-1`.
- bc125py resets the cursor by sending `EPG` then `PRG` before each walk. The spec instead says `GLF,<anything>` (reply `GLF,OK`) prepares to "retrieve the 1st L/O frequency". **Verify** that `GLF,0` resets the cursor. If it does, use it, because it avoids the scanner leaving and re-entering program mode.
- Writing compares the lists and sends only the needed `ULF`/`LOF` commands. bc125py instead unlocks everything and locks the full list again.
- The maximum number of lockouts isn't documented (**verify**).

### 3.4 Bit masks: watch the polarity

| Command | Digits | `0` means | `1` means | Order |
|---|---|---|---|---|
| `SCG` | 10 | enabled | disabled | banks 1…10 |
| `SSG` | 10 | enabled | disabled | Police … Racing (see table) |
| `CSG` | 10 | enabled | disabled | custom ranges 1…10 |
| `CLC` band | 5 | **off** | **on** | VHF Low1, Air, VHF High1, VHF High2, UHF |

At least one item must stay enabled in `SCG`. The spec also says this for `SSG`/`CSG`, though its wording there is garbled ("can not set all … to '0'"). bc125py enforces at least one enabled for all three, and so will we. **Verify** what the scanner does if all are disabled. The Close Call bands may all be off.

### 3.5 Valid frequency ranges
25.0000–54.0000, 108.0000–174.0000, 225.0000–380.0000, and 400.0000–512.0000 MHz, inclusive. The spec and bc125py's tests agree. The app refuses frequencies outside these ranges outright, and also warns when a frequency isn't on a valid channel step for its band. Neither source gives the step rules (**verify** against the band plan in the BC125AT owner's manual; I recall 5, 6.25, 8.33, and 12.5 kHz steps, but that is unconfirmed). Until that's confirmed, the off-step check is only a warning.

### 3.6 Factory default custom search ranges
From bc125py's defaults (**verify** against your scanner's `CSP` readout). The app uses these as the defaults for a new, empty document:

| # | Range (MHz) | # | Range (MHz) |
|---|---|---|---|
| 1 | 25.0000–27.9950 | 6 | 137.0000–143.9950 |
| 2 | 28.0000–29.6950 | 7 | 144.0000–147.9950 |
| 3 | 29.7000–49.9950 | 8 | 225.0000–380.0000 |
| 4 | 50.0000–54.0000 | 9 | 400.0000–449.9937 |
| 5 | 108.0000–136.9916 | 10 | 450.0000–469.9937 |

## 4. Data Model

These are plain `Codable`, `Sendable`, `Equatable` value types in a UI-free package:

```swift
struct ScannerConfig {
    var channels: [Channel]            // always exactly 500, index-stable
    var bankScanEnabled: [Bool]        // 10
    var settings: SystemSettings       // backlight, beep, keylock, contrast, battery, priority, weather, volume, squelch
    var search: SearchSettings         // SCO + SSG + CSG + 10 CustomRange (defaults per §3.6)
    var closeCall: CloseCallSettings
    var globalLockouts: [Frequency]    // sorted, unique
    var bankNames: [String]            // 10 — app-only metadata, never sent to the radio
    var metadata: DocumentMetadata     // firmware version read from, timestamps, notes
}

struct Channel { var name: String; var frequency: Frequency?; var modulation: Modulation
                 var tone: ToneCode; var delay: Delay; var lockedOut: Bool; var priority: Bool }

struct Frequency: Comparable { var hundredHz: UInt32 }   // = the wire value; exact integer math, no floating point
enum ToneCode { case none, search, noTone, ctcss(index: Int), dcs(index: Int) }  // index into the §3.2 tables; raw code is computed
```

Each model type has its own `validate() -> [ValidationIssue]`. An issue is either an `.error`, which blocks writing, or a `.warning`, which only advises.

## 5. File Formats

| Format | Purpose |
|---|---|
| `.bc125at` (native) | A JSON-encoded `ScannerConfig` with a format version. UTType is `net.k9fgt.bc125at.config`. |
| CSV | Import and export channels. The columns are `Channel,Bank,Name,Frequency,Modulation,Tone,Delay,Lockout,Priority`. Tones are written in readable form (`CTCSS 100.0`, `DCS 023`). |
| Uniden `.bc125at_ss` | Import only. A nice-to-have, planned after v1 (milestone 6). The format will be reverse-engineered from sample files the maintainer exports from Uniden's software. |

## 6. Architecture

```
BC125ATKit (Swift package, no UI)
├── Transport      SerialPort (POSIX termios on a dedicated thread) · MockTransport
├── Protocol       Command enum → encode / decode · response parser · error types
├── Model          ScannerConfig and friends, validation, tone tables
├── Sync           ScannerSession actor: connect, readAll, diff, write(changes), progress
└── Formats        native JSON, CSV
BC125ATCPS (SwiftUI app)
└── DocumentGroup + FileDocument, views, and the device-discovery observer
```

### 6.1 Concurrency
- `ScannerSession` is an `actor`. It owns the port and runs one command at a time, as Uniden's spec requires. Each command has a timeout (default 1 s; `CLR` 120 s, because the spec says it takes "dozens of seconds"). A timed-out read is retried once, but only for get commands. A set command that times out is never sent again blindly: the session reads the item back to find out whether it was applied.
- Long jobs (reading all, writing) report progress through an `AsyncStream<SyncProgress>` and can be cancelled. On cancel or any error, the session always sends `EPG` so the radio isn't left stuck in program mode.
- Built with Swift 6 strict concurrency.

### 6.2 Extensibility
Commands are described by a `ScannerModel` protocol: channel count, bank count, ranges, and which commands it supports. This keeps a second model possible later without generalizing everything now.

### 6.3 Sandbox & Distribution
- The app is sandboxed with the `com.apple.security.device.serial` entitlement and user-selected file read/write access.
- It's distributed as a zipped `.app` attached to GitHub Releases. It isn't on the Mac App Store.
- **No paid Apple Developer account yet**, so release builds are **ad-hoc signed and not notarized**. The README will explain how to get past Gatekeeper: on macOS 15, open System Settings → Privacy & Security → "Open Anyway", or run `xattr -dr com.apple.quarantine`. If we sign up for a developer account later, the only change is adding a Developer ID signing and `notarytool` step to the release script.
- Releases are built by a local script, `scripts/release.sh`, that runs `xcodebuild archive`, signs ad-hoc, and zips the app. CI on GitHub Actions can come later, once the repo is published.

## 7. Sync Behavior

1. **Read from Scanner**: runs `PRG`, reads every section, then `EPG`. If `PRG` returns `NG`, the app tells the user to leave the menu on the scanner and try again. This takes about 520 round trips, and the target is under 15 s. The result opens as a new untitled document, or replaces the current one after a confirmation.
2. **Write to Scanner**:
   1. Validate the document. Any errors stop the write.
   2. Read the scanner's current state, or reuse a cached read from this session if it's still fresh.
   3. Work out the diff and show a review sheet listing the changes by section (for example "37 channels changed, 2 lockouts added").
   4. Write only the changed items, read each one back, and check it.
   5. Report the result. A partial failure lists exactly which items didn't match.
3. **Never send `CLR`** except through an explicit "Factory Clear Scanner…" menu item that requires typing a confirmation.
4. **Release Scanner** (menu item): sends `EPG` on its own, to recover a scanner left stuck in program mode by a crash or an unplugged cable. bc125py has the same feature, its `unlock` command.
5. **After writing**, the scanner sits in Scan Hold (`EPG` doesn't resume scanning). The completion message tells the user to press Scan.
6. **Automatic backup**: every write first saves the scanner's previous state to `~/Library/Application Support/BC125AT CPS/Backups/<timestamp>.bc125at`.

## 8. User Interface

### 8.1 Window layout
- **Sidebar**: Channels (with banks 1–10 nested, each showing its scan-enabled toggle and a count of channels in use), Search & Close Call, Global Lockouts, Settings.
- **Detail**: the editor for the selected section.
- **Toolbar**: connection status (scanner name, firmware, connected or disconnected), Read, Write, and a Validation issue count that opens an issues popover.
- **Inspector** (optional, ⌥⌘I): full details for the selected channel or channels.

### 8.2 Channel table
- A SwiftUI `Table` that shows all 500 rows or one bank, with sortable columns.
- Cells edit inline. The frequency field accepts `162.55`, `162550k`, and similar forms and normalizes them. Invalid cells get a red badge with a tooltip.
- Selecting several rows allows bulk edits: modulation, tone, delay, lockout, and "Clear".
- Copy and paste uses TSV on the pasteboard, so it works with Numbers and Excel. Pasting into a selection fills consecutive slots.
- Rows can be dragged to reorder within or between banks. Moving a channel moves its whole record.
- Cmd-F filters by name or frequency.
- Every edit can be undone through the document's `UndoManager`.

### 8.3 Search & Close Call
Toggles for service search groups. A table with 10 custom ranges (low, high, enabled). Close Call settings for mode, alert beep, alert light, the band checkboxes, and lockout. Search delay and code search.

### 8.4 Global Lockouts
An editable list of frequencies with add and remove (**verify** the device's maximum count; §3.3).

### 8.5 Settings
Backlight, key beep, key lock, contrast, battery charge time (with bc125py's suggested hours for each NiMH capacity: 1500 mAh → 9 h … 2700 mAh → 16 h), priority mode, weather alert priority, volume, and squelch. Bank names are stored in the document only and are clearly labeled that way.

### 8.6 Stretch: Live panel
When connected but not in program mode, show volume and squelch sliders (`VOL`/`SQL` work outside program mode). The BC125AT has no status command (no `GLG`/`STS`), so there's no display of what it's receiving.

### 8.7 Platform polish
Light and dark mode, Dynamic Type where macOS supports it, full VoiceOver labels on the table, menu commands with keyboard shortcuts, and a Settings scene for app preferences (backup retention, timeouts).

## 9. Testing
- **Unit tests** cover encoding and decoding every command and its edge cases, the tone code tables, frequency parsing and formatting, validation, CSV round-trips, and diffs.
- **`MockTransport`** is a scripted fake scanner with state. It's used for sync tests, including timeouts, `NG`/`ERR` responses, cancelling partway through a write, and failed read-back checks.
- **Hardware tests** are opt-in. They're gated by an environment variable, run against a real BC125AT, and limited to read-only commands unless `BC125AT_ALLOW_WRITE=1` is set.

## 10. Milestones
0. **Protocol verification**: a small CLI in the package (`bc125at-cli info|dump|raw <cmd>`) that confirms the macOS driver works (or proves the IOUSBHost fallback is needed) and checks every **verify** item in §2–3 on real hardware. It reads only, except for clearly labelled round-trip tests on one spare channel. Update this spec with the results.
1. **Kit**: transport, protocol, model, validation, native and CSV formats, and the mock transport, all with tests.
2. **Read-only app**: document app, channel table, and Read from Scanner.
3. **Editing**: all editors, validation in the UI, undo, and copy/paste.
4. **Write**: diff review, writing only changes, read-back checks, and backups.
5. **Polish**: drag reordering, inspector, accessibility, app icon, release script, README.
6. **Uniden import**: open `.bc125at_ss` files (needs sample files).

## 11. Decisions
| Topic | Decision |
|---|---|
| Minimum OS | macOS 15 (Swift 6, Observation, modern `Table`) |
| Distribution | GitHub Releases, ad-hoc signed and not notarized for now (§6.3) |
| Uniden file import | Nice-to-have, milestone 6 |
| Bundle ID | `net.k9fgt.bc125at` |
| License | MIT. bc125py is also MIT (© 2022–2023 Max Loiacono), so its tables can be reused with attribution in a NOTICE file |
| Hardware | The maintainer has a BC125AT for Phase 0 and the hardware tests |
| Repo | Local git repo; not published to GitHub yet |
| Display name | BC125AT CPS |
| Protocol source | Uniden Operation Spec Appendix C, cross-checked with bc125py (§3) |

## 12. Open Questions
1. Sample files from Uniden's own software are needed before milestone 6. bc125py's `.125at` files are its own command scripts, not Uniden's format.
2. Should the app also accept the BC126AT, the international version? bc125py looks for it by name, and it probably uses the same protocol. If yes, accept `MDL,BC126AT` and check whether its frequency ranges differ.
3. The **verify** items in §2–3 all go to Phase 0.
