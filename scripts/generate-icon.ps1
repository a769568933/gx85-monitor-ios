$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$gxIconRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'GX85Monitor/Assets.xcassets/AppIcon.appiconset'
New-Item -ItemType Directory -Force -Path $gxIconRoot | Out-Null
$gxBitmap = New-Object System.Drawing.Bitmap(1024, 1024)
$gxGraphics = [System.Drawing.Graphics]::FromImage($gxBitmap)
$gxGraphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$gxGraphics.Clear([System.Drawing.Color]::FromArgb(12, 12, 14))
$gxYellow = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 211, 10), 28)
$gxYellow.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
$gxYellow.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
$gxWhite = New-Object System.Drawing.Pen([System.Drawing.Color]::White, 22)
$gxBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
foreach ($gxCorner in @(@(206,258,326,258), @(206,258,206,378), @(818,258,698,258), @(818,258,818,378), @(206,766,326,766), @(206,766,206,646), @(818,766,698,766), @(818,766,818,646))) {
    $gxGraphics.DrawLine($gxYellow, $gxCorner[0], $gxCorner[1], $gxCorner[2], $gxCorner[3])
}
$gxGraphics.DrawEllipse($gxWhite, 356, 356, 312, 312)
$gxGraphics.FillEllipse($gxBrush, 386, 386, 252, 252)
$gxImages = @()
foreach ($gxEntry in @(@('20x20',2), @('20x20',3), @('29x29',2), @('29x29',3), @('40x40',2), @('40x40',3), @('60x60',2), @('60x60',3))) {
    $gxPoints = [int]($gxEntry[0].Split('x')[0])
    $gxPixels = $gxPoints * $gxEntry[1]
    $gxFilename = 'icon-' + $gxPoints + '@' + $gxEntry[1] + 'x.png'
    $gxSmall = New-Object System.Drawing.Bitmap($gxBitmap, $gxPixels, $gxPixels)
    $gxSmall.Save((Join-Path $gxIconRoot $gxFilename), [System.Drawing.Imaging.ImageFormat]::Png)
    $gxSmall.Dispose()
    $gxImages += @{idiom='iphone';size=$gxEntry[0];scale=($gxEntry[1].ToString() + 'x');filename=$gxFilename}
}
$gxBitmap.Save((Join-Path $gxIconRoot 'icon-1024.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$gxImages += @{idiom='ios-marketing';size='1024x1024';scale='1x';filename='icon-1024.png'}
@{images=$gxImages;info=@{author='xcode';version=1}} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $gxIconRoot 'Contents.json') -Encoding utf8
$gxGraphics.Dispose()
$gxYellow.Dispose()
$gxWhite.Dispose()
$gxBrush.Dispose()
$gxBitmap.Dispose()
Write-Output 'Generated iPhone app icon assets.'
