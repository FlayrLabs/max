# Build a self-contained, unpackaged Max.exe for distribution (run on Windows).
#   pwsh ./publish.ps1            # x64
#   pwsh ./publish.ps1 -Rid win-arm64
param(
    [string]$Rid = "win-x64",
    [string]$Configuration = "Release"
)

$ErrorActionPreference = "Stop"
$proj = Join-Path $PSScriptRoot "Max.Windows/Max.Windows.csproj"

Write-Host "Publishing Max ($Rid, $Configuration)…" -ForegroundColor Cyan
dotnet publish $proj `
    -c $Configuration `
    -r $Rid `
    --self-contained true `
    /p:WindowsAppSDKSelfContained=true `
    /p:WindowsPackageType=None

$out = Join-Path $PSScriptRoot "Max.Windows/bin/$Configuration/net8.0-windows10.0.19041.0/$Rid/publish"
Write-Host "`nDone. Output: $out" -ForegroundColor Green
Write-Host "Distribute the folder (or zip it). Max.exe is the entry point." -ForegroundColor Green
Write-Host "`nTo sign for distribution (recommended):" -ForegroundColor Yellow
Write-Host "  signtool sign /fd SHA256 /a /tr http://timestamp.digicert.com /td SHA256 `"$out\Max.exe`""
