<#
.SYNOPSIS
  Set the 12 V JRGB headers of an MSI MAG B650 TOMAHAWK WIFI (MS-7D75) to a static colour
  without MSI Center. Windows PowerShell 5.1 compatible.

.DESCRIPTION
  Talks to the board's "MYSTIC LIGHT" USB HID controller (1462:7D75) with the 185-byte
  feature report 0x52, following the steps OpenRGB uses for this board
  (Controllers/MSIMotherboardController/MSIMotherboard185Controller, board entry 0x7D75):
    - JRGB1 = j_rgb_1 zone (bytes 1-10)
    - JRGB2 = on_board_led_6 zone (bytes 134-143; "mixed mode" boards >= 0x7D03)
    - the on_board_led zone (bytes 74-83) acts as sync master on boards without onboard
      LEDs; for static it gets the same effect/colour and its JRGB/JPIPE sync flags cleared
  Like MSI's own software, it sends the current state first, then the new state.

  Without -Apply it only prints what would change. The first run saves a backup of the
  controller's current settings next to the script (msi-7d75-backup.bin), and
  -Restore -Apply writes that backup back.

.EXAMPLE
  .\Set-MsiJrgb.ps1 -Color FF8000                 # preview only, nothing is written
  .\Set-MsiJrgb.ps1 -Color FF8000 -Apply          # set it (lost at the next full power-off)
  .\Set-MsiJrgb.ps1 -Color FF8000 -Apply -Save    # set it and store it in the controller
  .\Set-MsiJrgb.ps1 -Off -Apply -Save             # strip off
  .\Set-MsiJrgb.ps1 -Restore -Apply -Save         # back to the original rainbow settings

.NOTES
  SPDX-License-Identifier: GPL-2.0-or-later
  Protocol details (packet layout, zone offsets, sync-flag handling) come from OpenRGB's
  MSIMotherboard185Controller by the OpenRGB contributors: https://gitlab.com/CalcProgrammer1/OpenRGB
#>
[CmdletBinding()]
param(
    [string]$Color,
    [switch]$Off,
    [ValidateRange(1, 10)][int]$Brightness = 10,
    [switch]$Restore,
    [switch]$Apply,
    [switch]$Save,
    [string]$BackupFile
)
$ErrorActionPreference = 'Stop'
if (-not $BackupFile) { $BackupFile = Join-Path $PSScriptRoot 'msi-7d75-backup.bin' }

$modes = @($Color, $Off, $Restore) | Where-Object { $_ }
if (@($modes).Count -ne 1) { throw 'Give exactly one of -Color RRGGBB, -Off or -Restore.' }
if ($Off) { $Color = '000000' }

if (-not ('MsiHid' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class MsiHid {
  [StructLayout(LayoutKind.Sequential)] public struct CAPS {
    public ushort Usage, UsagePage, InputReportByteLength, OutputReportByteLength, FeatureReportByteLength;
    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 17)] public ushort[] Reserved;
    public ushort NumberLinkCollectionNodes, NumberInputButtonCaps, NumberInputValueCaps, NumberInputDataIndices,
      NumberOutputButtonCaps, NumberOutputValueCaps, NumberOutputDataIndices,
      NumberFeatureButtonCaps, NumberFeatureValueCaps, NumberFeatureDataIndices; }
  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  public static extern SafeFileHandle CreateFile(string n, uint a, uint s, IntPtr sa, uint c, uint f, IntPtr t);
  [DllImport("hid.dll")] public static extern bool HidD_GetPreparsedData(SafeFileHandle h, out IntPtr p);
  [DllImport("hid.dll")] public static extern bool HidD_FreePreparsedData(IntPtr p);
  [DllImport("hid.dll")] public static extern int HidP_GetCaps(IntPtr p, out CAPS c);
  [DllImport("hid.dll", SetLastError = true)] public static extern bool HidD_GetFeature(SafeFileHandle h, byte[] b, int len);
  [DllImport("hid.dll", SetLastError = true)] public static extern bool HidD_SetFeature(SafeFileHandle h, byte[] b, int len);
  [DllImport("hid.dll", CharSet = CharSet.Unicode)] public static extern bool HidD_GetProductString(SafeFileHandle h, byte[] b, int len);
}
'@
}

$PacketLen = 185   # FeaturePacket_185: report ID 0x52 + 183 bytes of zone data + save flag
$ZoneJrgb1 = 1     # j_rgb_1
$ZoneJrgb2 = 134   # on_board_led_6 = JRGB2 on this board
$ZoneMain  = 74    # on_board_led (sync master)
$SaveByte  = 184

function Open-Controller {
    $dev = Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like 'HID\VID_1462&PID_7D75\*' } | Select-Object -First 1
    if (-not $dev) { throw 'MSI Mystic Light controller (HID 1462:7D75) not found.' }
    $path = '\\?\' + ($dev.InstanceId -replace '\\', '#') + '#{4d1e55b2-f16f-11cf-88cb-001111000030}'
    $h = [MsiHid]::CreateFile($path, [uint32]3221225472, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
    if ($null -eq $h -or $h.IsInvalid) { throw "Cannot open $path (Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))" }
    $name = New-Object byte[] 256; [void][MsiHid]::HidD_GetProductString($h, $name, 256)
    $name = [Text.Encoding]::Unicode.GetString($name).Trim([char]0).Trim()
    $pp = [IntPtr]::Zero; [void][MsiHid]::HidD_GetPreparsedData($h, [ref]$pp)
    $caps = New-Object MsiHid+CAPS; [void][MsiHid]::HidP_GetCaps($pp, [ref]$caps); [void][MsiHid]::HidD_FreePreparsedData($pp)
    if ($name -ne 'MYSTIC LIGHT' -or $caps.FeatureReportByteLength -ne 761) {
        $h.Dispose(); throw "Unexpected device: product '$name', feature length $($caps.FeatureReportByteLength). Stopping."
    }
    return @{ Handle = $h; BufLen = [int]$caps.FeatureReportByteLength }
}

function Read-State($c) {
    $buf = New-Object byte[] $c.BufLen; $buf[0] = 0x52
    if (-not [MsiHid]::HidD_GetFeature($c.Handle, $buf, $buf.Length)) { throw "Reading the controller failed (Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))" }
    if ($buf[0] -ne 0x52 -or $buf[$SaveByte] -ne 0) { throw 'Controller returned an unexpected report layout. Stopping.' }
    for ($i = $PacketLen; $i -lt $buf.Length; $i++) { if ($buf[$i] -ne 0) { throw 'Controller returned data past byte 184. Stopping.' } }
    return [byte[]]$buf[0..($PacketLen - 1)]
}

function Write-State($c, [byte[]]$packet, [bool]$saveFlag) {
    # Windows wants the full feature-report buffer length; the HID driver sends only report 0x52's 185 bytes.
    $buf = New-Object byte[] $c.BufLen
    [Array]::Copy($packet, $buf, $PacketLen)
    $buf[$SaveByte] = [byte]([int]$saveFlag)
    if (-not [MsiHid]::HidD_SetFeature($c.Handle, $buf, $buf.Length)) { throw "Writing to the controller failed (Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))" }
}

function Set-StaticZone([byte[]]$p, [int]$o, [byte]$r, [byte]$g, [byte]$b, [byte]$sb) {
    # OpenRGB SetMode(STATIC, speed 0, brightness, custom colour) + SetZoneColor(c, c)
    $p[$o] = 1; $p[$o + 1] = $r; $p[$o + 2] = $g; $p[$o + 3] = $b
    $p[$o + 4] = $sb; $p[$o + 5] = $r; $p[$o + 6] = $g; $p[$o + 7] = $b
    $p[$o + 8] = $p[$o + 8] -bor 0x80; $p[$o + 9] = 0
}

function Show-Diff([byte[]]$old, [byte[]]$new) {
    $names = @{ $ZoneJrgb1 = 'JRGB1'; $ZoneJrgb2 = 'JRGB2'; $ZoneMain = 'sync master' }
    $n = 0
    foreach ($z in $ZoneJrgb1, $ZoneMain, $ZoneJrgb2) {
        $a = ($old[$z..($z + 9)] | ForEach-Object { $_.ToString('X2') }) -join ' '
        $b = ($new[$z..($z + 9)] | ForEach-Object { $_.ToString('X2') }) -join ' '
        if ($a -ne $b) { '  {0,-11} byte {1,3}: {2}  ->  {3}' -f $names[$z], $z, $a, $b; $n++ }
    }
    for ($i = 0; $i -lt $PacketLen; $i++) {
        $inZone = ($i -ge $ZoneJrgb1 -and $i -le $ZoneJrgb1 + 9) -or ($i -ge $ZoneMain -and $i -le $ZoneMain + 9) -or ($i -ge $ZoneJrgb2 -and $i -le $ZoneJrgb2 + 9)
        if (-not $inZone -and $old[$i] -ne $new[$i]) { '  other       byte {0,3}: {1:X2}  ->  {2:X2}' -f $i, $old[$i], $new[$i]; $n++ }
    }
    if ($n -eq 0) { '  (no change)' }
}

$c = Open-Controller
try {
    $current = Read-State $c
    if (-not (Test-Path $BackupFile)) {
        [IO.File]::WriteAllBytes($BackupFile, $current)
        "Backup of the current settings saved to $BackupFile"
    }

    if ($Restore) {
        if (-not (Test-Path $BackupFile)) { throw "No backup at $BackupFile" }
        $target = [IO.File]::ReadAllBytes($BackupFile)
        if ($target.Length -ne $PacketLen -or $target[0] -ne 0x52) { throw 'Backup file is not a valid 185-byte report.' }
        $what = 'restore the backed-up settings'
    } else {
        if ($Color -notmatch '^#?([0-9A-Fa-f]{6})$') { throw "Colour must be RRGGBB hex, e.g. FF8000 (got '$Color')." }
        $hex = $Matches[1]
        $r = [Convert]::ToByte($hex.Substring(0, 2), 16); $g = [Convert]::ToByte($hex.Substring(2, 2), 16); $b = [Convert]::ToByte($hex.Substring(4, 2), 16)
        $sb = [byte](($Brightness -shl 2) -band 0x7C)
        $target = [byte[]]$current.Clone()
        Set-StaticZone $target $ZoneJrgb1 $r $g $b $sb
        Set-StaticZone $target $ZoneJrgb2 $r $g $b $sb
        # sync master: same static effect + colour, keep its brightness bits, clear JRGB/JPIPE sync, set onboard sync
        $target[$ZoneMain] = 1
        $target[$ZoneMain + 1] = $r; $target[$ZoneMain + 2] = $g; $target[$ZoneMain + 3] = $b
        $target[$ZoneMain + 4] = $target[$ZoneMain + 4] -band 0x7F
        $target[$ZoneMain + 5] = $r; $target[$ZoneMain + 6] = $g; $target[$ZoneMain + 7] = $b
        $target[$ZoneMain + 8] = ($target[$ZoneMain + 8] -bor 0x01) -band 0xCF
        $target[$ZoneMain + 9] = 0
        $what = "set both JRGB headers to static #$($hex.ToUpper()) at brightness $Brightness/10"
    }

    "Plan: $what" + $(if ($Save) { ', and store it in the controller' } else { ' (until the next full power-off)' })
    Show-Diff $current $target

    if (-not $Apply) { 'Preview only. Add -Apply to write it.'; return }

    Write-State $c $current $Save    # same order as MSI's software: current state first...
    Start-Sleep -Milliseconds 50
    Write-State $c $target $Save     # ...then the new state
    Start-Sleep -Milliseconds 200

    $after = Read-State $c
    $diff = @(0..($PacketLen - 2) | Where-Object { $after[$_] -ne $target[$_] })
    if ($diff.Count -eq 0) { 'Done: the controller now reports exactly the new settings.' }
    else { "Written, but the controller reports $($diff.Count) byte(s) different from what was sent (first at byte $($diff[0])). Check the strip." }
} finally {
    $c.Handle.Dispose()
}
