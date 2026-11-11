$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Add-Type -AssemblyName System.Drawing

$iconDirectory = Join-Path $PSScriptRoot 'icons'
$highResolutionPng = Join-Path $iconDirectory 'codex-c-1024.png'
$previewPng = Join-Path $iconDirectory 'codex-c-256.png'
$iconPath = Join-Path $iconDirectory 'codex-c.ico'

function New-RoundedRectanglePath {
    param(
        [Parameter(Mandatory = $true)]
        [System.Drawing.RectangleF]$Rectangle,

        [Parameter(Mandatory = $true)]
        [float]$Radius
    )

    $diameter = $Radius * 2
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc($Rectangle.Left, $Rectangle.Top, $diameter, $diameter, 180, 90)
    $path.AddArc($Rectangle.Right - $diameter, $Rectangle.Top, $diameter, $diameter, 270, 90)
    $path.AddArc($Rectangle.Right - $diameter, $Rectangle.Bottom - $diameter, $diameter, $diameter, 0, 90)
    $path.AddArc($Rectangle.Left, $Rectangle.Bottom - $diameter, $diameter, $diameter, 90, 90)
    $path.CloseFigure()
    return $path
}

function New-CodexIconBitmap {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(16, 2048)]
        [int]$Size
    )

    $bitmap = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)

    try {
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.Clear([System.Drawing.Color]::Transparent)

        $rectangle = [System.Drawing.RectangleF]::new(0, 0, $Size, $Size)
        $backgroundPath = New-RoundedRectanglePath -Rectangle $rectangle -Radius ([float]($Size * 0.22))
        $gradient = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
            $rectangle,
            [System.Drawing.ColorTranslator]::FromHtml('#1769E8'),
            # Blue only: the bar and its icons use no green or teal.
            [System.Drawing.ColorTranslator]::FromHtml('#1147B8'),
            45.0
        )

        try {
            $graphics.FillPath($gradient, $backgroundPath)
        }
        finally {
            $gradient.Dispose()
            $backgroundPath.Dispose()
        }

        $fontFamily = New-Object System.Drawing.FontFamily('Arial')
        $letterPath = New-Object System.Drawing.Drawing2D.GraphicsPath

        try {
            $letterPath.AddString(
                'C',
                $fontFamily,
                [int][System.Drawing.FontStyle]::Bold,
                [float]($Size * 0.68),
                [System.Drawing.PointF]::new(0, 0),
                [System.Drawing.StringFormat]::GenericTypographic
            )

            $bounds = $letterPath.GetBounds()
            $translateX = [float](($Size * 0.505) - ($bounds.Left + ($bounds.Width / 2)))
            $translateY = [float](($Size * 0.47) - ($bounds.Top + ($bounds.Height / 2)))
            $positionMatrix = New-Object System.Drawing.Drawing2D.Matrix
            $positionMatrix.Translate($translateX, $translateY)
            $letterPath.Transform($positionMatrix)
            $positionMatrix.Dispose()

            $shadowPath = $letterPath.Clone()
            $shadowMatrix = New-Object System.Drawing.Drawing2D.Matrix
            $shadowOffset = [float][Math]::Max(1, [Math]::Round($Size * 0.018))
            $shadowMatrix.Translate($shadowOffset, $shadowOffset)
            $shadowPath.Transform($shadowMatrix)
            $shadowMatrix.Dispose()

            $shadowBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(125, 14, 44, 110))
            $letterBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)

            try {
                $graphics.FillPath($shadowBrush, $shadowPath)
                $graphics.FillPath($letterBrush, $letterPath)
            }
            finally {
                $shadowBrush.Dispose()
                $letterBrush.Dispose()
                $shadowPath.Dispose()
            }
        }
        finally {
            $letterPath.Dispose()
            $fontFamily.Dispose()
        }
    }
    finally {
        $graphics.Dispose()
    }

    return $bitmap
}

function Convert-BitmapToPngBytes {
    param(
        [Parameter(Mandatory = $true)]
        [System.Drawing.Bitmap]$Bitmap
    )

    $stream = New-Object System.IO.MemoryStream
    try {
        $Bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
        return $stream.ToArray()
    }
    finally {
        $stream.Dispose()
    }
}

function Write-MultiSizeIcon {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [int[]]$Sizes
    )

    $images = @()
    foreach ($size in $Sizes) {
        $bitmap = New-CodexIconBitmap -Size $size
        try {
            $images += ,(Convert-BitmapToPngBytes -Bitmap $bitmap)
        }
        finally {
            $bitmap.Dispose()
        }
    }

    $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
    $writer = New-Object System.IO.BinaryWriter($stream)

    try {
        $writer.Write([uint16]0)
        $writer.Write([uint16]1)
        $writer.Write([uint16]$Sizes.Count)

        $offset = 6 + ($Sizes.Count * 16)
        for ($index = 0; $index -lt $Sizes.Count; $index++) {
            $size = $Sizes[$index]
            $dimension = if ($size -eq 256) { [byte]0 } else { [byte]$size }
            $data = [byte[]]$images[$index]

            $writer.Write($dimension)
            $writer.Write($dimension)
            $writer.Write([byte]0)
            $writer.Write([byte]0)
            $writer.Write([uint16]1)
            $writer.Write([uint16]32)
            $writer.Write([uint32]$data.Length)
            $writer.Write([uint32]$offset)
            $offset += $data.Length
        }

        foreach ($data in $images) {
            $writer.Write([byte[]]$data)
        }
    }
    finally {
        $writer.Dispose()
        $stream.Dispose()
    }
}

New-Item -ItemType Directory -Force -Path $iconDirectory | Out-Null

$largeBitmap = New-CodexIconBitmap -Size 1024
try {
    $largeBitmap.Save($highResolutionPng, [System.Drawing.Imaging.ImageFormat]::Png)
}
finally {
    $largeBitmap.Dispose()
}

$previewBitmap = New-CodexIconBitmap -Size 256
try {
    $previewBitmap.Save($previewPng, [System.Drawing.Imaging.ImageFormat]::Png)
}
finally {
    $previewBitmap.Dispose()
}

Write-MultiSizeIcon -Path $iconPath -Sizes @(16, 32, 48, 64, 128, 256)

Write-Host "Created: $highResolutionPng"
Write-Host "Created: $previewPng"
Write-Host "Created: $iconPath"
