# MSI JRGB static colour without MSI Center

A single PowerShell script that sets the **12 V JRGB headers** of an **MSI MAG B650 TOMAHAWK WIFI
(MS-7D75)** to one static colour, or turns them off, without installing MSI Center or Mystic Light.

It talks to the board's built-in lighting controller (USB HID `1462:7D75`, product string
`MYSTIC LIGHT`) directly, using the protocol that [OpenRGB](https://gitlab.com/CalcProgrammer1/OpenRGB)
documents for this board.

## Why

- With no MSI software running, the board's JRGB headers cycle through rainbow colours.
- iCUE 5 has an MSI plugin, but it only passes commands to MSI Center's Mystic Light service.
  Without MSI Center it fails every ~10 s with
  `MLAPI_Initialize() failed with status code -3: "MSI Application not found or installed version not supported."`
- This script needs no extra software. Store the colour once with `-Save` and the board keeps it
  after shutdowns, with nothing running in the background.

## Usage

Windows PowerShell 5.1 or PowerShell 7. Run from the folder that holds the script:

```powershell
.\Set-MsiJrgb.ps1 -Color 785AFF                    # preview only: shows the bytes it would change
.\Set-MsiJrgb.ps1 -Color 785AFF -Apply             # set it until the next full power-off
.\Set-MsiJrgb.ps1 -Color 785AFF -Apply -Save       # set it and store it in the controller
.\Set-MsiJrgb.ps1 -Color 785AFF -Brightness 6 -Apply -Save   # brightness 1-10 (default 10)
.\Set-MsiJrgb.ps1 -Off -Apply -Save                # strip off
.\Set-MsiJrgb.ps1 -Restore -Apply -Save            # write back the original settings from the backup
```

If Windows blocks the script after downloading it from GitHub, run `Unblock-File .\Set-MsiJrgb.ps1`
first, or start it with `powershell -ExecutionPolicy Bypass -File .\Set-MsiJrgb.ps1 ...`.

## Safety

- **Preview by default.** Nothing is written without `-Apply`.
- **Backup.** On its first run the script saves the controller's current settings to
  `msi-7d75-backup.bin` next to itself. `-Restore` writes that file back.
  `msi-7d75-backup.bin` in this repo holds the factory settings read from my board before any change:
  rainbow on both JRGB and both ARGB headers.
- **Strict device check.** The script only runs if it finds HID `1462:7D75` with product `MYSTIC LIGHT`
  and the expected report layout. Otherwise it stops without writing.
- **Verified write.** After writing, it reads the settings back and compares them byte by byte.
- **Known risk.** In 2020, early OpenRGB code made the lighting controller stop responding on some
  older MSI boards (X570, different protocol) after it sent certain animated effects. This script
  only uses the static mode. A failure like that affects the RGB headers only, not the rest of the PC.

## How it works

The controller takes a 185-byte HID feature report with ID `0x52`. Each lighting zone is a
10-byte block:

| Byte in zone | Meaning |
|---|---|
| 0 | effect (`1` = static, `25` = rainbow, `26` = rainbow wave, ...) |
| 1-3 | colour 1 (R, G, B) |
| 4 | bits 0-1 speed, bits 2-6 brightness (0-10), bit 7 "sync JRGB" (sync master only) |
| 5-7 | colour 2 (R, G, B) |
| 8 | colour flags: bit 7 = use custom colour, bits 0-5 = sync flags (sync master only) |
| 9 | padding |

Zone positions on this board, from OpenRGB's board table entry `0x7D75`:

| Bytes | Zone |
|---|---|
| 1-10 | **JRGB1** |
| 74-83 | onboard-LED zone, which acts as the sync master on this board because it has no onboard LEDs |
| 134-143 | **JRGB2** (MSI boards from `0x7D03` on use this slot, not the `j_rgb_2` slot at 174) |
| 184 | save flag: `1` tells the controller to store the settings in its flash |

To set a static colour, the script does what OpenRGB does: both JRGB zones get effect `1`, the colour
in both colour slots and the "custom colour" flag. The sync master gets the same effect and colour,
with its JRGB/JPIPE sync flags cleared. Like MSI's own software, it sends the current state first,
then the new state, as two `HidD_SetFeature` calls. Anything on the 3-pin ARGB headers may follow
the sync master's colour.

## Other boards

The script only accepts PID `7D75`. OpenRGB uses the same zone layout for several other MSI boards,
for example `7D76` MAG B650M MORTAR WIFI, `7D78` PRO B650-P WIFI and `7E12` MAG X670E TOMAHAWK WIFI.
Adapting the script to those boards is untested; check OpenRGB's board table first.

## Credits and licence

The protocol details come from OpenRGB's `MSIMotherboard185Controller`
(`Controllers/MSIMotherboardController/`) by the OpenRGB contributors. Like OpenRGB, this script is
licensed under the GNU GPL v2 or later; see [LICENSE](LICENSE).
