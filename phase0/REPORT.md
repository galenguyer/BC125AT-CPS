# Phase 0 results

Hardware: BC125AT, firmware 1.06.06, macOS 27.0.1 (Apple silicon), 2026-10-12.
Produced by `swift run bc125at-cli verify --allow-write`; the full command transcript was captured with `--log`.
After the write tests, a full `dump` was byte-identical to the backup taken beforehand.

## USB / transport (SPEC.md §2)

- macOS loads `AppleUSBCDCCompositeDevice` (com.apple.driver.usb.cdc) on the device, but it never
  matches; no ACM driver attaches to either interface and **no `/dev/cu.*` node is created**.
- Interface 0: class 2/2/0 (CDC ACM, protocol 0), 1 endpoint. Interface 1: class 10 (CDC data),
  bulk IN `0x81` and bulk OUT `0x02`, 64-byte packets.
- Opening interface 1 with `IOUSBHostInterface` from user space works with **no root, no driver, and no
  line-coding or DTR setup**. `IOUSBHostInterface`'s matching dictionary does not find the interfaces;
  walking the `IOUSBHostDevice`'s children does.
- Replies can arrive split across USB transfers (`VER,Vers` + `ion 1.06.06\r`), so reads accumulate until `\r`.
- Reading all 500 channels takes 1.5 s (≈3 ms per command).

## Protocol checks

| Spec | Item | Result | Detail |
|---|---|---|---|
| §3 | MDL / VER | ✅ matches spec | `MDL,BC125AT`, `VER,Version 1.06.06` |
| §3 | Program-mode command outside program mode | ✅ matches spec | `BLT` → `BLT,NG` (spec: NG) |
| §3 | Unknown command | ✅ matches spec | `ZZZ` → `ERR` (spec: ERR) |
| §3 | VOL/SQL outside program mode | ✅ matches spec | `VOL,1`, `SQL,4` |
| §3 | PRG while already in program mode | ℹ️ observed | `PRG,OK` |
| §3 | Out-of-range channel index | ✅ matches spec | `CIN,501` → `CIN,ERR` |
| §3 | Get replies for all settings | ✅ matches spec | `BLT,KS`, `BSV,14`, `KBP,0,0`, `PRI,3`, `SCG,1010000001`, `SCO,2,1`, `CLC,0,1,1,01010,0`, `SSG,0000000000`, `CSG,0000000000`, `WXS,0`, `CNT,8`, `VOL,1`, `SQL,4` |
| §3 | Trailing comma on BLT | ⚠️ differs | `BLT,KS` |
| §3 | Trailing comma on CSP | ⚠️ differs | `CSP,1,00250000,00279950` |
| §3.6 | Custom search ranges vs bc125py defaults | ✅ matches spec | all 10 equal bc125py's defaults |
| §7 | Reading 500 channels | ℹ️ observed | 1.7 sec; 143 channels in use |
| §3.1 | Frequency padding in replies | ℹ️ observed | zero-padded; widths [8]; `CIN,1,…,01215000,…`, `CIN,2,…,01183000,…`, `CIN,3,…,01195500,…`, `CIN,27,…,00000000,…` |
| §3.1 | Empty channel reply | ℹ️ observed | `CIN,27,,00000000,AUTO,0,2,1,0` (name "") |
| §3.1 | Names with commas / characters in use | ℹ️ observed | 0 names contain commas; characters used: ` -/0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ` |
| §3.1 | Banks with more than one priority channel | ℹ️ observed | none in current data |
| §3.2 | Tone codes in use are in the spec table | ✅ matches spec | all valid |
| §3.3 | GLF walk | ℹ️ observed | 0 lockouts ; GLF after -1 → `GLF,-1` |
| Writes | Spare channels | ℹ️ observed | using empty channels 500 and 499 in bank 10 |
| §3.1 | Name characters and length | ℹ️ observed | "PHASE0 TEST" → `CIN,OK`, stored "PHASE0 TEST"<br>"abcdefghijklmnop" → `CIN,OK`, stored "abcdefghijklmnop"<br>"!@#$%^&*()-_=+/?" → `CIN,OK`, stored "!@#$%^&*()-_=+/?"<br>".:;\'\"<>[]{}\|\\~`" → `CIN,OK`, stored ".:;\'\"<>[]{}\|\\~`"<br>"12345678901234567" → `CIN,OK`, stored "1234567890123456"<br>"TRAIL  " → `CIN,OK`, stored "TRAIL" |
| §3.1 | Clearing a name | ✅ matches spec | empty field → `CIN,OK`, name "CLEARME"; single space → `CIN,OK`, name "" |
| §3 | Empty fields leave values unchanged | ✅ matches spec | `CIN,500,,1624000,,,,,` → `CIN,OK`; now `KEEPNAME,01624000,NFM,76,3` |
| §3.5 | Frequency acceptance and rounding | ℹ️ observed | 25.0050 (5 kHz): `250050` → `CIN,OK`, stored `00250050`<br>162.5510 (off-step): `1625510` → `CIN,OK`, stored `01625475`<br>162.5525 (2.5 kHz): `1625525` → `CIN,OK`, stored `01625550`<br>154.0062 (≈6.25 kHz, rounded down): `1540062` → `CIN,OK`, stored `01540025`<br>154.0063 (≈6.25 kHz, rounded up): `1540063` → `CIN,OK`, stored `01540100`<br>118.0083 (8.33 kHz): `1180083` → `CIN,OK`, stored `01180083`<br>118.0050 (5 kHz in air band): `1180050` → `CIN,OK`, stored `01180083`<br>406.0125 (12.5 kHz): `4060125` → `CIN,OK`, stored `04060125`<br>406.0050 (5 kHz in UHF): `4060050` → `CIN,OK`, stored `04060062`<br>512.0000 (top edge): `5120000` → `CIN,OK`, stored `05120000`<br>512.0100 (above range): `5120100` → `CIN,ERR`, stored `01625500`<br>60.0000 (gap): `600000` → `CIN,ERR`, stored `01625500` |
| §3.1 | Two priority channels in one bank | ℹ️ observed | after setting both: 500 pri=0, 499 pri=1 |
| §3 | DCH clears a channel to the empty state | ✅ matches spec | `DCH` → `DCH,OK`; reads back identical to the original empty channel: true |
| §3.4 | SCG all disabled | ⚠️ differs | `SCG,1111111111` → `SCG,OK`; reads back `SCG,1111111111` |
| §3.4 | SSG all disabled | ℹ️ observed | `SSG,1111111111` → `SSG,OK`; reads back `SSG,1111111111` |
| §3.4 | CSG all disabled | ℹ️ observed | `CSG,1111111111` → `CSG,OK`; reads back `CSG,1111111111` |
| §3 | CNT out of range | ✅ matches spec | `CNT,20` → `CNT,OK`; reads back `CNT,8` (was `CNT,8`) |
| §3.3 | Temporary lockout | ℹ️ observed | `LOF,4069875` → `LOF,OK`; list now ["`04069875`"] |
| §3.3 | GLF,0 resets the cursor | ✅ matches spec | `GLF,0` → `GLF,OK`, then `GLF` → `GLF,04069875` (first is `04069875`) |
| §3.3 | EPG+PRG resets the cursor (bc125py) | ✅ matches spec | then `GLF` → `GLF,04069875` |
| §3 | VOL/SQL after EPG | ✅ matches spec | `VOL,1`, `SQL,4` |
