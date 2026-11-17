param([string]$Runtime = "win-x64")
$ErrorActionPreference = "Stop"
$Root = Split-Path $PSScriptRoot -Parent
Set-Location $Root
if ($Runtime -ne "win-x64") { throw "This package currently targets Windows x64." }
$Output = Join-Path $Root "build/RemoteMouse-Windows"
$Target = "x86_64-pc-windows-msvc"
cargo build --release -p atv-cli --target $Target
if ($LASTEXITCODE -ne 0) { throw "Rust build failed" }
cargo build --release --manifest-path integrations/web-remote/windows/Cargo.toml --target $Target
if ($LASTEXITCODE -ne 0) { throw "Web remote Rust build failed" }
dotnet publish windows-app/RemoteMouse.csproj -c Release -r $Runtime --self-contained true -o $Output
if ($LASTEXITCODE -ne 0) { throw ".NET publish failed" }
Copy-Item "target/$Target/release/atv-cli.exe" "$Output/RemoteMouse.Core.exe" -Force
Copy-Item "integrations/web-remote/windows/target/$Target/release/PCRemote.exe" "$Output/RemoteMouse.WebRemote.exe" -Force
Copy-Item windows-app/README.md "$Output/README.md" -Force
Compress-Archive -Path $Output -DestinationPath "build/RemoteMouse-windows-x64.zip" -Force
Write-Host "Package: build/RemoteMouse-windows-x64.zip"
