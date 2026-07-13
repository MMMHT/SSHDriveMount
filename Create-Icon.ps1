[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$assetsDirectory = Join-Path $projectRoot 'assets'
$iconPath = Join-Path $assetsDirectory 'TailMount.ico'
New-Item -ItemType Directory -Path $assetsDirectory -Force | Out-Null

$bitmap = New-Object System.Drawing.Bitmap 256, 256
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit

try {
    $graphics.Clear([System.Drawing.Color]::Transparent)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $radius = 58
    $diameter = $radius * 2
    $path.AddArc(10, 10, $diameter, $diameter, 180, 90)
    $path.AddArc(246 - $diameter, 10, $diameter, $diameter, 270, 90)
    $path.AddArc(246 - $diameter, 246 - $diameter, $diameter, $diameter, 0, 90)
    $path.AddArc(10, 246 - $diameter, $diameter, $diameter, 90, 90)
    $path.CloseFigure()

    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        (New-Object System.Drawing.Point 28, 20),
        (New-Object System.Drawing.Point 228, 238),
        ([System.Drawing.Color]::FromArgb(111, 112, 255)),
        ([System.Drawing.Color]::FromArgb(79, 70, 229)))
    $graphics.FillPath($brush, $path)

    $font = New-Object System.Drawing.Font('Segoe UI', 126, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel))
    $format = New-Object System.Drawing.StringFormat
    $format.Alignment = [System.Drawing.StringAlignment]::Center
    $format.LineAlignment = [System.Drawing.StringAlignment]::Center
    $textBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
    $graphics.DrawString('T', $font, $textBrush, (New-Object System.Drawing.RectangleF 0, -5, 256, 256), $format)

    $pngStream = New-Object System.IO.MemoryStream
    $bitmap.Save($pngStream, [System.Drawing.Imaging.ImageFormat]::Png)
    $pngBytes = $pngStream.ToArray()

    $fileStream = [System.IO.File]::Create($iconPath)
    $writer = New-Object System.IO.BinaryWriter($fileStream)
    try {
        $writer.Write([UInt16]0)
        $writer.Write([UInt16]1)
        $writer.Write([UInt16]1)
        $writer.Write([Byte]0)
        $writer.Write([Byte]0)
        $writer.Write([Byte]0)
        $writer.Write([Byte]0)
        $writer.Write([UInt16]1)
        $writer.Write([UInt16]32)
        $writer.Write([UInt32]$pngBytes.Length)
        $writer.Write([UInt32]22)
        $writer.Write($pngBytes)
    }
    finally {
        $writer.Dispose()
    }
}
finally {
    if ($textBrush) { $textBrush.Dispose() }
    if ($format) { $format.Dispose() }
    if ($font) { $font.Dispose() }
    if ($brush) { $brush.Dispose() }
    if ($path) { $path.Dispose() }
    if ($graphics) { $graphics.Dispose() }
    if ($bitmap) { $bitmap.Dispose() }
}

Write-Host "图标已生成：$iconPath" -ForegroundColor Green
