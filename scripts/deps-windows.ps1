# Install the build dependencies for ZMarkdown on Windows 11.
#
# Installs Nim via choosenim (per-user) and the pinned nimble packages. The Edge
# WebView2 runtime is already present on Windows 11, so nothing else is needed to
# build or run. Run from a PowerShell prompt:
#
#     powershell -ExecutionPolicy Bypass -File scripts\deps-windows.ps1

$ErrorActionPreference = "Stop"

function Have($name) { $null -ne (Get-Command $name -ErrorAction SilentlyContinue) }

Write-Host "==> This installs (per-user, no administrator rights needed):"
Write-Host "      Nim toolchain      via choosenim, into %USERPROFILE%\.nimble"
Write-Host "      markdown 0.8.8     Nim library, renders the markdown preview"
Write-Host "      tinyfiledialogs    Nim library, native open/save/message dialogs"
Write-Host "    The Edge WebView2 runtime is already present on Windows 11, so"
Write-Host "    nothing needs to be installed system-wide."
Write-Host ""

if (-not (Have "nim")) {
    Write-Host "==> Installing Nim via choosenim"
    $env:CHOOSENIM_NO_ANALYTICS = "1"
    # Official choosenim Windows bootstrapper.
    Invoke-WebRequest -UseBasicParsing `
        -Uri "https://nim-lang.org/choosenim/init.ps1" `
        -OutFile "$env:TEMP\choosenim-init.ps1"
    powershell -ExecutionPolicy Bypass -File "$env:TEMP\choosenim-init.ps1" -y

    # choosenim installs into %USERPROFILE%\.nimble\bin
    $nimbleBin = Join-Path $env:USERPROFILE ".nimble\bin"
    $env:PATH = "$nimbleBin;$env:PATH"
} else {
    Write-Host "==> Nim already installed: $(nim --version | Select-Object -First 1)"
}

$nimbleBin = Join-Path $env:USERPROFILE ".nimble\bin"
$env:PATH = "$nimbleBin;$env:PATH"

Write-Host "==> Installing pinned nimble dependencies"
# The webview binding is vendored in the repo; only these registry packages are
# fetched.
nimble install -y "markdown@0.8.8"
nimble install -y "tinyfiledialogs@3.21.3"

Write-Host "==> Done. Build with: nim cpp -d:release --app:gui -o:build\zmarkdown.exe src\zmarkdown.nim"
