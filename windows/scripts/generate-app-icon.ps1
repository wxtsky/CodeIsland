param([string]$OutputDirectory = (Join-Path $PSScriptRoot '..\source'))

Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class IconNative {
    [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr handle);
}
'@

$output = [System.IO.Path]::GetFullPath($OutputDirectory)
[System.IO.Directory]::CreateDirectory($output) | Out-Null
$bitmap = [System.Drawing.Bitmap]::new(256, 256, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$graphics.Clear([System.Drawing.Color]::Transparent)
$graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
$graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half

function Block([System.Drawing.Brush]$brush, [int]$x, [int]$y, [int]$w, [int]$h) {
    $graphics.FillRectangle($brush, $x * 16, $y * 16, $w * 16, $h * 16)
}

$outline = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(245, 8, 9, 10))
$white = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::White)
$green = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(255, 57, 228, 110))
$blue = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(255, 46, 145, 199))
$gray = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(255, 102, 106, 112))

Block $outline 4 3 8 1; Block $outline 3 4 10 8; Block $outline 2 6 1 4; Block $outline 13 6 1 4
Block $outline 4 12 3 2; Block $outline 9 12 3 2; Block $outline 3 14 10 1
Block $white 4 4 8 1; Block $white 3 5 10 6; Block $white 5 11 2 1; Block $white 9 11 2 1
Block $green 5 7 2 2; Block $green 9 7 2 2; Block $outline 7 10 2 1
Block $blue 3 13 10 1; Block $gray 5 14 6 1

$pngPath = Join-Path $output 'codeisland.png'
$icoPath = Join-Path $output 'codeisland.ico'
$bitmap.Save($pngPath, [System.Drawing.Imaging.ImageFormat]::Png)
$handle = $bitmap.GetHicon()
try {
    $icon = [System.Drawing.Icon]::FromHandle($handle)
    $stream = [System.IO.File]::Open($icoPath, [System.IO.FileMode]::Create)
    try { $icon.Save($stream) } finally { $stream.Dispose(); $icon.Dispose() }
}
finally { [IconNative]::DestroyIcon($handle) | Out-Null }

foreach ($brush in @($outline, $white, $green, $blue, $gray)) { $brush.Dispose() }
$graphics.Dispose(); $bitmap.Dispose()
Write-Output "Generated $pngPath and $icoPath"
