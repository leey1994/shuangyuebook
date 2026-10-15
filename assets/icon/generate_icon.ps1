# 爽阅 app icon generator — draws the mark and emits all required sizes.
# Run: powershell -File assets/icon/generate_icon.ps1
# ponytail: System.Drawing one-shot script instead of an icon-design dependency.
Add-Type -AssemblyName System.Drawing

$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$out = Join-Path $PSScriptRoot 'sizes'
New-Item -ItemType Directory -Force -Path $out | Out-Null

function New-Gfx([int]$size) {
    $bmp = New-Object System.Drawing.Bitmap($size, $size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.PixelOffsetMode = 'HighQuality'
    $g.InterpolationMode = 'HighQualityBicubic'
    return @($bmp, $g)
}

# 渐变底：teal -> indigo。
#
# $rounded 只用于传统方形图标。自适应图标的 background 层必须满幅（系统自己
# 裁形状），不能切圆角，否则圆形 mask 下四角会露出透明缺口。
function New-Gradient([int]$size, [bool]$rounded) {
    $pair = New-Gfx $size
    $bmp = $pair[0]; $g = $pair[1]
    $s = [float]$size
    $rect = New-Object System.Drawing.RectangleF(0, 0, $s, $s)
    $c1 = [System.Drawing.Color]::FromArgb(255, 16, 150, 130)   # teal
    $c2 = [System.Drawing.Color]::FromArgb(255, 30, 64, 175)    # indigo
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, $c1, $c2, 60.0)
    if ($rounded) {
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        $r = $s * 0.20
        $d = New-Object System.Drawing.RectangleF(0, 0, $s, $s)
        $path.AddArc($d.X, $d.Y, $r * 2, $r * 2, 180, 90)
        $path.AddArc($d.Right - $r * 2, $d.Y, $r * 2, $r * 2, 270, 90)
        $path.AddArc($d.Right - $r * 2, $d.Bottom - $r * 2, $r * 2, $r * 2, 0, 90)
        $path.AddArc($d.X, $d.Bottom - $r * 2, $r * 2, $r * 2, 90, 90)
        $path.CloseFigure()
        $g.SetClip($path)
    }
    $g.FillRectangle($brush, $rect)
    $g.Dispose()
    return $bmp
}

# 「爽阅」字标：白色粗体 + 柔和投影 + 金色下划线。透明底。
function New-Mark([int]$size) {
    $pair = New-Gfx $size
    $bmp = $pair[0]; $g = $pair[1]
    $s = [float]$size
    $g.Clear([System.Drawing.Color]::Transparent)

    # 必须显式 NoWrap：默认 StringFormat 会自动换行，字号稍大就把
    # 「爽阅」拆成上下两行，黄色下划线正好压在第二个字上。
    $fmt = New-Object System.Drawing.StringFormat
    $fmt.Alignment = [System.Drawing.StringAlignment]::Center
    $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
    $fmt.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap
    $fmt.Trimming = [System.Drawing.StringTrimming]::None

    # 按目标宽度反推字号，保证任何画布尺寸下都单行且撑满安全区
    $targetW = $s * 0.80
    $probe = New-Object System.Drawing.Font('Microsoft YaHei', 100.0, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $probeW = $g.MeasureString([string]'爽阅', $probe, [System.Drawing.PointF]::Empty, $fmt).Width
    $probe.Dispose()
    $fontSize = [float](100.0 * $targetW / $probeW)

    $font = New-Object System.Drawing.Font('Microsoft YaHei', $fontSize, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $layout = New-Object System.Drawing.RectangleF(0, 0, $s, $s * 0.86)
    $shadow = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(90, 0, 0, 0))
    $shadowRect = New-Object System.Drawing.RectangleF(0, [float]($s * 0.026), $s, $s * 0.86)
    $g.DrawString([string]'爽阅', $font, $shadow, $shadowRect, $fmt)
    $g.DrawString([string]'爽阅', $font, [System.Drawing.Brushes]::White, $layout, $fmt)
    $font.Dispose()

    # 金色下划线（保留旧配色里的火花色作为品牌线索）
    $accent = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 255, 214, 90))
    $barW = $targetW
    $barH = [float]([math]::Max(2, $s * 0.035))
    $g.FillRectangle($accent, ($s - $barW) / 2, $s * 0.775, $barW, $barH)
    $g.Dispose()
    return $bmp
}

# 传统方形图标：圆角渐变 + 字标
function New-IconBitmap([int]$size) {
    $bg = New-Gradient $size $true
    $mark = New-Mark $size
    $g = [System.Drawing.Graphics]::FromImage($bg)
    $g.DrawImage($mark, 0, 0, $size, $size)
    $g.Dispose(); $mark.Dispose()
    return $bg
}

function Save-Size([int]$size, [string]$name) {
    $b = New-IconBitmap $size
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

# ---------------------------------------------------------------- adaptive icon
# 画布 108dp。系统把中间 72dp 裁成实际形状，字标必须落在中心 66dp 的安全区内，
# 否则圆形 mask 下会被切掉。
#
# 关键：各密度要**各自尺寸**的图层。之前所有密度都塞同一张 432px，
# 小屏机会被放大到糊。
# background 层满幅渐变，**绝不能带字标** —— 否则和 foreground 叠成两重错位重影。
function New-AdaptiveBackground([int]$size) {
    return (New-Gradient $size $false)
}

function New-AdaptiveForeground([int]$size) {
    $pair = New-Gfx $size
    $bmp = $pair[0]; $g = $pair[1]
    $g.Clear([System.Drawing.Color]::Transparent)
    $s = [float]$size
    $safe = [int]($s * 66.0 / 108.0)           # 中心 66dp 安全区
    $off = [int](($s - $safe) / 2)
    $mark = New-Mark $safe
    $g.DrawImage($mark, $off, $off, $safe, $safe)
    $g.Dispose(); $mark.Dispose()
    return $bmp
}

# Android 13+ 主题图标（themed icon）只认这一层，必须是单色剪影。
# 缺了它，部分启动器会把自适应图标退化成只剩背景层 —— 也就是用户看到的
# 「一个蓝色方块」。
function New-AdaptiveMonochrome([int]$size) {
    $pair = New-Gfx $size
    $bmp = $pair[0]; $g = $pair[1]
    $g.Clear([System.Drawing.Color]::Transparent)
    $s = [float]$size
    $safe = [int]($s * 66.0 / 108.0)
    $off = [int](($s - $safe) / 2)
    $mark = New-Mark $safe
    # 把字标整体染成纯黑（系统会按主题重新上色）
    $tint = New-Object System.Drawing.Imaging.ColorMatrix
    $imgAttr = New-Object System.Drawing.Imaging.ImageAttributes
    $imgAttr.SetColorMatrix($tint)
    $cm = New-Object System.Drawing.Imaging.ColorMatrix
    $cm.Matrix00 = 0; $cm.Matrix11 = 0; $cm.Matrix22 = 0
    $cm.Matrix33 = 1; $cm.Matrix44 = 1
    $cm.Matrix40 = 0; $cm.Matrix41 = 0; $cm.Matrix42 = 0; $cm.Matrix44 = 1
    $imgAttr.SetColorMatrix($cm)
    $dst = New-Object System.Drawing.Rectangle($off, $off, $safe, $safe)
    $g.DrawImage($mark, $dst, 0, 0, $mark.Width, $mark.Height,
        [System.Drawing.GraphicsUnit]::Pixel, $imgAttr)
    $g.Dispose(); $mark.Dispose(); $imgAttr.Dispose()
    return $bmp
}

function Save-Adaptive([int]$size, [string]$name) {
    (New-AdaptiveBackground $size).Save((Join-Path $out "$name-bg.png"),
        [System.Drawing.Imaging.ImageFormat]::Png)
    (New-AdaptiveForeground $size).Save((Join-Path $out "$name-fg.png"),
        [System.Drawing.Imaging.ImageFormat]::Png)
    (New-AdaptiveMonochrome $size).Save((Join-Path $out "$name-mono.png"),
        [System.Drawing.Imaging.ImageFormat]::Png)
    Write-Host "  $name ($size)"
}

# 108dp @ 各密度
Save-Adaptive 108 'adaptive-mdpi'
Save-Adaptive 162 'adaptive-hdpi'
Save-Adaptive 216 'adaptive-xhdpi'
Save-Adaptive 324 'adaptive-xxhdpi'
Save-Adaptive 432 'adaptive-xxxhdpi'

# 预览：按启动器的方式合成（背景 + 前景，再只取中心 66dp 的圆形 mask），
# 用来肉眼确认「用户到底会看到什么」，而不是只看分层文件。
$prev = 432
$safe = [int]($prev * 66.0 / 108.0)      # 启动器实际显示的直径
$off = [int](($prev - $safe) / 2)
$full = New-Object System.Drawing.Bitmap($prev, $prev)
$fg1 = [System.Drawing.Graphics]::FromImage($full)
$bgImg = New-AdaptiveBackground $prev
$fg1.DrawImage($bgImg, 0, 0, $prev, $prev)
$bgImg.Dispose()
$fgImg = New-AdaptiveForeground $prev
$fg1.DrawImage($fgImg, 0, 0, $prev, $prev)
$fgImg.Dispose()
$fg1.Dispose()

# 圆形 mask：先铺透明，再从 full 里取中心 safe×safe
$disc = New-Object System.Drawing.Bitmap($safe, $safe)
$gd = [System.Drawing.Graphics]::FromImage($disc)
$gd.Clear([System.Drawing.Color]::Transparent)
$clip = New-Object System.Drawing.Drawing2D.GraphicsPath
$clip.AddEllipse(0, 0, $safe, $safe)
$gd.SetClip($clip)
$gd.DrawImage($full, (New-Object System.Drawing.Rectangle(0, 0, $safe, $safe)),
    (New-Object System.Drawing.Rectangle($off, $off, $safe, $safe)),
    [System.Drawing.GraphicsUnit]::Pixel)
$gd.ResetClip()
$gd.Dispose(); $clip.Dispose(); $full.Dispose()
$disc.Save((Join-Path $out 'preview-launcher.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$disc.Dispose()
Write-Host "  preview-launcher.png"

# windows .ico: PNG-compressed entries (Vista+)
function New-Ico([string]$path, [int[]]$sizes) {
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    $bw.Write([uint16]0)           # reserved
    $bw.Write([uint16]1)           # type icon
    $bw.Write([uint16]$sizes.Count)
    $blobs = @()
    foreach ($sz in $sizes) {
        $b = New-IconBitmap $sz
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
    $map = [ordered]@{
        'mipmap-mdpi'    = 48
        'mipmap-hdpi'    = 72
        'mipmap-xhdpi'   = 96
        'mipmap-xxhdpi'  = 144
        'mipmap-xxxhdpi' = 192
    }
    $adaptive = [ordered]@{
        'mipmap-mdpi'    = 'adaptive-mdpi'
        'mipmap-hdpi'    = 'adaptive-hdpi'
        'mipmap-xhdpi'   = 'adaptive-xhdpi'
        'mipmap-xxhdpi'  = 'adaptive-xxhdpi'
        'mipmap-xxxhdpi' = 'adaptive-xxxhdpi'
    }
    foreach ($k in $map.Keys) {
        $dir = Join-Path $res $k
        if (-not (Test-Path $dir)) { continue }
        # 传统方形图标
        Copy-Item (Join-Path $out "$k.png") (Join-Path $dir 'ic_launcher.png') -Force
        Copy-Item (Join-Path $out "$k.png") (Join-Path $dir 'ic_launcher_round.png') -Force
        # 自适应图标三层，各密度各自尺寸
        $a = $adaptive[$k]
        Copy-Item (Join-Path $out "$a-fg.png")   (Join-Path $dir 'ic_launcher_foreground.png') -Force
        Copy-Item (Join-Path $out "$a-bg.png")   (Join-Path $dir 'ic_launcher_background.png') -Force
        Copy-Item (Join-Path $out "$a-mono.png") (Join-Path $dir 'ic_launcher_monochrome.png') -Force
    }

    # anydpi-v26 这一层**只放 XML**：放 PNG 会被当作「任意密度不缩放」，
    # 在小屏机上把 432px 硬塞进 108dp，图标会糊掉。
    $anydpi = Join-Path $res 'mipmap-anydpi-v26'
    New-Item -ItemType Directory -Force -Path $anydpi | Out-Null
    Get-ChildItem $anydpi -Filter '*.png' -ErrorAction SilentlyContinue | Remove-Item -Force

    $xml = @(
        '<?xml version="1.0" encoding="utf-8"?>',
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">',
        '    <background android:drawable="@mipmap/ic_launcher_background"/>',
        '    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>',
        '    <monochrome android:drawable="@mipmap/ic_launcher_monochrome"/>',
        '</adaptive-icon>'
    )
    foreach ($n in @('ic_launcher.xml', 'ic_launcher_round.xml')) {
        [System.IO.File]::WriteAllLines((Join-Path $anydpi $n), $xml,
            (New-Object System.Text.UTF8Encoding $false))
    }
    Write-Host "  android mipmaps + adaptive xml updated"
}
# windows runner icon
$winIco = Join-Path $root 'windows\runner\resources\app_icon.ico'
if (Test-Path (Split-Path $winIco)) {
    Copy-Item (Join-Path $out 'app_icon.ico') $winIco -Force
    Write-Host "  windows app_icon.ico updated"
}
Write-Host "done"