# Install the build dependencies for ZMarkdown on Windows 11.
#
# Installs Nim via choosenim (per-user) if no Nim is present, then fetches the
# Microsoft WebView2 SDK headers. The Nim libraries the app uses are vendored in
# the repository, so nimble is not needed and nothing is fetched from a package
# registry. The Edge WebView2 runtime is already present on Windows 11, so nothing
# else is needed to build or run. Run from a PowerShell prompt:
#
#     powershell -ExecutionPolicy Bypass -File scripts\deps-windows.ps1

$ErrorActionPreference = "Stop"

function Have($name) { $null -ne (Get-Command $name -ErrorAction SilentlyContinue) }

Write-Host "==> This installs (per-user, no administrator rights needed):"
Write-Host "      Nim toolchain      via choosenim, into %USERPROFILE%\.nimble, only if"
Write-Host "                         no Nim is present; an existing one is left alone"
Write-Host "      WebView2 SDK       Microsoft headers, downloaded from NuGet (not"
Write-Host "                         stored in this repo; Microsoft's own license)"
Write-Host "    The Nim libraries the app uses are vendored in the repository, and the"
Write-Host "    Edge WebView2 runtime is already present on Windows 11, so nothing"
Write-Host "    needs to be installed system-wide."
Write-Host ""

# choosenim installs into %USERPROFILE%\.nimble\bin, so put that on PATH before
# looking for nim: a shell that could not see an existing installation is what
# made earlier versions of this script install Nim again.
$nimbleBin = Join-Path $env:USERPROFILE ".nimble\bin"
$env:PATH = "$nimbleBin;$env:PATH"

if (Have "nim") {
    # Whatever Nim is there is left alone; this script never upgrades or
    # reinstalls an existing one.
    Write-Host "==> Nim already installed, leaving it alone: $(nim --version | Select-Object -First 1)"
} elseif (Test-Path (Join-Path $nimbleBin "choosenim.exe")) {
    # choosenim is present but no toolchain is selected. Ask it for one directly
    # rather than re-running the bootstrapper, which downloads choosenim again and
    # can leave a second toolchain next to the first.
    Write-Host "==> choosenim is installed but no Nim is selected; installing stable Nim"
    $env:CHOOSENIM_NO_ANALYTICS = "1"
    choosenim stable -y
} else {
    Write-Host "==> Installing Nim via choosenim"
    $env:CHOOSENIM_NO_ANALYTICS = "1"
    # Official choosenim Windows bootstrapper.
    Invoke-WebRequest -UseBasicParsing `
        -Uri "https://nim-lang.org/choosenim/init.ps1" `
        -OutFile "$env:TEMP\choosenim-init.ps1"
    powershell -ExecutionPolicy Bypass -File "$env:TEMP\choosenim-init.ps1" -y
}

# The Microsoft WebView2 SDK is not stored in this repo (Microsoft's own license);
# fetch its headers from NuGet so the Windows build can compile.
& (Join-Path $PSScriptRoot "fetch-webview2.ps1")

Write-Host "==> Done. Build (from Git Bash, so the vendored PCRE static library"
Write-Host "    is compiled first; MinGW gcc must be on PATH):"
Write-Host "      bash scripts/build-pcre.sh"
Write-Host "      nim cpp -d:release --app:gui -o:build/zmarkdown.exe src/zmarkdown.nim"
