# Slogan image generator - "shuang yue, read freely, whenever you want".
# Run: powershell -File assets/brand/generate_slogan.ps1
# ASCII only on purpose: PowerShell 5.1 reads BOM-less .ps1 as ANSI and would
# mangle non-ASCII literals into broken quote terminators.
# CJK copy lives in slogan.txt (UTF-8) and is read from there, never inlined.
Add-Type -AssemblyName System.Drawing

$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$brand = $PSScriptRoot
$webOut = Join-Path $root 'docs\assets'
New-Item -ItemType Directory -Force -Path $webOut | Out-Null

$copy = @(Get-Content (Join-Path $brand 'slogan.txt') -Encoding UTF8 | Where-Object { $_.Trim() -ne '' })
$title = $copy[0]
$line = $copy[1]
$tag = $copy[2]

function New-Gfx([int]$w, [int]$h) {
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.PixelOffsetMode = 'HighQuality'
    $g.InterpolationMode = 'HighQualityBicubic'
    $g.TextRenderingHint = 'AntiAliasGridFit'
    return @($bmp, $g)
}

function Fill-Bg($g, [int]$w, [int]$h) {
    $rect = New-Object System.Drawing.RectangleF(0, 0, [float]$w, [float]$h)
    $br = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect,
        [System.Drawing.Color]::FromArgb(255, 17, 24, 39),
        [System.Drawing.Color]::FromArgb(255, 10, 61, 66), 62.0)
    $g.FillRectangle($br, $rect)
    $br.Dispose()
}

# The ink-drop mark (mo di): teardrop body, two page-corner ears, a vermilion
# seal on the forehead and bean eyes - the pet's invariants, so the brand mark
# and the in-app pet are recognisably the same creature.
function Draw-Mark($g, [float]$cx, [float]$cy, [float]$r) {
    $earFill = [System.Drawing.Color]::FromArgb(255, 236, 240, 246)

    # ears first, so the body covers their inner edge and they look attached
    $ear = New-Object System.Drawing.SolidBrush($earFill)
    foreach ($s in @(-1.0, 1.0)) {
        $p = New-Object System.Drawing.Drawing2D.GraphicsPath
        $p.AddPolygon([System.Drawing.PointF[]]@(
                (New-Object System.Drawing.PointF([float]($cx + $s * $r * 0.22), [float]($cy - $r * 0.55))),
                (New-Object System.Drawing.PointF([float]($cx + $s * $r * 0.70), [float]($cy - $r * 0.92))),
                (New-Object System.Drawing.PointF([float]($cx + $s * $r * 0.50), [float]($cy - $r * 0.18)))))
        $g.FillPath($ear, $p)
        $p.Dispose()
    }
    $ear.Dispose()

    $body = New-Object System.Drawing.Drawing2D.GraphicsPath
    $body.StartFigure()
    $body.AddBezier([float]$cx, [float]($cy - $r * 1.06),
        [float]($cx + $r * 0.60), [float]($cy - $r * 0.28),
        [float]($cx + $r * 0.58), [float]($cy + $r * 0.56),
        [float]$cx, [float]($cy + $r * 0.80))
    $body.AddBezier([float]$cx, [float]($cy + $r * 0.80),
        [float]($cx - $r * 0.58), [float]($cy + $r * 0.56),
        [float]($cx - $r * 0.60), [float]($cy - $r * 0.28),
        [float]$cx, [float]($cy - $r * 1.06))
    $body.CloseFigure()
    $fill = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        (New-Object System.Drawing.RectangleF(0, 0, 1, 1)),
        [System.Drawing.Color]::FromArgb(255, 240, 244, 249),
        [System.Drawing.Color]::FromArgb(255, 170, 192, 210), 90.0)
    $g.FillPath($fill, $body)
    $fill.Dispose(); $body.Dispose()

    $seal = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(235, 214, 69, 69))
    $sr = [float]($r * 0.135)
    $g.FillEllipse($seal, [float]($cx - $sr), [float]($cy - $r * 0.50), [float]($sr * 2), [float]($sr * 2))
    $seal.Dispose()

    $eye = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(235, 30, 41, 59))
    $er = [float]($r * 0.095)
    foreach ($s in @(-1.0, 1.0)) {
        $ex = [float]($cx + $s * $r * 0.23)
        $ey = [float]($cy + $r * 0.14)
        $g.FillEllipse($eye, [float]($ex - $er), [float]($ey - $er), [float]($er * 2), [float]($er * 2))
    }
    $eye.Dispose()
}

function New-Center([bool]$wrap) {
    $fmt = New-Object System.Drawing.StringFormat
    $fmt.Alignment = [System.Drawing.StringAlignment]::Center
    $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
    if (-not $wrap) {
        # Default StringFormat auto-wraps: a slightly large size splits the
        # slogan onto two lines and the gold rule lands on top of the second.
        $fmt.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap
        $fmt.Trimming = [System.Drawing.StringTrimming]::None
    }
    return $fmt
}

# Largest size (px) at which $text still fits inside $targetW on one line.
function Fit-Font($g, [string]$text, [float]$targetW, [float]$cap) {
    $probe = New-Object System.Drawing.Font('Microsoft YaHei', 10.0, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
    $w = $g.MeasureString($text, $probe, [System.Drawing.PointF]::Empty, (New-Center $false)).Width
    $probe.Dispose()
    if ($w -le 0) { return $cap }
    return [math]::Min($cap, $cap * $targetW / $w)
}

# Draw the three text lines stacked inside a column whose horizontal centre is
# $cx and whose top edge is $top. Draws everything and returns nothing: an
# earlier version returned the bottom y, and PowerShell's output pipeline
# turned that into an Object[] that blew up the caller's arithmetic.
function Draw-Text($g, [float]$cx, [float]$top, [float]$colW,
                   [float]$tCap, [float]$sCap, [float]$cSize) {
    $x0 = [float]($cx - $colW / 2)
    $tFs = Fit-Font $g $title $colW $tCap
    $titleFont = New-Object System.Drawing.Font('Microsoft YaHei', $tFs,
        [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $g.DrawString($title, $titleFont, [System.Drawing.Brushes]::White,
        (New-Object System.Drawing.RectangleF($x0, $top, $colW, [float]($tFs * 1.22))), (New-Center $false))
    $titleFont.Dispose()

    $y = [float]($top + $tFs * 1.22)
    $ruleW = [float]($colW * 0.26)
    $ruleH = [float][math]::Max(2.0, $colW * 0.011)
    $accent = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 255, 214, 90))
    $g.FillRectangle($accent, [float]($cx - $ruleW / 2), $y, $ruleW, $ruleH)
    $accent.Dispose()
    $y = [float]($y + $ruleH)

    $sFs = Fit-Font $g $line $colW $sCap
    $sFont = New-Object System.Drawing.Font('Microsoft YaHei', $sFs,
        [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
    $muted = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(238, 216, 226, 238))
    $y = [float]($y + $colW * 0.085)
    $g.DrawString($line, $sFont, $muted,
        (New-Object System.Drawing.RectangleF($x0, $y, $colW, [float]($sFs * 1.35))), (New-Center $false))
    $sFont.Dispose(); $muted.Dispose()
    $y = [float]($y + $sFs * 1.35)

    if ($cSize -gt 0) {
        $cFont = New-Object System.Drawing.Font('Microsoft YaHei', $cSize,
            [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
        $faint = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(140, 148, 163, 184))
        $g.DrawString($tag, $cFont, $faint,
            (New-Object System.Drawing.RectangleF($x0, [float]($y + $colW * 0.05), $colW, [float]($cSize * 1.6))),
            (New-Center $false))
        $cFont.Dispose(); $faint.Dispose()
    }
}

# Two arrangements: stacked for portrait/square, side-by-side for landscape.
# Deriving every size from min(w,h) keeps one function usable for all three
# exports - scaling everything by width blows the vertical stack off-canvas.
function New-Slogan([int]$w, [int]$h) {
    $pair = New-Gfx $w $h
    $bmp = $pair[0]; $g = $pair[1]
    Fill-Bg $g $w $h

    $fw = [float]$w; $fh = [float]$h
    $min = [math]::Min($fw, $fh)
    $landscape = ($fw / $fh) -gt 1.35

    if ($landscape) {
        $r = [float]($fh * 0.20)
        Draw-Mark $g ([float]($fw * 0.245)) ([float]($fh * 0.50)) $r
        Draw-Text $g ([float]($fw * 0.655)) ([float]($fh * 0.20)) ([float]($fw * 0.50)) `
            ([float]($fh * 0.20)) ([float]($fh * 0.088)) ([float]($fh * 0.046))
    }
    else {
        $r = [float]($min * 0.125)
        $markCy = [float]($fh * 0.265)
        Draw-Mark $g ([float]($fw * 0.50)) $markCy $r
        $colW = [float]($fw * 0.78)
        $tCap = [float]($min * 0.155)
        $tFs = Fit-Font $g $title $colW $tCap
        $top = [float]($markCy + $r * 1.25 + $tFs * 0.30)
        Draw-Text $g ([float]($fw * 0.50)) $top $colW $tCap ([float]($min * 0.072)) ([float]($min * 0.036))
    }

    $g.Dispose()
    return $bmp
}

# app splash - shipped inside the APK, one file per orientation
$p = New-Slogan 900 1600
$p.Save((Join-Path $brand 'splash-portrait.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$p.Dispose()
Write-Host "  assets/brand/splash-portrait.png (900x1600)"

$l = New-Slogan 1600 640
$l.Save((Join-Path $brand 'splash-landscape.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$l.Dispose()
Write-Host "  assets/brand/splash-landscape.png (1600x640)"

$old = Join-Path $brand 'splash.png'
if (Test-Path $old) { Remove-Item $old -Force }

# website hero (landscape) - shipped on docs/assets
$web = New-Slogan 1600 640
$web.Save((Join-Path $webOut 'slogan.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$web.Dispose()
Write-Host "  docs/assets/slogan.png (1600x640)"

# Backdrop for splash.html - gradient + mark ONLY, no baked-in text.
#
# Why no text: the page puts the slogan in real HTML (selectable, screen-reader
# reachable, and it reflows). Baking it into a 1080x1920 portrait image meant a
# landscape viewport got it `cover`-cropped, and the buttons landed on top of it.
# One decoration-only backdrop works at every aspect ratio.
function New-Backdrop([int]$w, [int]$h) {
    $pair = New-Gfx $w $h
    $bmp = $pair[0]; $g = $pair[1]
    Fill-Bg $g $w $h
    $min = [math]::Min([float]$w, [float]$h)
    Draw-Mark $g ([float]($w / 2)) ([float]($h * 0.24)) ([float]($min * 0.10))
    $g.Dispose()
    return $bmp
}

$bp = New-Backdrop 1080 1920
$bp.Save((Join-Path $webOut 'bg-portrait.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$bp.Dispose()
Write-Host "  docs/assets/bg-portrait.png (1080x1920)"

$bl = New-Backdrop 1600 900
$bl.Save((Join-Path $webOut 'bg-landscape.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$bl.Dispose()
Write-Host "  docs/assets/bg-landscape.png (1600x900)"

$oldBg = Join-Path $webOut 'splash-bg.png'
if (Test-Path $oldBg) { Remove-Item $oldBg -Force }

Write-Host "done"