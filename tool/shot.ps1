# Launch the Windows app and screenshot its window, for visual checks.
# ASCII only on purpose: PowerShell 5.1 reads BOM-less .ps1 as ANSI and
# would mangle non-ASCII strings into broken quote terminators.
# Usage: powershell -ExecutionPolicy Bypass -File tool\shot.ps1 -Out path.png -WaitMs 8000
param(
  [string]$Out = "$PSScriptRoot\..\build\shot.png",
  [int]$WaitMs = 6000,
  [switch]$Dismiss,
  [switch]$ClickPet
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$exe = "$PSScriptRoot\..\build\windows\x64\runner\Debug\novel_reader.exe"
if (-not (Test-Path $exe)) { throw "not found: $exe" }

# Load the P/Invoke shim from a file; here-strings are fragile in LF scripts.
$lines = @(
  'using System;'
  'using System.Runtime.InteropServices;'
  'public class ShotNative {'
  '  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);'
  '  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);'
  '  [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int t, bool repaint);'
  '  [StructLayout(LayoutKind.Sequential)]'
  '  public struct RECT { public int L, T, R, B; }'
  '}'
)
$cs = Join-Path $env:TEMP 'shot_native.cs'
[System.IO.File]::WriteAllLines($cs, $lines, (New-Object System.Text.UTF8Encoding $false))
Add-Type -Path $cs

$p = Start-Process -FilePath $exe -PassThru
Start-Sleep -Milliseconds $WaitMs

$h = [IntPtr]::Zero
for ($i = 0; $i -lt 40 -and $h -eq [IntPtr]::Zero; $i++) {
  $p.Refresh()
  $h = $p.MainWindowHandle
  if ($h -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 250 }
}
if ($h -eq [IntPtr]::Zero) { $p.Kill(); throw 'no window' }

[ShotNative]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 700
# Fixed size so successive shots are comparable
[ShotNative]::MoveWindow($h, 60, 60, 1280, 820, $true) | Out-Null
Start-Sleep -Milliseconds 1200
# Nudge the window: a Flutter surface that had nothing to repaint after the
# resize still holds the blank frame from mid-startup, so CopyFromScreen grabs
# white. Moving it a few times forces fresh frames.
foreach ($dx in @(0, 1, 0, 1, 0)) {
  [ShotNative]::MoveWindow($h, (60 + $dx), 60, 1280, 820, $true) | Out-Null
  Start-Sleep -Milliseconds 350
}
Start-Sleep -Milliseconds 1200

# Dismiss whatever modal is up (startup announcement / update dialog) so the
# shot shows the shell instead of a full-screen page. ESC does not close it —
# the announcement is a route with a button, not a dismissible dialog — so
# click its close X in the top-right corner.
if ($Dismiss) {
  $lines3 = @(
    'using System;'
    'using System.Runtime.InteropServices;'
    'public class Clicker {'
    '  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint x, uint y, uint d, IntPtr e);'
    '  public const uint LD = 0x0002, LU = 0x0004;'
    '}'
  )
  $cs3 = Join-Path $env:TEMP 'shot_clicker.cs'
  [System.IO.File]::WriteAllLines($cs3, $lines3, (New-Object System.Text.UTF8Encoding $false))
  Add-Type -Path $cs3
  Add-Type -AssemblyName System.Windows.Forms
  [System.Windows.Forms.Cursor]::Position =
    New-Object System.Drawing.Point((60 + 1192), (60 + 57))
  Start-Sleep -Milliseconds 250
  [Clicker]::mouse_event([Clicker]::LD, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 60
  [Clicker]::mouse_event([Clicker]::LU, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 1200
}

# Poke the pet so its reaction bubble is on screen when the shot is taken.
if ($ClickPet) {
  Add-Type -AssemblyName System.Windows.Forms
  $cx = 60 + 229   # window x + the middle of the pet's roaming range
  $cy = 60 + 22    # window y + the title bar strip
  [System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point($cx, $cy)
  Start-Sleep -Milliseconds 250
  [Clicker]::mouse_event([Clicker]::LD, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 60
  [Clicker]::mouse_event([Clicker]::LU, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 700
}

$r = New-Object ShotNative+RECT
[ShotNative]::GetWindowRect($h, [ref]$r) | Out-Null
$w = $r.R - $r.L
$ht = $r.B - $r.T
$bmp = New-Object System.Drawing.Bitmap($w, $ht)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($r.L, $r.T, 0, 0, $bmp.Size)
$g.Dispose()
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Output "shot ${w}x${ht} -> $Out"

$p.CloseMainWindow() | Out-Null
Start-Sleep -Milliseconds 700
if (-not $p.HasExited) { $p.Kill() }