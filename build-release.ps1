param([string]$Output = (Join-Path (Split-Path -Parent $PSScriptRoot) 'zapret2-windows-v0.1.0.zip'))

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
$root = (Resolve-Path -LiteralPath $PSScriptRoot).Path
$outputPath = [IO.Path]::GetFullPath($Output)
if ($outputPath.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The release ZIP must be outside the package directory.'
}
New-Item -ItemType Directory -Path (Split-Path -Parent $outputPath) -Force | Out-Null
if (Test-Path -LiteralPath $outputPath) { Remove-Item -LiteralPath $outputPath -Force }
$stream = [IO.File]::Open($outputPath, [IO.FileMode]::CreateNew)
try {
    $zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $false)
    try {
        $files = @(Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object {
            $relative = $_.FullName.Substring($root.Length + 1).Replace('\', '/')
            $relative -notmatch '^(\.git|runtime)/' -and $relative -notmatch '\.(log|tmp)$'
        })
        foreach ($file in $files) {
            $relative = $file.FullName.Substring($root.Length + 1).Replace('\', '/')
            $entry = $zip.CreateEntry('zapret2-windows/' + $relative, [IO.Compression.CompressionLevel]::Optimal)
            $source = [IO.File]::OpenRead($file.FullName)
            try {
                $destination = $entry.Open()
                try { $source.CopyTo($destination) } finally { $destination.Dispose() }
            } finally { $source.Dispose() }
        }
    } finally { $zip.Dispose() }
} finally { $stream.Dispose() }
Write-Host "Created $outputPath with $($files.Count) files"
