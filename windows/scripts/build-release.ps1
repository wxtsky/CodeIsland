param(
    [string]$Configuration = "Release",
    [string]$Runtime = "win-x64"
)

$ErrorActionPreference = "Stop"
$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$artifacts = [System.IO.Path]::GetFullPath((Join-Path $root "artifacts"))
$staging = [System.IO.Path]::GetFullPath((Join-Path $artifacts "staging"))
$bridgeStaging = [System.IO.Path]::GetFullPath((Join-Path $artifacts "bridge"))

foreach ($target in @($staging, $bridgeStaging)) {
    if (-not $target.StartsWith($artifacts, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to clean a path outside the artifacts directory: $target"
    }
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
}

New-Item -ItemType Directory -Path $staging -Force | Out-Null
New-Item -ItemType Directory -Path $bridgeStaging -Force | Out-Null

dotnet publish (Join-Path $root "CodeIsland.Windows\CodeIsland.Windows.csproj") `
    -c $Configuration -r $Runtime --self-contained false -o $staging
if ($LASTEXITCODE -ne 0) { throw "Desktop publish failed with exit code $LASTEXITCODE" }

dotnet publish (Join-Path $root "CodeIsland.Bridge\CodeIsland.Bridge.csproj") `
    -c $Configuration -r $Runtime --self-contained false -o $bridgeStaging
if ($LASTEXITCODE -ne 0) { throw "Bridge publish failed with exit code $LASTEXITCODE" }

foreach ($name in @("CodeIsland.Bridge.exe", "CodeIsland.Bridge.dll", "CodeIsland.Bridge.deps.json", "CodeIsland.Bridge.runtimeconfig.json")) {
    Copy-Item -LiteralPath (Join-Path $bridgeStaging $name) -Destination (Join-Path $staging $name) -Force
}

$version = "0.1.0"
$zip = Join-Path $artifacts "CodeIsland-Windows-$version-$Runtime.zip"
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -Path (Join-Path $staging "*") -DestinationPath $zip -CompressionLevel Optimal
$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
$manifest = [ordered]@{
    version = $version
    runtime = $Runtime
    framework = "net8.0-windows"
    selfContained = $false
    archive = [System.IO.Path]::GetFileName($zip)
    sha256 = $hash
    generatedAtUtc = [DateTime]::UtcNow.ToString("o")
}
$manifest | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $artifacts "release-manifest.json") -Encoding utf8
Write-Output "Release archive: $zip"
Write-Output "SHA256: $hash"
