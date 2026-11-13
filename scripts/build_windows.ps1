param([string]$Runtime = "win-x64")
$ErrorActionPreference = "Stop"
$Root = Split-Path $PSScriptRoot -Parent
Set-Location $Root
if ($Runtime -ne "win-x64") { throw "This package currently targets Windows x64." }
$Output = Join-Path $Root "build/TVRemoteMouse-Windows"
$Target = "x86_64-pc-windows-msvc"
cargo build --release -p atv-cli --target $Target
if ($LASTEXITCODE -ne 0) { throw "Rust build failed" }
dotnet publish windows-app/TVRemoteMouse.csproj -c Release -r $Runtime --self-contained true -o $Output
if ($LASTEXITCODE -ne 0) { throw ".NET publish failed" }
Copy-Item "target/$Target/release/atv-cli.exe" "$Output/TVRemoteMouse.Core.exe" -Force
Copy-Item windows-app/README.md "$Output/README.md" -Force
Compress-Archive -Path $Output -DestinationPath "build/TVRemoteMouse-windows-x64.zip" -Force
Write-Host "Package: build/TVRemoteMouse-windows-x64.zip"
