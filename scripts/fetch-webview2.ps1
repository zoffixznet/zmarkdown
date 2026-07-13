# Fetch the Microsoft WebView2 SDK headers needed to build the Windows version.
#
# These headers are deliberately NOT committed to this repository. The WebView2
# SDK is Microsoft's and comes under Microsoft's own license terms, separate from
# this project's license, so rather than redistribute it here we download it from
# Microsoft's official NuGet package at build time. The headers land in a
# git-ignored folder that the build's include path already points at. Linux does
# not use this at all (it uses WebKitGTK).
#
# Set WEBVIEW2_SDK_VERSION to pin a specific SDK version; otherwise the latest
# stable release is used.

$ErrorActionPreference = "Stop"

$dest = Join-Path $PSScriptRoot "..\src\vendor\webview\libs\webview2"

$version = $env:WEBVIEW2_SDK_VERSION
if (-not $version) {
    Write-Host "==> Resolving latest stable Microsoft.Web.WebView2 SDK version from NuGet"
    $index = Invoke-RestMethod -UseBasicParsing `
        -Uri "https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/index.json"
    # Skip pre-release versions (they contain a '-'); take the highest stable one.
    $version = ($index.versions | Where-Object { $_ -notmatch '-' } | Select-Object -Last 1)
}

Write-Host "==> Fetching Microsoft.Web.WebView2 SDK $version from NuGet"
Write-Host "    (Microsoft's SDK, under Microsoft's own license; not stored in this repo)"

$nupkg = Join-Path $env:TEMP "microsoft.web.webview2.$version.nupkg"
$url = "https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/$version/microsoft.web.webview2.$version.nupkg"
Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $nupkg

$extract = Join-Path $env:TEMP "webview2-sdk-$version"
if (Test-Path $extract) { Remove-Item -Recurse -Force $extract }
# A .nupkg is a zip; Expand-Archive needs the .zip extension to be safe.
$zip = "$nupkg.zip"
Copy-Item $nupkg $zip -Force
Expand-Archive -Path $zip -DestinationPath $extract -Force

$includeDir = Join-Path $extract "build\native\include"
if (-not (Test-Path $includeDir)) {
    throw "WebView2 SDK layout unexpected: no build\native\include in the package"
}

New-Item -ItemType Directory -Force -Path $dest | Out-Null
Copy-Item -Path (Join-Path $includeDir "*.h") -Destination $dest -Force

Write-Host "==> WebView2 SDK headers placed in src/vendor/webview/libs/webview2 (git-ignored):"
Get-ChildItem $dest -Filter *.h | ForEach-Object { Write-Host "      $($_.Name)" }
