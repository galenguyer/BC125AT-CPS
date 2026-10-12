# BC125AT CPS — Native macOS Programming Software

**Status:** Draft v0.2 · 2026-10-12  
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
- Live remote control or audio. A small read-only "monitor" panel is a stretch goal (§8.6).

## 2. Hardware & Connection

| Item | Value |
|---|---|
| Interface | USB CDC-ACM (virtual serial port) |
| USB VID / PID | `0x1965` / `0x0017` |
| Serial | 115200 baud, 8N1, no flow control |
| Framing | ASCII commands ending in `\r`; responses end in `\r` |
| macOS device | Expected `/dev/cu.usbmodem*` (**verify**: confirm the stock AppleUSBCDC driver matches the device without a custom driver) |

The app finds the scanner by watching IOKit for the VID/PID pair, so the user never has to choose a port. If several scanners are plugged in, the app shows a picker.

## 3. Protocol Reference

> ⚠️ This table is from Uniden's BC125AT operation spec as I remember it. **Phase 0 (§10) checks every command against real hardware** before any write path is built.

Commands marked **P** work only in program mode. The scanner shows "Remote Mode" and stops scanning while it is in program mode.

| Cmd | Mode | Format | Notes |
|---|---|---|---|
| `MDL` | – | `MDL` → `MDL,BC125AT` | Identify the model |
| `VER` | – | `VER` → `VER,Version x.xx.xx` | Firmware version |
| `PRG` | – | `PRG` → `PRG,OK` / `PRG,NG` | Enter program mode |
| `EPG` | P | `EPG` → `EPG,OK` | Exit program mode |
| `CIN` | P | `CIN,idx[,name,frq,mod,tone,dly,lout,pri]` | Read or write channel 1–500 |
| `DCH` | P | `DCH,idx` | Clear one channel |
| `SCG` | P | `SCG[,##########]` | Bank scan enable, 10 digits; `0` = enabled |
| `BLT` | P | `BLT[,evnt]` | Backlight: `AO` `AF` `KY` `SQ` `KS` |
| `BSV` | P | `BSV[,hrs]` | Battery charge time, 1–16 h |
| `KBP` | P | `KBP[,beep,lock]` | Key beep (0 = auto, 99 = off); key lock 0/1 |
| `PRI` | P | `PRI[,mode]` | Priority: 0 off, 1 on, 2 plus on, 3 DND |
| `CNT` | P | `CNT[,lvl]` | LCD contrast, 1–15 |
| `WXS` | P | `WXS[,pri]` | Weather alert priority 0/1 |
| `SCO` | P | `SCO[,dly,code_srch]` | Search/close-call delay and CTCSS/DCS code search |
| `CLC` | P | `CLC[,mode,altb,altl,band,lout]` | Close Call; band is 5 digits |
| `SSG` | P | `SSG[,##########]` | Service search groups (Police, Fire/EMS, HAM, Marine, Railroad, Civil Air, Military Air, CB, FRS/GMRS/MURS, Racing) |
| `CSG` | P | `CSG[,##########]` | Custom search ranges, enable mask |
| `CSP` | P | `CSP,idx[,lo,hi]` | Custom search range 1–10 limits |
| `GLF` | P | `GLF` → `GLF,frq` or `GLF,-1` | Walk the global lockout list (repeat until -1) |
| `LOF` | P | `LOF,frq` | Add a global lockout |
| `ULF` | P | `ULF,frq` | Remove a global lockout |
| `CLR` | P | `CLR` | **Factory-clear all memory.** Never sent automatically |
| `VOL` / `SQL` | – | `VOL[,0-15]`, `SQL[,0-15]` | Allowed outside program mode |

**Errors:** `ERR` means the scanner didn't understand the command. `NG` means the command was valid but can't run in the current mode. The transport treats both as typed errors.

### 3.1 Channel fields (`CIN`)

| Field | Encoding | Values |
|---|---|---|
| `idx` | int | 1–500 (bank = `(idx-1)/50 + 1`) |
| `name` | ASCII | ≤ 16 chars (**verify** allowed charset) |
| `frq` | 8-digit int, 100 Hz units | `01625500` = 162.5500 MHz; `00000000` = empty |
| `mod` | enum | `AUTO` `AM` `FM` `NFM` |
| `tone` | int code | `0` none · `64–113` CTCSS (50 tones) · `128–231` DCS (104 codes) · `127` search · `240` no-tone (**verify full table**) |
| `dly` | int | `-10 -5 0 1 2 3 4 5` |
| `lout` | bool | 0/1 |
| `pri` | bool | 0/1 (**verify**: only one priority channel per bank?) |

### 3.2 Valid frequency ranges
25.0000–54.0000, 108.0000–174.0000, 225.0000–380.0000, and 400.0000–512.0000 MHz. The app warns when a frequency isn't on a valid channel step for its band (5, 6.25, 8.33, or 12.5 kHz, with the exact rules per band **to be verified**). It refuses frequencies outside these ranges outright.

## 4. Data Model

These are plain `Codable`, `Sendable`, `Equatable` value types in a UI-free package:

```swift
struct ScannerConfig {
    var channels: [Channel]            // always exactly 500, index-stable
    var bankScanEnabled: [Bool]        // 10
    var settings: SystemSettings       // backlight, beep, keylock, contrast, battery, priority, weather
    var search: SearchSettings         // SCO + SSG + CSG + 10 CustomRange
    var closeCall: CloseCallSettings
    var globalLockouts: [Frequency]    // sorted, unique
    var bankNames: [String]            // 10 — app-only metadata, never sent to the radio
    var metadata: DocumentMetadata     // firmware version read from, timestamps, notes
}

struct Channel { var name: String; var frequency: Frequency?; var modulation: Modulation
                 var tone: ToneCode; var delay: Delay; var lockedOut: Bool; var priority: Bool }

struct Frequency: Comparable { var hundredHz: UInt32 }   // exact integer math, no floating point
enum ToneCode { case none, search, noTone, ctcss(Double), dcs(Int) }  // maps to and from the raw codes
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
- `ScannerSession` is an `actor`. It owns the port and runs one command at a time, with a per-command timeout (default 1 s) and a single retry if a read times out.
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

1. **Read from Scanner**: runs `PRG`, reads every section, then `EPG`. This takes about 520 round trips, and the target is under 15 s. The result opens as a new untitled document, or replaces the current one after a confirmation.
2. **Write to Scanner**:
   1. Validate the document. Any errors stop the write.
   2. Read the scanner's current state, or reuse a cached read from this session if it's still fresh.
   3. Work out the diff and show a review sheet listing the changes by section (for example "37 channels changed, 2 lockouts added").
   4. Write only the changed items, read each one back, and check it.
   5. Report the result. A partial failure lists exactly which items didn't match.
3. **Never send `CLR`** except through an explicit "Factory Clear Scanner…" menu item that requires typing a confirmation.
4. **Automatic backup**: every write first saves the scanner's previous state to `~/Library/Application Support/BC125AT CPS/Backups/<timestamp>.bc125at`.

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
An editable list of frequencies with add and remove (**verify** the device's maximum count).

### 8.5 Settings
Backlight, key beep, key lock, contrast, battery charge time, priority mode, and weather alert priority. Bank names are stored in the document only and are clearly labeled that way.

### 8.6 Stretch: Live panel
When connected but not in program mode, show volume and squelch sliders (`VOL`/`SQL`), plus a read-only display of what the scanner is receiving if `GLG`/`STS` turn out to be supported (**verify**).

### 8.7 Platform polish
Light and dark mode, Dynamic Type where macOS supports it, full VoiceOver labels on the table, menu commands with keyboard shortcuts, and a Settings scene for app preferences (backup retention, timeouts).

## 9. Testing
- **Unit tests** cover encoding and decoding every command and its edge cases, the tone code tables, frequency parsing and formatting, validation, CSV round-trips, and diffs.
- **`MockTransport`** is a scripted fake scanner with state. It's used for sync tests, including timeouts, `NG`/`ERR` responses, cancelling partway through a write, and failed read-back checks.
- **Hardware tests** are opt-in. They're gated by an environment variable, run against a real BC125AT, and limited to read-only commands unless `BC125AT_ALLOW_WRITE=1` is set.

## 10. Milestones
0. **Protocol verification**: a small CLI in the package (`bc125at-cli info|dump|get CIN 1`) that confirms the macOS driver works and checks every command in §3 on real hardware. Update this spec with the results.
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
| License | MIT. Tools such as `bc125py` and `bc125csv` are fine to read as protocol references; check their licences before copying any code |
| Hardware | The maintainer has a BC125AT for Phase 0 and the hardware tests |
| Repo | Local git repo; not published to GitHub yet |

## 12. Open Questions
1. Display name: "BC125AT CPS" or something else?
2. Sample `.bc125at_ss` files are needed before milestone 6.
