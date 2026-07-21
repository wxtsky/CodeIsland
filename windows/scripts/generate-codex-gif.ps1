param(
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\source\codex.gif'),
    [string]$BackgroundColor = '#000000'
)

Add-Type -AssemblyName System.Drawing

function Set-IndexRect {
    param([byte[]]$Pixels, [int]$X, [int]$Y, [int]$Width, [int]$Height, [byte]$ColorIndex)
    for ($py = $Y; $py -lt ($Y + $Height); $py++) {
        for ($px = $X; $px -lt ($X + $Width); $px++) { $Pixels[$py * 32 + $px] = $ColorIndex }
    }
}

function New-PetFrame {
    param([int]$FrameIndex, [System.Drawing.Color]$Background)
    $bitmap = [System.Drawing.Bitmap]::new(32, 32, [System.Drawing.Imaging.PixelFormat]::Format8bppIndexed)
    $palette = $bitmap.Palette
    $palette.Entries[0] = $Background
    $palette.Entries[1] = [System.Drawing.Color]::White
    $palette.Entries[2] = [System.Drawing.Color]::Black
    $palette.Entries[3] = [System.Drawing.Color]::FromArgb(112, 112, 112)
    $bitmap.Palette = $palette
    $pixels = [byte[]]::new(32 * 32)
    $offsets = @(1, 0, 0, 0, 0, 1)
    $y = $offsets[$FrameIndex]

    Set-IndexRect $pixels 9 (8 + $y) 14 2 1
    Set-IndexRect $pixels 7 (10 + $y) 18 11 1
    Set-IndexRect $pixels 5 (12 + $y) 2 6 1
    Set-IndexRect $pixels 25 (12 + $y) 2 6 1
    Set-IndexRect $pixels 9 (21 + $y) 5 3 1
    Set-IndexRect $pixels 18 (21 + $y) 5 3 1
    Set-IndexRect $pixels 7 (24 + $y) 18 2 3
    if ($FrameIndex -eq 3) {
        Set-IndexRect $pixels 10 (14 + $y) 4 1 2
        Set-IndexRect $pixels 18 (14 + $y) 4 1 2
    }
    else {
        Set-IndexRect $pixels 11 (13 + $y) 2 3 2
        Set-IndexRect $pixels 19 (13 + $y) 2 3 2
    }
    Set-IndexRect $pixels 14 (18 + $y) 4 1 2
    $data = $bitmap.LockBits([System.Drawing.Rectangle]::new(0, 0, 32, 32),
        [System.Drawing.Imaging.ImageLockMode]::WriteOnly, [System.Drawing.Imaging.PixelFormat]::Format8bppIndexed)
    try { [System.Runtime.InteropServices.Marshal]::Copy($pixels, 0, $data.Scan0, $pixels.Length) }
    finally { $bitmap.UnlockBits($data) }
    return $bitmap
}

$resolvedOutput = [System.IO.Path]::GetFullPath($OutputPath)
[System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($resolvedOutput)) | Out-Null
$background = [System.Drawing.ColorTranslator]::FromHtml($BackgroundColor)
$frames = @(for ($i = 0; $i -lt 6; $i++) { New-PetFrame $i $background })
try {
    $encodedFrames = foreach ($frame in $frames) {
        $memory = [System.IO.MemoryStream]::new()
        try {
            $frame.Save($memory, [System.Drawing.Imaging.ImageFormat]::Gif)
            ,$memory.ToArray()
        }
        finally { $memory.Dispose() }
    }

    $first = $encodedFrames[0]
    $colorTableLength = 3 * [math]::Pow(2, (($first[10] -band 7) + 1))
    $prefixLength = 13 + $colorTableLength
    $output = [System.Collections.Generic.List[byte]]::new()
    $output.AddRange([byte[]]$first[0..($prefixLength - 1)])
    $output.AddRange([byte[]](0x21,0xFF,0x0B,0x4E,0x45,0x54,0x53,0x43,0x41,0x50,0x45,0x32,0x2E,0x30,0x03,0x01,0x00,0x00,0x00))

    foreach ($encoded in $encodedFrames) {
        $imageStart = [Array]::IndexOf($encoded, [byte]0x2C, $prefixLength)
        if ($imageStart -lt 0) { throw 'Encoded GIF frame has no image descriptor.' }
        $output.AddRange([byte[]](0x21,0xF9,0x04,0x04,0x0C,0x00,0x00,0x00))
        $output.AddRange([byte[]]$encoded[$imageStart..($encoded.Length - 2)])
    }
    $output.Add(0x3B)
    [System.IO.File]::WriteAllBytes($resolvedOutput, $output.ToArray())
}
finally {
    foreach ($frame in $frames) { $frame.Dispose() }
}

Write-Output "Generated $resolvedOutput (32x32, 6 frames)"
