# Third-party licenses

ZMarkdown's own source code is under the MIT License (see `LICENSE`). That license
covers only this project's original code. The third-party components it builds on
keep their own licenses, listed here.

## Bundled in this repository

| Component | Used by | License | Location |
| --- | --- | --- | --- |
| webview (C/C++ library) | Linux and Windows UI | MIT | `src/vendor/webview/libs/webview/LICENSE` |
| neroist/webview (Nim binding) | Linux and Windows UI | MIT | `src/vendor/webview/LICENSE` |
| Source Serif 4 (font) | rendered preview | OFL-1.1 | `src/ui/assets/fonts/LICENSE-SourceSerif4.txt` |
| IBM Plex Mono (font) | editor and code | OFL-1.1 | `src/ui/assets/fonts/LICENSE-IBMPlexMono.txt` |

## Fetched at build time, not stored here

| Component | Used by | License | How it is obtained |
| --- | --- | --- | --- |
| Microsoft WebView2 SDK (headers) | Windows build only | Microsoft's own SDK license terms | Downloaded from Microsoft's NuGet package by `scripts/fetch-webview2.ps1` |
| markdown (Nim package) | markdown rendering | MIT | `nimble install` |
| tinyfiledialogs (Nim package + C library) | native file dialogs | zlib | `nimble install` |

The Microsoft WebView2 SDK is deliberately kept out of this repository. It is
Microsoft's, under Microsoft's own license terms (separate from this project), so
rather than redistribute it here we download it from Microsoft's official NuGet
package at build time. The runtime it targets is already part of Windows 11.

## Runtime, provided by the operating system

- Linux: WebKitGTK and GTK 3, installed from the distribution (LGPL / BSD).
- Windows 11: the Microsoft Edge WebView2 runtime, preinstalled with the OS.

Prebuilt release binaries statically link `markdown` (MIT) and `tinyfiledialogs`
(zlib); their notices above apply to those binaries.
