# 爽看 app icon generator — draws the mark and emits all required sizes.
# Run: powershell -File assets/icon/generate_icon.ps1
# ponytail: System.Drawing one-shot script instead of an icon-design dependency.
Add-Type -AssemblyName System.Drawing

$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$out = Join-Path $PSScriptRoot 'sizes'
New-Item -ItemType Directory -Force -Path $out | Out-Null

function New-IconBitmap([int]$size, [bool]$foregroundOnly) {
    $bmp = New-Object System.Drawing.Bitmap($size, $size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.PixelOffsetMode = 'HighQuality'
    $s = [float]$size

    if (-not $foregroundOnly) {
        # background: vertical gradient teal -> deep indigo, rounded square (legacy) / full (adaptive)
        $rect = New-Object System.Drawing.RectangleF(0, 0, $s, $s)
        $c1 = [System.Drawing.Color]::FromArgb(255, 16, 150, 130)   # teal
        $c2 = [System.Drawing.Color]::FromArgb(255, 30, 64, 175)    # indigo
        $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, $c1, $c2, 60.0)
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        $r = $s * 0.20
        $d = New-Object System.Drawing.RectangleF(0, 0, $s, $s)
        $path.AddArc($d.X, $d.Y, $r * 2, $r * 2, 180, 90)
        $path.AddArc($d.Right - $r * 2, $d.Y, $r * 2, $r * 2, 270, 90)
        $path.AddArc($d.Right - $r * 2, $d.Bottom - $r * 2, $r * 2, $r * 2, 0, 90)
        $path.AddArc($d.X, $d.Bottom - $r * 2, $r * 2, $r * 2, 90, 90)
        $path.CloseFigure()
        $g.SetClip($path)
        $g.FillRectangle($brush, $rect)
    } else {
        $g.Clear([System.Drawing.Color]::Transparent)
    }

    # mark: 「爽阅」 brand characters (white bold, centered) + soft shadow + gold bar
    $ff = New-Object System.Drawing.FontFamily('Microsoft YaHei')
    $font = New-Object System.Drawing.Font($ff, [float]($s * 0.37), [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $fmt = New-Object System.Drawing.StringFormat
    $fmt.Alignment = [System.Drawing.StringAlignment]::Center
    $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
    $layout = New-Object System.Drawing.RectangleF(0, 0, $s, $s)
    $shadow = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(90, 0, 0, 0))
    $soff = [float]($s * 0.022)
    $shadowRect = New-Object System.Drawing.RectangleF(0, $soff, $s, $s)
    $g.DrawString([string]'爽阅', $font, $shadow, $shadowRect, $fmt)
    $g.DrawString([string]'爽阅', $font, [System.Drawing.Brushes]::White, $layout, $fmt)
    # gold underline accent (keeps the old spark color as brand thread)
    $accent = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 255, 214, 90))
    $barW = $s * 0.34; $barH = [float]($s * 0.028)
    $g.FillRectangle($accent, ($s - $barW) / 2, $s * 0.725, $barW, $barH)
    $font.Dispose(); $ff.Dispose()

    $g.Dispose()
    return $bmp
}

function Save-Size([int]$size, [string]$name) {
    $b = New-IconBitmap $size $false
    $b.Save((Join-Path $out "$name.png"), [System.Drawing.Imaging.ImageFormat]::Png)
    $b.Dispose()
    Write-Host "  $name.png ($size)"
}

# marketing / store
Save-Size 1024 'icon-1024'
Save-Size 512 'icon-512'
# android mipmap densities (192=xxxhdpi, 144=xxhdpi, 96=xhdpi, 72=hdpi, 48=mdpi)
Save-Size 192 'mipmap-xxxhdpi'
Save-Size 144 'mipmap-xxhdpi'
Save-Size 96 'mipmap-xhdpi'
Save-Size 72 'mipmap-hdpi'
Save-Size 48 'mipmap-mdpi'
# android adaptive icon: foreground 108dp canvas with mark inside inner 66%
$fg = New-IconBitmap 432 $true
# draw mark scaled into center 66% by compositing a scaled copy
$inner = New-Object System.Drawing.Bitmap(432, 432)
$g2 = [System.Drawing.Graphics]::FromImage($inner)
$g2.Clear([System.Drawing.Color]::Transparent)
$src = New-IconBitmap 285 $true
$g2.DrawImage($src, 73, 73, 285, 285)
$g2.Dispose(); $src.Dispose(); $fg.Dispose()
$inner.Save((Join-Path $out 'mipmap-anydpi-v26-foreground.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$inner.Dispose()
# adaptive background (solid/gradient square, no rounding — launcher masks it)
$bg = New-IconBitmap 432 $false
$bg.Save((Join-Path $out 'mipmap-anydpi-v26-background.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$bg.Dispose()

# windows .ico: PNG-compressed entries (Vista+)
function New-Ico([string]$path, [int[]]$sizes) {
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    $bw.Write([uint16]0)           # reserved
    $bw.Write([uint16]1)           # type icon
    $bw.Write([uint16]$sizes.Count)
    $blobs = @()
    foreach ($sz in $sizes) {
        $b = New-IconBitmap $sz $false
        $ms2 = New-Object System.IO.MemoryStream
        $b.Save($ms2, [System.Drawing.Imaging.ImageFormat]::Png)
        $b.Dispose()
        $blobs += ,@($ms2.ToArray(), $sz)
    }
    $offset = 6 + 16 * $sizes.Count
    foreach ($entry in $blobs) {
        $data = $entry[0]; $sz = $entry[1]
        $bw.Write([byte]($(if ($sz -ge 256) { 0 } else { $sz })))
        $bw.Write([byte]($(if ($sz -ge 256) { 0 } else { $sz })))
        $bw.Write([byte]0)         # colors
        $bw.Write([byte]0)         # reserved
        $bw.Write([uint16]1)       # planes
        $bw.Write([uint16]32)      # bpp
        $bw.Write([uint32]$data.Length)
        $bw.Write([uint32]$offset)
        $offset += $data.Length
    }
    foreach ($entry in $blobs) { $bw.Write($entry[0]) }
    [System.IO.File]::WriteAllBytes($path, $ms.ToArray())
    $bw.Dispose(); $ms.Dispose()
    Write-Host "  app_icon.ico"
}
New-Ico (Join-Path $out 'app_icon.ico') @(256, 128, 64, 48, 32, 16)

# install into android res (replace flutter default)
$res = Join-Path $root 'android\app\src\main\res'
if (Test-Path $res) {
    $map = @{ 'mdpi' = 'mipmap-mdpi'; 'hdpi' = 'mipmap-hdpi'; 'xhdpi' = 'mipmap-xhdpi'; 'xxhdpi' = 'mipmap-xxhdpi'; 'xxxhdpi' = 'mipmap-xxxhdpi' }
    foreach ($k in $map.Keys) {
        $dir = Join-Path $res $map[$k]
        if (Test-Path $dir) {
            Copy-Item (Join-Path $out "$($map[$k]).png") (Join-Path $dir 'ic_launcher.png') -Force
            Copy-Item (Join-Path $out "$($map[$k]).png") (Join-Path $dir 'ic_launcher_round.png') -Force
        }
    }
    Write-Host "  android mipmaps updated"
}
# adaptive icon xml
$anydpi = Join-Path $res 'mipmap-anydpi-v26'
if (Test-Path $res) {
    New-Item -ItemType Directory -Force -Path $anydpi | Out-Null
    Copy-Item (Join-Path $out 'mipmap-anydpi-v26-foreground.png') (Join-Path $anydpi 'ic_launcher_foreground.png') -Force
    Copy-Item (Join-Path $out 'mipmap-anydpi-v26-background.png') (Join-Path $anydpi 'ic_launcher_background.png') -Force
}
# windows runner icon
$winIco = Join-Path $root 'windows\runner\resources\app_icon.ico'
if (Test-Path (Split-Path $winIco)) {
    Copy-Item (Join-Path $out 'app_icon.ico') $winIco -Force
    Write-Host "  windows app_icon.ico updated"
}
Write-Host "done"
