# BC125AT CPS — Native macOS Programming Software

**Status:** v1.0 of this spec, app 1.0 (milestones 0–7 complete) · 2026-10-13  
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
- iOS or iPadOS. USB device access there needs DriverKit or MFi, which is out of scope for now.
- Audio, and general remote control. (What the scanner is receiving, its volume and squelch, and Scan, Hold and Listen *are* available; §3.7, §3.8, §8.6.)

## 2. Hardware & Connection

> **Verified in Phase 0** on firmware 1.06.06 / macOS 27.0.1. See `phase0/REPORT.md`.

| Item | Value |
|---|---|
| USB VID / PID | `0x1965` / `0x0017` |
| Interfaces | 0: CDC ACM control (class 2/2/0, 1 endpoint). 1: CDC data (class 10), **bulk IN `0x81`, bulk OUT `0x02`, 64-byte packets** |
| macOS driver | **None usable.** `AppleUSBCDCCompositeDevice` loads but never matches, so there's no `/dev/cu.*` node |
| Transport | Open interface 1 with **IOUSBLib** (`IOUSBInterfaceInterface942`) and exchange bytes on the bulk pipes. Needs no root, no driver, and **no line-coding/baud or DTR setup** |
| Framing | ASCII commands ending in `\r`; replies end in `\r`. **Replies can be split across USB transfers**, so reads accumulate until `\r` |
| Flow | Strictly one command at a time. About 3 ms per command; all 500 channels read in 1.5 s |

The transport is `USBTransport` in `BC125ATKit`; the USB calls are in a small C target, `CBC125ATUSB`.
- **Sandbox finding (milestone 2):** in an App Sandbox with `com.apple.security.device.usb`, the newer **IOUSBHost** framework can't open the scanner. Opening the interface fails with `0xe00002c9`, and opening the device fails with `kIOReturnNotPermitted`. The older **IOUSBLib** plug-in API works fully in the same sandbox. Phase 0 used IOUSBHost, which only worked because the CLI isn't sandboxed. The transport now uses IOUSBLib, and reads are byte-identical either way.
- Matching on the interface class doesn't find this device's interfaces, so the transport finds the `IOUSBHostDevice` by VID/PID and walks its children for `bInterfaceNumber == 1`.
- The app watches IOKit for that VID/PID, so the user never picks a port. If several scanners are connected, it shows a picker keyed by `locationID`.
- A program that already holds a user client on the *device* (Calibre does, while probing for e-readers) did not get in the way, because the app opens the *interface*.

## 3. Protocol Reference

> **Phase 0 status:** every item that was marked *verify* has now been tested on hardware (`phase0/REPORT.md`); the results are written in below. The step plan (§3.5) and lockout capacity (§3.3) were measured afterwards.
>
> **Source:** Uniden's *BC125AT Operation Specification*, Appendix C "PC programming Command" (pp. 54–63; a copy is in the bc125py repo at `docs/BC125AT_Protocol.pdf`), cross-checked against bc125py (MIT, commit `b9454ca`, 2026-01-03). Wherever the hardware disagreed with Uniden's document, the hardware wins, and the row says so.

Commands marked **P** only work in program mode. Uniden's official list has exactly 24 commands, all in the table below. **`GLG`, `STS` and `KEY` aren't on that list but work** (§3.7, §3.8). `PWR` hasn't been tried.

| Cmd | Mode | Get → response | Set | Notes |
|---|---|---|---|---|
| `PRG` | – | `PRG` → `PRG,OK` / `PRG,NG` | – | `NG` if the scanner is in Menu mode, Direct Entry, or Quick Save. The display shows "Remote Mode" / "Keypad Lock". Sending `PRG` while already in program mode returns `PRG,OK` (tested) |
| `EPG` | – | `EPG` → `EPG,OK` | – | The scanner then goes to **Scan Hold**, not Scan |
| `MDL` | – | `MDL` → `MDL,BC125AT` | – | |
| `VER` | – | `VER` → `VER,Version 1.06.06` | – | Tested unit runs 1.06.06 |
| `BLT` | P | `BLT` → `BLT,evnt,` | `BLT,evnt` | `AO` always on · `AF` always off · `KY` keypress · `SQ` squelch · `KS` key+squelch. Reply is `BLT,KS`. **No trailing comma**, despite what Uniden's spec shows |
| `BSV` | P | `BSV` → `BSV,hrs` | `BSV,hrs` | Battery charge time, 1–16 h |
| `CLR` | P | – | `CLR` → `CLR,OK` | Factory-clears all memory. **Takes "dozens of seconds"**, so it needs a long timeout |
| `KBP` | P | `KBP` → `KBP,level,lock` | `KBP,level,lock` | Beep level `0` auto / `99` off; key lock `0`/`1` |
| `BPL` | P | `BPL` → `BPL,plan` | `BPL,plan` | Band plan `0` USA / `1` Canada; changes the channel steps (§3.5) |
| `PRI` | P | `PRI` → `PRI,mode` | `PRI,mode` | `0` off · `1` on · `2` plus on · `3` DND |
| `SCG` | P | `SCG` → `SCG,##########` | `SCG,##########` | Bank scan enable. **`0` = enabled, `1` = disabled**. Digits in bank order 1…10. Uniden's spec says all ten can't be disabled, **but the scanner accepts `SCG,1111111111`** (tested) |
| `DCH` | P | – | `DCH,idx` | Delete channel 1–500 |
| `CIN` | P | `CIN,idx` → `CIN,idx,name,frq,mod,tone,dly,lout,pri` | same as response | See §3.1 |
| `SCO` | P | `SCO` → `SCO,dly,code_srch` | `SCO,dly,code_srch` | Search/Close Call delay (same values as channel delay); code search `0` off / `1` CTCSS/DCS |
| `GLF` | P | `GLF` → `GLF,frq` … `GLF,-1` | `GLF,x` → `GLF,OK` | Call repeatedly until `-1`. See §3.3 for how to reset the walk |
| `ULF` | P | – | `ULF,frq` | Remove a global lockout |
| `LOF` | P | – | `LOF,frq` | Add a global lockout |
| `CLC` | P | `CLC` → `CLC,mode,altb,altl,band,lout` | same | Mode `0` off · `1` CC priority · `2` CC DND · `3` Close Call Only (searches the CC bands continuously; tested: accepted and kept across `EPG`); alert beep and alert light `0`/`1`; band is 5 digits (§3.4); `lout` is "lockout for CC hits with scan", `0` locked out / `1` unlocked, i.e. the menu's **Scan Hits** (scan the Close Call Hits bank of the last 10 hits; default off). The app calls it `scanHits`, `1` = on |
| `SSG` | P | `SSG` → `SSG,##########` | same | Service search groups, **`0` = enabled**. Order: Police, Fire/Emergency, Ham, Marine, Railroad, Civil Air, Military Air, CB, FRS/GMRS/MURS, Racing |
| `CSG` | P | `CSG` → `CSG,##########` | same | Custom search ranges 1…10, **`0` = enabled** |
| `CSP` | P | `CSP,idx` → `CSP,idx,lo,hi,` | `CSP,idx,lo,hi` | Range index 1–10. Reply is `CSP,1,00250000,00279950`. **No trailing comma** |
| `WXS` | P | `WXS` → `WXS,pri` | `WXS,pri` | Weather alert priority `0`/`1` |
| `CNT` | P | `CNT` → `CNT,lvl` | `CNT,lvl` | Contrast 1–15. **An out-of-range value gets `CNT,OK` but is ignored**: `CNT,20` left it at 8. Validation must catch it |
| `VOL` | – | `VOL` → `VOL,lvl` | `VOL,lvl` | 0–15. Read with the settings, but only ever set from the live bar, never by a write (§7.2) |
| `SQL` | – | `SQL` → `SQL,lvl` | `SQL,lvl` | `0` open · 1–14 · `15` closed |
| `STS` | – | `STS` → `STS,011000,line1,,line2,,…` | – | Not in Uniden's list. The screen, line by line (e.g. `BANK3` / `SCAN` while scanning, the name and `CH133  127.6750` in hold), then status flags. Icons are custom glyphs that don't survive UTF-8 decoding. Unused by the app (§3.8) |
| `KEY` | – | – | `KEY,key,P` → `KEY,OK` | Not in Uniden's list. Presses a key (§3.8) |

Set commands reply `<CMD>,OK`.

**General rules from the spec:**
- **An empty field in a set command means "leave unchanged".** For example, `CIN,5,,1625500,,,,,` changes only the frequency. Because of this, *clearing* a channel name needs a single space (`CIN,5, ,…`). bc125py fixed exactly this bug in v0.9.
- The scanner rejects the whole set command if any field is malformed. Nothing is partly applied.
- **Errors:** `ERR` means a format or value error, and `NG` means the command isn't allowed right now. Both forms were seen on hardware: an unknown command gives a bare `ERR`, while `CIN,501` gives `CIN,ERR` and `BLT` outside program mode gives `BLT,NG`. The parser accepts both. A reply only counts as an error when it has at most two fields, so a channel *named* "ERR" isn't mistaken for one.
- The parser still tolerates trailing empty fields, but none were seen.

### 3.1 Channel fields (`CIN`)

| Field | Encoding | Values |
|---|---|---|
| `idx` | int | 1–500 (bank = `(idx-1)/50 + 1`) |
| `name` | ASCII | ≤ 16 chars. **Every printable ASCII character tested was accepted and stored as sent**, including lowercase and ``!@#$%^&*()-_=+/?.:;'"<>[]{}\|\\~` ``. Commas are forbidden because they're the field separator. **Names longer than 16 characters are silently cut to 16** (`CIN,OK`, not `ERR`), and **trailing spaces are removed**. A single space clears the name, which then reads back as `""` |
| `frq` | int, units of 100 Hz | **Replies are zero-padded to 8 digits** (`01625500` = 162.5500 MHz; `00000000` = empty). Writes are accepted without padding (`1625500`); the app sends 8 digits to match the replies. **Off-step values are silently snapped** (§3.5) |
| `mod` | enum | `AUTO` `AM` `FM` `NFM` |
| `tone` | int code | see §3.2 |
| `dly` | int | `-10 -5 0 1 2 3 4 5` seconds. Negative values are Uniden's "minus delay" modes |
| `lout` | bool | `0` unlocked / `1` locked out |
| `pri` | bool | `0`/`1`. **Only one priority channel per bank**: making a channel priority silently clears the flag on the bank's previous priority channel (tested). Validation treats two in a bank as an error, and the writer must apply priority changes in an order that ends in the intended state |

An empty channel reads back as `CIN,n,,00000000,AUTO,0,2,1,0`. Note that it's **locked out** by default, and `DCH` returns a channel to exactly this state.

Being careful, the `CIN` parser reads `idx` from the left and the last 6 fields from the right. Anything in between is the name. So if a name entered on the keypad ever contains a comma, it still parses correctly.

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
- After `-1`, more `GLF` calls keep returning `-1`.
- **`GLF,0` resets the cursor** (reply `GLF,OK`; tested). The app uses this. bc125py's `EPG`+`PRG` approach also works, but it takes the scanner out of program mode for a moment.
- Writing compares the lists and sends only the needed `ULF`/`LOF` commands. bc125py instead unlocks everything and locks the full list again.
- Lockout replies are zero-padded like `CIN` (`GLF,04069875`).
- **The list holds 100 frequencies.** Once it's full, `LOF` still replies `LOF,OK` but **silently drops the new entry**; the existing 100 are kept. The app enforces the 100-entry limit itself and checks every `LOF` by re-reading the list.

### 3.4 Bit masks: watch the polarity

| Command | Digits | `0` means | `1` means | Order |
|---|---|---|---|---|
| `SCG` | 10 | enabled | disabled | banks 1…10 |
| `SSG` | 10 | enabled | disabled | Police … Racing (see table) |
| `CSG` | 10 | enabled | disabled | custom ranges 1…10 |
| `CLC` band | 5 | **off** | **on** | VHF Low 25–54, Civil Air 108–137, VHF High 137–174, Military Air 225–320, UHF 320–512 MHz (owner's manual and protocol document agree) |

**Tested:** the scanner accepts all ten disabled for `SCG`, `SSG` and `CSG` (`OK`, and it reads back `1111111111`), even though Uniden's spec says it can't be done. So disabling everything is allowed, but the app shows it as a **warning** because the scanner would then have nothing to scan. The Close Call bands may all be off.

### 3.5 Valid frequency ranges and steps
25.0000–54.0000, 108.0000–174.0000, 225.0000–380.0000, and 400.0000–512.0000 MHz, inclusive. Tested: `5120000` was accepted, while `5120100` and `600000` (60 MHz, in a gap) got `CIN,ERR`.

**Every channel frequency is snapped to a fixed band plan.** An in-range frequency that isn't on the plan is still accepted (`CIN,OK`), but it's stored as the nearest valid point.

The rules, measured on firmware 1.06.06:
1. **Valid points** are `start + n × step` within each segment of the table below, truncated to 100 Hz. That's why 8.33 kHz points read back as `…0083`, `…0166`, `…0250`, and 6.25 kHz points as `…0062`, `…0125`, `…0187`.
2. **Snapping:** any other frequency is stored as the nearest valid point. **Exact ties round up** (tested in five bands).
3. **Exception, 137–174 MHz only:** a frequency that is an exact multiple of 5 kHz is **kept as sent**, even off-plan (e.g. 162.5050 is kept, although the plan there is 7.5 kHz). This doesn't apply in other bands: 118.0050 → 118.0083 and 406.0050 → 406.0062.

| Range (MHz) | Step | Notes |
|---|---|---|
| 25.0000–54.0000 | 5 kHz | |
| 108.0000–137.0000 | 8.33 kHz | Air band |
| 137.0000–150.7750 | 5 kHz | |
| 150.7750–174.0000 | mostly 7.5 kHz, then 12.5 kHz from 163.25 | about 20 segments, each with its own starting point, following FCC channel plans. Examples: the 154.45625–154.47875 offset channels, 5 kHz runs at 154.515–154.525 and 157.450–157.470, and lone channels 173.20375 and 173.39625. The full table is in the owner's manual ("USA Band Plan", p. 14) and `BandPlan.usa` |
| 225.0000–380.0000 | 12.5 kHz | |
| 400.0000–512.0000 | 6.25 kHz | |

**The owner's manual has the same table** ("USA Band Plan", p. 14; `https://www.uniden.info/download/ompdf/BC125ATom.pdf`). It was found after the measurements, and the two agree point for point: both give the same 44,967 channels (compared on 2026-10-14). The manual prints frequencies to 100 Hz, so it shows 154.45625, 173.20375 and 173.39625 as 154.4562, 173.2037 and 173.3962, and 136.99167 as 136.9916. It splits a few ranges differently from `phase0/band-plan.json` (25–27.995 and 28–54 MHz; 173.20375–173.210 at 6.25 kHz then 173.215–173.220 at 5 kHz) without changing the points. The manual says nothing about rules 2 and 3 above; those come only from the measurements. `BandPlan.usa` is now written from the manual's rows.

**How it was measured, and how sure we are:**

| Range | Evidence | Confidence |
|---|---|---|
| 137–174 MHz | A gap test on every pair of neighbouring grid points: a write just below each midpoint must read back as the lower point, so any extra or missing point would show up. All 5,363 gaps passed, and `band-plan.json` reproduces all 5,364 points | Exact |
| 25–54 MHz | Same gap test, all 5,800 gaps | Exact |
| 108–125.43 MHz | Same gap test, about 2,090 gaps | Exact |
| 125.43–137, 225–380, 400–512 MHz | 4–9 windows per band, each 25 kHz, sampled every 700 Hz. All matched a single regular grid. The full gap test was stopped as not worth about 32,000 more writes | Sampled |

In the sampled bands, an undiscovered irregular segment is possible but unlikely. If one exists, read-back (§7) catches it.

**Band plan region.** All of the above is the scanner's **USA** band plan. The scanner also has a **Canada** plan, chosen by holding **1** (USA) or **2** (Canada) while powering on; the owner's manual ("Canada Band Plan", p. 15) gives the same steps as USA except a plain **5 kHz grid across 137–174 MHz**. That's `BandPlan.canada`. It's read and set with `BPL` (program mode only; `BPL,NG` outside it), which is in Uniden's protocol document (V1.01, p. 58) but was missed at first. The document says to "issue this command before frequency programming". Switching with `BPL` takes effect at once and doesn't change anything else: tested USA → Canada → USA on 2026-10-14, every other reply in a full dump was unchanged, including the 500 channels (frequencies already stored aren't re-snapped) and weather priority. Tested earlier: after Uniden's software wrote a file set to Canada, off-plan VHF-high writes snapped to a 5 kHz grid (154.0062 → 154.0050, 155.0012 → 155.0000, 165.0030 → 165.0050) instead of the USA table's 154.0025, 155.0025 and 165.0000, while 137–150.775, 225–380 and 25–54 MHz behaved as in the USA plan. The app treats it as an ordinary setting (`SystemSettings.bandPlan`): read with the other settings, editable in Settings, and written first, before any channel, since it changes how the scanner stores their frequencies. Documents saved before it was read have no band plan and open as USA.

**On the Canada plan**, `ScannerConfig.channelPlan` is `BandPlan.canada`, so the app predicts snapping just as on USA. That table is the manual's, with only the spot checks above on hardware (all consistent with it), so if the scanner stores something else, the write reports it (§7) instead of failing.

**How the app uses this:**
- `BandPlan` in `BC125ATKit` carries both tables and predicts what the scanner will store for any frequency.
- The channel editor shows the predicted value and warns *before* writing ("154.0062 will be stored as 154.0025").
- Every write is still read back (§7). If the stored value doesn't match the prediction, the result reports it.

### 3.6 Factory default custom search ranges
From bc125py's defaults. **These match the tested scanner's `CSP` readout exactly.** The app uses these as the defaults for a new, empty document:

| # | Range (MHz) | # | Range (MHz) |
|---|---|---|---|
| 1 | 25.0000–27.9950 | 6 | 137.0000–143.9950 |
| 2 | 28.0000–29.6950 | 7 | 144.0000–147.9950 |
| 3 | 29.7000–49.9950 | 8 | 225.0000–380.0000 |
| 4 | 50.0000–54.0000 | 9 | 400.0000–449.9937 |
| 5 | 108.0000–136.9916 | 10 | 450.0000–469.9937 |

### 3.7 Live status (`GLG`)
Not in Uniden's BC125AT list, but tested on firmware 1.06.06: outside program mode, `GLG` answers with the layout Uniden's other scanners use, and the scanner keeps scanning while it's polled.

`GLG,[FRQ],[MOD],[ATT],[CTCSS/DCS],[NAME1],[NAME2],[NAME3],[SQL],[MUT],[SYS_TAG],[CHAN_TAG],[NAC]`

| Field | On the BC125AT |
|---|---|
| FRQ | Frequency, 100 Hz units (`04625625`) |
| MOD | `AM`, `FM`, `NFM` |
| CTCSS/DCS | Tone code (§3.2), `0` for none |
| NAME3 | The channel name; NAME1 and NAME2 are empty |
| SQL | `1` while a signal holds squelch open |
| MUT | `1` while muted (squelch closed); `0` while receiving |
| CHAN_TAG | The channel number (`312`) |
| ATT, SYS_TAG, NAC | Empty |

Examples: `GLG,04625625,NFM,,82,,,TALKAROUND,1,0,,312,` while receiving; `GLG,01215000,AM,,0,,,GUARD,0,1,,1,` in Scan Hold. While scanning, the reply changes several times a second, and the fields can momentarily disagree (one channel's frequency with the next one's name), so a channel is only shown once the scanner stays on it. `VOL` and `SQL` also work outside program mode and take effect immediately.

**Priority checks in hold.** With priority mode on, a `GLG` that lands on the scanner's priority check reports the priority channel's frequency under the held channel's number and name, with SQL `0`, for one poll. Observed 2026-10-15 on firmware 1.06.06, held on channel 13 (118.7000): 3 of about 150 polls over 30 s returned `GLG,01215000,AM,,0,,,YYZ TWR N,0,1,,13,`. 121.5000 is channel 1 (`CIN,1,GUARD,01215000,AM,0,5,0,1`), bank 1's priority channel, with priority mode `PRI,3` (Do Not Disturb); both read back afterwards with `bc125at-cli raw --prg PRI CIN,1`. Two of the samples were 2.07 s apart, consistent with the owner's manual's priority check every 2 seconds. The live bar treats such a reply as the scanner staying put rather than moving (`LiveStatus.looksLikePriorityCheck`), for one poll only, so a frequency that really changes on the channel is still shown on the next. Before this, each sample showed "Scanning…" for about 0.8 s. Telling scanning from hold (§3.8) compares channel numbers only, so it was never affected.

### 3.8 Scan and hold (`KEY`)
`KEY,<key>,P` presses a key as a finger would. It isn't in Uniden's BC125AT list, but works outside program mode (tested 2026-10-14, firmware 1.06.06). Tried: `S` (Scan), `H` (Hold) and the digits. Uniden's other scanners also use `L` (L/O), `F` (Func), `E` (Pgm/E), `.` (Clr), `<`/`>` (scroll) and the modes `L` (long press), `H`/`R` (hold down, release); untried here. The scanner's behaviour, all tested:
- **Scan** resumes scanning from hold, and does nothing while scanning.
- **Hold is a toggle**: it holds while scanning and resumes scanning while held.
- **Digits then Hold, while held**, jump to that channel in hold (typing `133`, Hold → channel 133).
- **Digits while scanning turn banks on and off** (as on the keypad), so the app never types digits unless it has just made sure the scanner is held.
- **`PRG`/`EPG` always leaves the scanner in hold on channel 1**, whatever it was doing before.

Telling scanning from hold uses `GLG` (§3.7): while scanning, the channel changes several times a second; in hold it stays put. `ScannerSession.scanMode()` polls every 100 ms and decides after 1 s, or 3.5 s if a signal is open (scanning also stops on a transmission, and for the delay after it). If the scanner isn't on a memory channel (a menu, search, Close Call Only, weather), the mode is unknown and nothing is restored. A scan that stays stopped on a transmission for the whole window is taken for hold; the user then presses Scan once, as before this feature.

`hold(on:)` presses **Scan, Hold, the digits, Hold**: Scan only ever leads to scanning and Hold then always holds, so the digits are typed in hold whatever the starting state. It then checks `GLG` reports that channel (an empty channel isn't reachable, so that returns false).

The app uses this to:
- **Keep the mode across reads and writes**: `LiveMonitor.withScanner` notes the mode before, and afterwards resumes scanning or holds on the same channel. The result sheets say which ("The scanner is scanning again." / "The scanner is back on hold on channel 131."). Release Scanner doesn't. `bc125at-cli read` and `write` do the same, and `bc125at-cli mode`, `scan` and `hold <channel>` expose it.
- **Scan and Hold buttons** in the live bar (§8.6). Hold uses `hold(on:)` with the channel shown, not the Hold key, so it never toggles back to scanning.
- **Listen on Scanner** in a channel's context menu: holds the scanner on that channel number.

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

Each model type has its own `validate() -> [ValidationIssue]`. An issue is either an `.error`, which blocks writing, or a `.warning`, which only advises. Channels that share a frequency (compared as the scanner would store them) each get a warning naming the others, e.g. "121.5000 MHz is also on channel 51 “GUARD”"; as in Uniden's software, duplicates are allowed, since the same channel in several banks is common. The warnings can be turned off in the app's Settings (⌘,), "Warn about duplicate frequencies".

## 5. File Formats

| Format | Purpose |
|---|---|
| `.bc125at` (native) | A JSON-encoded `ScannerConfig` with a format version. UTType is `net.k9fgt.bc125at.config`. Tones are written as Uniden's files write them (`Off`, `Srch`, `NoTone`, `C110.9`, `D023`; §5.1). The app shows the tone-squelch-off setting as **CSQ**. |
| CSV | Import and export channels. The columns are `Channel,Bank,Name,Frequency,Modulation,Tone,Delay,Lockout,Priority`. Tones are written in readable form (`CTCSS 100.0`, `DCS 023`). |
| Uniden `.bc125at_ss` | Import and export (File menu; `bc125at-cli convert`). See §5.1. |
| RadioReference CSV | Import only (**File ▸ Import from RadioReference…**). See §5.2. |

### 5.1 Uniden `.bc125at_ss`
Files from Uniden's BC125AT software (`UnidenFormat`). Worked out from three files the maintainer saved from Uniden's software and wrote to the scanner with it; after each, every field (3,539 per file) was compared with a dump of the scanner. Exporting an imported file reproduces Uniden's file byte for byte.

Tab-separated text, CRLF line endings, one record per line, in this order:

| Record | Fields | Notes |
|---|---|---|
| `Misc` | backlight, key beep, key lock, contrast, battery hours, volume, squelch, band plan | Backlight `On` `Off` `K+S` (= AO, AF, KS); `Key`/`Squelch` for KY/SQ are assumed, not yet seen. Key beep `Auto`/`Off` (0/99). Band plan `USA`/`Canada` (§3.5) |
| `Priority` | mode | `Off` `On` `Plus` `DND` (0–3) |
| `WxPri` | On/Off | |
| `Service` ×10 | n, name, flag | |
| `Custom` ×10 | n, name, lower Hz, upper Hz, flag | Names are Uniden's ("Search Bnak1", sic); the app doesn't keep them |
| `CloseCall` | mode, beep, light, lockout | Mode `Off` `Pri` `DND` (0–2); `Only` for 3 is assumed, not yet seen. The last field is Scan Hits (§3.1 `CLC`) |
| `CloseCallBands` | 5 × On/Off | On = enabled |
| `GeneralSearch` | delay, code search | |
| `Conventional` | n, name, flag | One per bank, each followed by its 50 `C-Freq` lines. "Bank n" means no name |
| `C-Freq` ×500 | n, name, Hz, modulation, tone, lockout, delay, priority | Modulation `Auto` `AM` `FM` `NFM`. Tone `Off` `Srch` `NoTone` `C110.9` `D023`. Delay is the number of seconds (`-10`…`5`). An empty channel is `0` Hz |

**Watch the polarity:** for `Conventional`, `Service` and `Custom`, the flag is the scanner's raw mask digit (§3.4), so **On means disabled**. `CloseCallBands` are the right way round. Frequencies are in hertz (the scanner uses 100 Hz). The files have no global lockouts: import keeps the document's, and export leaves them out.

Import replaces the whole document as one undo step, keeping its global lockouts, notes, and bank names where the file has only Uniden's defaults. Any value not in the table above stops the import with the line number rather than being guessed.

**Unexplained:** after Uniden's software wrote a file with `WxPri On` and band plan `Canada`, the scanner read back `WXS,0`. With `USA` it read back `WXS,1`. It isn't the scanner: `BPL` leaves `WXS` alone in both directions, `WXS,1` can be set and read back on the Canada plan, and switching at power-on left `WXS,1` alone too (tested 2026-10-14). So Uniden's software doesn't send weather priority on (or sends it off) for a Canada file. This app writes `WXS` as the document says on either plan.

### 5.2 RadioReference CSV
CSV exports of RadioReference's county, agency and category frequency lists (`RadioReferenceFormat`): `Frequency Output,Frequency Input,FCC Callsign,Agency/Category,Description,Alpha Tag,PL Output Tone,PL Input Tone,Mode,Class Station Code,Tag`. Columns are matched by name; `Frequency Output` and `Mode` are required.

- **Usable rows** have mode `AM`, `FM` (wideband) or `FMN` (narrowband → `NFM`) and an output frequency in the scanner's bands. Every other row is listed with the reason: digital (DMR, P25/Project 25, NXDN, D-STAR, …), trunked (LTR, Motorola, EDACS), data (`Telm`), or out of band.
- **Name** is the Alpha Tag (the Description if there's no tag), with commas and non-ASCII characters removed, cut to 16 characters.
- **Tone** comes from `PL Output Tone`, the tone the station transmits: `110.9 PL` → CTCSS 110.9, `023 DPL` → DCS 023. A tone the scanner can't decode (`NAC`, `RAN`, `CC`, or a non-standard value) leaves the channel open (CSQ), with a note.
- Delay is 2 s, unlocked, not priority.

The import sheet lists the usable rows, all selected except ones already in the document with the same name and frequency (or repeated earlier in the file), with a filter and Select All/None that act on the filtered rows. Rows whose frequency is already in the document are marked. The user picks a starting channel; it starts at the lowest channel selected in the table if that one is empty. The selected channels go into consecutive channels from there, in file order, and **only into empty channels**: Import is disabled unless the whole run is empty. The sheet shows the bank and how far the empty run reaches, warns (without blocking) when the run crosses into the next bank, and **Find Empty Channels** moves the start to the first run that fits, preferring one inside a single bank. The import is one undo step.

## 6. Architecture

```
BC125AT CPS.xcodeproj        the app target; folder-synchronized, so files aren't listed in it
App/
├── Info.plist               document type + exported UTType (merged with generated keys)
├── BC125ATCPS.entitlements  sandbox, USB, user-selected files, outgoing network (update check)
└── Sources/                 SwiftUI app: DocumentGroup, sidebar, channel table, section views,
                             ScannerMonitor (connected devices), ScannerReader (read + progress)
BC125ATKit/                  Swift package, no UI
├── Sources/CBC125ATUSB      C: IOUSBLib open/read/write/close (§2)
├── Sources/BC125ATKit
│   ├── Transport            USBTransport, USBDeviceWatcher, MockScanner (stateful fake), MockTransport
│   ├── Protocol             ScannerConnection (send/parse, ERR/NG), Wire (model ↔ command fields)
│   ├── Model                Frequency, BandPlan, ToneCode, Channel, settings, ScannerConfig, validation
│   ├── Sync                 ScannerSession actor: identify, readConfiguration, releaseProgramMode
│   └── Formats              NativeFormat (.bc125at JSON), CSVFormat, UnidenFormat, RadioReferenceFormat
├── Sources/bc125at-cli      list/info/raw/dump/read/verify/probe/release
└── Tests/BC125ATKitTests    Swift Testing; Fixtures/step-measurements.csv (19,505 measured values)
```

### 6.1 Concurrency
- `ScannerSession` is an `actor` with a custom executor: its own serial dispatch queue, so blocking USB I/O never occupies Swift's cooperative thread pool. It owns the transport and runs one command at a time, as Uniden's spec requires. Commands take about 3 ms. Each has a timeout (default 1 s; `CLR` 120 s, because the spec says it takes "dozens of seconds"). A timed-out read is retried once, but only for get commands. A set command that times out is never sent again blindly: the session reads the item back to find out whether it was applied.
- Long jobs (reading all, writing) report progress through an `AsyncStream<SyncProgress>` and can be cancelled. On cancel or any error, the session always sends `EPG` so the radio isn't left stuck in program mode.
- Built with Swift 6 strict concurrency.

### 6.2 Extensibility
Commands are described by a `ScannerModel` protocol: channel count, bank count, ranges, and which commands it supports. This keeps a second model possible later without generalizing everything now.

### 6.3 Sandbox & Distribution
- The app is sandboxed with the **`com.apple.security.device.usb`** entitlement and user-selected file read/write access, plus `com.apple.security.network.client` for the update check, which asks the GitHub releases API for the latest release at launch and when Settings opens. A newer release shows a one-line yellow note at the bottom of the sidebar, the same height as the live bar: clicking it opens the release, and its X hides it until the next launch or skips that version. Verified: the ad-hoc-signed, sandboxed app reads the scanner, but only through IOUSBLib (§2).
- It's distributed as a zipped `.app` attached to GitHub Releases. It isn't on the Mac App Store.
- Releases are **signed with a Developer ID and notarized** (Apple Developer team `L3T933ZXSR`), so they open without a Gatekeeper warning.
- Releases are built by `scripts/release.sh`. It runs the Kit tests, archives a universal (arm64 + x86_64) Release build, re-signs it with a Developer ID **with the hardened runtime**, checks the signature and the four entitlements, builds a universal `bc125at-cli` signed the same way, writes `dist/BC125AT-CPS-<version>.zip` and `dist/bc125at-cli-<version>-macos.zip`, notarizes both, staples the app's ticket, and writes `SHA256SUMS-<version>.txt`. It notarizes with a `NOTARY_PROFILE` keychain profile or an App Store Connect API key (`NOTARY_KEY`, `NOTARY_KEY_ID`, `NOTARY_ISSUER`), and stops if either step is unavailable. `scripts/release-unsigned.sh` builds the same thing signed ad hoc and not notarized; a quarantined download of that is `rejected` by Gatekeeper, as the README's instructions expect. `.github/workflows/release.yml` runs `release.sh` on GitHub Actions when a tag like `v1.1.0` is pushed, importing the certificate and API key from repository secrets, and attaches the zips to its release. Versions have three fields, and the tag must be `v` plus `MARKETING_VERSION`.

### 6.4 Building and testing
- Kit and CLI: `cd BC125ATKit && swift test` runs the 87 Kit tests, including `BandPlan` against every measured value; `swift run bc125at-cli read out.bc125at` reads a real scanner exactly as the app does.
- App: open `BC125AT CPS.xcodeproj`, or `xcodebuild -project "BC125AT CPS.xcodeproj" -scheme "BC125AT CPS" build`. It's signed "Apple Development" with team `L3T933ZXSR`; release builds override that and archive ad hoc before re-signing.

## 7. Sync Behavior

Every read, write and compare goes through `LiveMonitor.withScanner` (§8.6), so the live bar stops polling and the app has the scanner to itself. Each step below names the commands it sends.

### 7.1 Read from Scanner (⇧⌘R)
1. **Pause the live bar** and open the scanner over USB.
2. **Note what the scanner is doing** (`GLG`, §3.8): scanning, or holding on a channel. It polls every 100 ms for 1 s, or 3.5 s while a signal is open. If the scanner isn't on a memory channel (a menu, search, Close Call Only, weather), the mode is unknown and step 6 is skipped.
3. **Identify it**: `MDL` must be `BC125AT`; `VER` gives the firmware.
4. **Enter program mode**: `PRG`. `PRG,NG` means the scanner is in a menu, Direct Entry or Quick Save; the app asks the user to leave it and try again.
5. **Read everything**, about 530 round trips, about 2 s: the settings (`BLT`, `BSV`, `KBP`, `BPL`, `PRI`, `SCG`, `SCO`, `CLC`, `SSG`, `CSG`, `WXS`, `CNT`, `VOL`, `SQL`), the 10 custom ranges (`CSP`), the 500 channels (`CIN`), and the global lockouts (`GLF,0`, then `GLF` until `-1`). Then `EPG`, which always leaves the scanner held on channel 1. `EPG` is sent even on an error or cancel.
6. **Put the scanner back** (§3.8): Scan if it was scanning, or Scan, Hold, the channel's digits, Hold if it was holding, then check with `GLG`.
7. **Close the connection and resume the live bar.** The result sheet gives the channel count and firmware, and says whether the scanner is scanning again or back on hold on its channel.
8. **Update the document**: on an untitled, unchanged document the read fills it directly; otherwise the app asks before replacing. App-only bank names and notes are kept, and **one ⌘Z undoes the read**. SwiftUI registers that undo for changes made through the document binding, so the app must not register its own as well, or every read would take two ⌘Z presses. (SwiftUI's undo entry has no action name, so the menu says "Undo", not "Undo Read from Scanner".)

### 7.2 Write to Scanner (⇧⌘U)
1. **Validate the document.** Any errors stop the write and list the problems.
2. **Read the scanner fresh**: all of §7.1 steps 1–7. What the scanner holds is never assumed from an earlier read, since it can be changed on the keypad at any time.
3. **Plan** (`WritePlan`): compare the scanner with the document as the scanner will store it (frequencies snapped to the band plan, §3.5; names trimmed), giving one command per difference. **Volume and squelch are never in the plan**: they're the listener's, changed on the scanner or with the live bar at any time, so the plan keeps the scanner's levels (the ones just read) whatever the document says. If nothing differs, the app says the scanner is up to date and stops.
4. **Review**: a sheet lists the changes by section, plus anything the scanner will store differently ("154.0062 MHz will be stored as 154.0025 MHz"). Nothing has been written yet; Cancel stops here.
5. **Back up**: the scanner contents read in step 2 are saved (§7.3, item 4). If the backup can't be saved, nothing is written.
6. **Open the scanner again** and note its mode (§7.1 steps 1–2), since time has passed since the review.
7. **Write**: `MDL`/`VER`, `PRG`, then the plan's commands in order. `BPL` goes first, because it changes how frequencies are stored; channels follow, with priority channels last (setting one clears the bank's others); lockout removals come before additions. A rejected command (`ERR`/`NG`) is recorded and the rest still sent; a timeout or cancel stops the write.
8. **Verify**: read the whole scanner back (§7.1 step 5, ending with `EPG`) and plan again; anything still in that plan is a mismatch. A channel that matches except for its frequency was snapped to a value the app didn't predict (possible where the plan was only sampled, §3.5): that's reported as "stored as", not a failure (`WriteReport.storedDifferently`). Volume and squelch are taken from the read-back, in case they were changed during the write.
9. **Put the scanner back** and close (§7.1 steps 6–7).
10. **Report and update the document**: a partial failure lists exactly what the scanner rejected and what still differs, and leaves the document as it was. On success, the document takes what the scanner stored (snapped frequencies, trimmed names, the scanner's volume and squelch) as one undo step (`WriteReport.acceptedConfig`). The sheet says whether the scanner is scanning again or back on hold on its channel.

### 7.3 Other rules
1. **Never send `CLR`** except through an explicit "Factory Clear Scanner…" menu item that requires typing a confirmation.
2. **Compare with Scanner** (⇧⌘D): §7.2 steps 2–3, then lists how the scanner differs from the document, as the write review would, without writing. Like a write, it ignores volume and squelch. Works even when the document has errors.
3. **Release Scanner** (menu item): sends `EPG` on its own (and doesn't touch scan or hold), to recover a scanner left stuck in program mode by a crash or an unplugged cable. bc125py has the same feature, its `unlock` command.
4. **Automatic backup**: every write first saves the scanner's previous state to `Application Support/BC125AT CPS/Backups/Scanner backup <date> at <time>.bc125at`, inside the app's sandbox container. If the backup can't be saved, nothing is written. The newest 50 are kept. Scanner ▸ Show Backups in Finder opens the folder.

## 8. User Interface

### 8.1 Window layout
- **Sidebar**: Channels (with banks 1–10 nested, each showing its scan-enabled toggle and a count of channels in use), Search & Close Call, Global Lockouts, Settings.
- **Detail**: the editor for the selected section.
- **Toolbar**: connection status (scanner name, firmware, connected or disconnected), Read, Write, and a Validation issue count that opens an issues popover.
- **Inspector** (⌥⌘I, toolbar button): with one channel selected, every field as an editor, plus the value the scanner will store and the channel's issues. With several selected, counts and "Change All" menus for modulation, tone, delay and lockout.

### 8.2 Channel table
- An AppKit `NSTableView` (`ChannelTable`, wrapped for SwiftUI) that shows all 500 rows or one bank, with sortable columns. SwiftUI's `Table` re-laid out every visible row on each frame of a resize, so the sidebar animation dropped most of its frames (§8.7). The AppKit cells are plain controls reused as rows scroll, rows refresh in place only when their channel changes, and only the Name column stretches.
- Cells edit inline. The frequency field accepts `162.55`, `162550k`, and similar forms and normalizes them. Invalid cells get a red badge with a tooltip.
- Selecting several rows allows bulk edits from the context menu: modulation, tone, delay, lock out / unlock, priority (single channel), and Clear. Delete clears the selected channels.
- Making a channel priority clears the other priority channel in its bank, as the scanner itself would.
- An empty row can be started from either cell. Typing a frequency creates an active channel (empty channels are locked out on the scanner), keeping any name already typed. A name without a frequency is kept in the document with a warning, but isn't written until it has a frequency. Clearing a frequency empties the channel. Text cells commit on Return or when focus leaves, so each edit is one undo step.
- Copy, cut and paste use TSV on the pasteboard (`ChannelClipboard`), so they work with Numbers and Excel. Pasting starts at the first selected channel and fills consecutive slots, stopping at 500. Pasted text may have a header row (columns matched by name, as for CSV), or be in Name, Frequency, Modulation, Tone, Delay, Lockout, Priority order, or be a single column of frequencies.
- Rows can be dragged (one or several) onto another row, which moves them to consecutive slots starting there. Channels already in those slots aren't lost; they move into the slots that were vacated (`ScannerConfig.moveChannels`). Dropping onto a bank in the sidebar moves them into that bank's first empty slots, or beeps if there isn't room. Dragging into a *different* document's window copies the channels instead, since channel numbers mean nothing there. Each drop is one undo step.
- Cmd-F filters by name or frequency.
- **Cell selection**, like a spreadsheet: clicking a cell selects just that cell (outlined in the accent colour; the row stays selected underneath for the inspector, menus and drags, but isn't highlighted). Clicking the # column, or Shift/⌘-clicking, selects whole rows. With a cell selected: typing into a name or frequency starts editing it with what was typed; Return edits it, opens a pop-up or toggles a checkbox (Space does too, on controls); arrows and Tab move between cells; Delete clears a name or frequency; Escape goes back to whole-row selection. A single click no longer starts editing; double-click does.
- Keyboard with rows selected: Return edits the selected row's name; typing a channel number ("4", "5", "8" in quick succession) jumps to it. While editing, Tab and Shift-Tab commit and move Name → Frequency → the next row's Name, and back; Escape cancels.
- Every edit can be undone through the document's `UndoManager`.

### 8.3 Search & Close Call
Toggles for service search groups. The 10 custom ranges, one row each: lower and upper frequency, then the enabled switch. Close Call settings for mode, alert beep, alert light, the band checkboxes (with their ranges), and Scan Hits. Search delay and code search.

### 8.4 Global Lockouts
An editable list of frequencies with add and remove. It holds at most 100 (§3.3; the owner's manual agrees).

### 8.5 Settings
Backlight, key beep, key lock, contrast, battery charge time (with bc125py's suggested hours for each NiMH capacity: 1500 mAh → 9 h … 2700 mAh → 16 h), priority mode, weather alert priority, volume, and squelch (saved with the document but never written, §7.2). The band plan (§3.5). Bank names are stored in the document only and are clearly labeled that way.

### 8.6 Live bar
A strip along the bottom of every document window (`LiveBar`, `LiveMonitor`):
- **Now:** while a signal is open, or once the scanner has stayed on a channel for 0.6 s (hold, or the delay after a transmission; a one-poll frequency change on the same channel is a priority check, §3.7, not a move), the channel number, name, frequency, modulation and tone, with a green dot while receiving. Otherwise "Scanning…".
- **Last:** the most recent transmission and how long ago, so a short one isn't missed.
- **Scan and Hold buttons** (§3.8): Scan resumes scanning; Hold stops on the channel shown.
- **Volume and squelch sliders** that change the scanner immediately, and pick up changes made on the scanner itself.
- When space is short, the channel's name is cut first, and "Last" is hidden rather than cut.
- A pause button that stops polling (and frees the scanner for other programs, such as `bc125at-cli`).

`LiveMonitor` is shared by all windows. It polls `GLG` every 200 ms and `VOL`/`SQL` every 2 s, and sends slider changes, Scan, Hold and Listen between polls. USB access is exclusive, so reading, writing, comparing and Release Scanner go through `LiveMonitor.withScanner`, which pauses polling, opens the scanner, and closes it before polling resumes.

### 8.7 Platform polish
Light and dark mode, menu commands with keyboard shortcuts, and a Settings window (⌘,) for backup retention. App icon in `App/Sources/Assets.xcassets`, drawn by `scripts/make-icon.swift`.

- **Launch** opens a new, empty document rather than the Open panel (`NSShowAppCentricOpenPanelInsteadOfUntitledFile` is registered as false), since reading from the scanner is the usual first step.
- **Title bar double-click** zooms the window, or does whatever System Settings says (`AppleActionOnDoubleClick`), anywhere in the title bar or toolbar that isn't a control (`TitlebarDoubleClick`). SwiftUI's toolbar content would otherwise swallow the clicks.
- **Sidebar animation:** measured with Instruments (Animation Hitches) over six sidebar toggles in full screen on a 120 Hz display. A bare `NavigationSplitView` drops 17 frames; with SwiftUI's `Table` the app dropped 70, totalling 1.8 s of hitches with a worst frame of 100 ms. With the AppKit table it's 975 ms with a worst frame of 25 ms. What remains is AppKit re-tiling the scroll view and resizing every visible row view on each frame.

**VoiceOver:** every control in the channel table carries its own label ("Channel 12 modulation"). The headers are still spelled out (Modulation, Lockout, Priority). The inspector gives every field a normal form label.

## 9. Testing
- **Unit tests** cover encoding and decoding every command and its edge cases, the tone code tables, frequency parsing and formatting, validation, CSV round-trips, and diffs.
- **`MockTransport`** is a scripted fake scanner with state. It's used for sync tests, including timeouts, `NG`/`ERR` responses, cancelling partway through a write, and failed read-back checks.
- **Hardware tests** are opt-in. They're gated by an environment variable, run against a real BC125AT, and limited to read-only commands unless `BC125AT_ALLOW_WRITE=1` is set.

## 10. Milestones
0. ✅ **Protocol verification** (done 2026-10-12; `phase0/REPORT.md` and `phase0/band-plan.json`): a small CLI in the package (`bc125at-cli info|dump|raw|verify|probe`) that confirms the macOS driver works (or proves the IOUSBHost fallback is needed) and checks every **verify** item in §2–3 on real hardware. It reads only by default. `--allow-write` adds round-trip tests on two empty channels and a few settings; each change is restored and read back.
1. ✅ **Kit**: transport, protocol, model, validation (including `BandPlan`), native and CSV formats (CSV also imports bc125py exports), a stateful mock scanner, and the `ScannerSession` actor, all with tests.
2. ✅ **Read-only app**: document app (`.bc125at`), channel table (all channels or per bank, search, show/hide empty, issue badges), read-only Settings / Search & Close Call / Global Lockouts views, an issues popover, connection status with hot-plug detection, Read from Scanner, and Release Scanner. Verified end to end against a real BC125AT in the sandboxed, ad-hoc-signed app.
3. ✅ **Editing**: inline channel editing, bulk edits, copy/cut/paste, Delete, editable Settings (including bank names and scan flags), Search & Close Call and Global Lockouts, validation shown inline, undo for every edit, and CSV import/export (File menu).
4. ✅ **Write**: diff review, writing only changes, read-back checks, and backups. Verified against a real BC125AT: from the CLI (5 changes, then restoring the original) and from the app (pasting channels, an off-plan frequency that was adjusted, clearing channels, and the up-to-date case). Each test ended with a dump identical to the backup.
5. ✅ **Polish**: drag reordering (within a table, onto a sidebar bank, and between documents), inspector, VoiceOver labelling, app icon, Settings window, release script, README and NOTICE.
6. ✅ **Uniden files**: import and export `.bc125at_ss` (§5.1), checked against a real scanner with three files from Uniden's software. Also: the AppKit channel table, title-bar double-click zoom, and a blank document at launch instead of the Open panel.
7. ✅ **Live and keyboard** (app 0.2): the live bar (§8.6) on `GLG`, which turned out to work (§3.7); Compare with Scanner; Return, Tab and type-a-number in the channel table. After 0.2: spreadsheet-style cell selection, starting a channel from its name, and duplicate-frequency warnings (with a setting to turn them off).

## 11. Decisions
| Topic | Decision |
|---|---|
| Minimum OS | macOS 15 (Swift 6, Observation, modern `Table`) |
| Distribution | GitHub Releases, Developer ID signed and notarized (§6.3) |
| Uniden files | Import and export, milestone 6 |
| Bundle ID | `net.k9fgt.bc125at` |
| License | MIT. bc125py is also MIT (© 2022–2023 Max Loiacono), so its tables can be reused with attribution in a NOTICE file |
| Hardware | The maintainer has a BC125AT for Phase 0 and the hardware tests |
| Repo | Local git repo; not published to GitHub yet |
| Display name | BC125AT CPS |
| Protocol source | Uniden Operation Spec Appendix C, cross-checked with bc125py (§3) |

## 12. Open Questions
1. The Canada table is the manual's, spot-checked at four points in 150–174 MHz. A gap test of 137–174 MHz on Canada (about 7,400 writes) would confirm it, but isn't planned since the Canada plan isn't used here.
2. Should the app also accept the BC126AT, the international version? bc125py looks for it by name, and it probably uses the same protocol. If yes, accept `MDL,BC126AT` and check whether its frequency ranges differ.
