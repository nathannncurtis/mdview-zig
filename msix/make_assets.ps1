param(
    [string]$Icon = "$PSScriptRoot\..\icon.ico",
    [string]$Out = "$PSScriptRoot\Assets"
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
New-Item -ItemType Directory -Force $Out | Out-Null
$src = [System.Drawing.Icon]::new((Resolve-Path $Icon).Path, 256, 256).ToBitmap()

function Save-Png([int]$size, [string]$name) {
    $bmp = [System.Drawing.Bitmap]::new($size, $size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = 'HighQualityBicubic'
    $g.SmoothingMode = 'HighQuality'
    $g.PixelOffsetMode = 'HighQuality'
    $g.DrawImage($src, 0, 0, $size, $size)
    $g.Dispose()
    $bmp.Save((Join-Path $Out $name), [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}

Save-Png 50 'StoreLogo.png'
Save-Png 150 'Square150x150Logo.png'
Save-Png 44 'Square44x44Logo.png'
foreach ($s in 16, 24, 32, 48, 256) {
    Save-Png $s "Square44x44Logo.targetsize-${s}_altform-unplated.png"
    Save-Png $s "Square44x44Logo.targetsize-${s}_altform-lightunplated.png"
}
