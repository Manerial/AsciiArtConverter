# Façade CLI de compatibilité : .\AsciiArtMask.ps1 -Path photo_pre.png -Mask retouches.png [-Out photo_masked.png]
# Applique seulement la gomme (rouge) ; donner aussi le masque PNG à AsciiArtConverter.ps1 -Mask pour l'exclusion (vert).
# Aucun moteur ici : données/codecs dans AsciiArtRaster.ps1 (AsciiRasterMask), traits dans AsciiArtBrush.ps1 (AsciiBrush).
param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Mask,
    [string]$Out
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'AsciiArtPluginCompilator.ps1')
$typeName = Import-AsciiEngine -File 'AsciiArtRaster.ps1' -Class 'AsciiRasterMask'
$inputPath = (Resolve-Path $Path).Path
$maskPath = (Resolve-Path $Mask).Path
if ($Out -and -not [IO.Path]::IsPathRooted($Out)) { $Out = Join-Path (Get-Location).Path $Out }
if (-not $Out) { $Out = Join-Path (Split-Path $inputPath) ([IO.Path]::GetFileNameWithoutExtension($inputPath) + '_masked.png') }
$source = New-Object Drawing.Bitmap $inputPath
try {
    $marks = New-Object Drawing.Bitmap $maskPath
    try {
        $result = ($typeName -as [type])::Apply($source, $marks, $false)
        try { $result.Save($Out, [Drawing.Imaging.ImageFormat]::Png) } finally { $result.Dispose() }
    } finally { $marks.Dispose() }
} finally { $source.Dispose() }
Write-Output $Out
