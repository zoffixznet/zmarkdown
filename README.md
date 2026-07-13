# ZMarkdown

A small, fast desktop markdown editor and viewer. One window, three ways to look at a
document: the raw text, the rendered result, or both side by side with a divider you can
drag. You edit in the raw pane; the rendered pane updates live as you type and is styled to
be genuinely pleasant to read, not plain browser HTML.

Written in Nim, it compiles to a single native executable and uses the system webview
(WebKitGTK on Linux, Edge WebView2 on Windows) for the display.

## Get a prebuilt binary

You do not need to build anything. Prebuilt binaries are published on the project's GitHub
Releases page, built by CI and attached to each tagged release. They are not stored in the
repository; the repository holds source only.

- Linux: download the `zmarkdown-<version>-linux-x86_64.tar.gz`, extract it, and run
  `./zmarkdown`. The archive includes an `install.sh` that copies the binary, the desktop
  entry, and the icons into `~/.local` so the app shows up in your menu.
- Windows 11: download the `zmarkdown-<version>-windows-x86_64.zip`, extract it, and run
  `zmarkdown.exe`. No install step is needed; the Edge WebView2 runtime ships with
  Windows 11.

## Supported platforms

- Kubuntu 24.04 (KDE Plasma) on X11 and on Wayland
- Kali Linux (XFCE)
- Windows 11

Other platforms may work but are not supported.

## Runtime requirements (Linux)

The Linux binary links the system GTK3 and WebKitGTK 4.1 libraries, which the desktops
above already ship. It also needs a native dialog helper for open/save and confirmation
prompts: KDE provides `kdialog`; on other desktops install `zenity`. `make deps` installs
`zenity` as a portable fallback. On Windows there is no extra runtime dependency.

## Build from source

Everything goes through the `Makefile`. Run `make` on its own to see every target.

```
make deps    # install the toolchain and libraries (uses sudo for system packages on Linux)
make run     # build and launch the app
make test    # run the unit tests and the headless end-to-end smoke test
make build   # just build the release binary into build/
make dist    # build and package the Linux tarball
```

`make deps` installs the GTK3 and WebKitGTK 4.1 development packages, `zenity`, and `xvfb`
(used by the tests), installs the Nim toolchain via choosenim if it is missing, then fetches
the pinned Nim dependencies. On Windows, run the dependency bootstrap directly:

```
powershell -ExecutionPolicy Bypass -File scripts\deps-windows.ps1
```

then build with:

```
nim cpp -d:release --hints:off -o:build\zmarkdown.exe src\zmarkdown.nim
```

## Using it

- Three view buttons in the toolbar switch between **Text**, **Split**, and **Preview**.
  In Split you can drag the divider all the way to either edge to give one pane the whole
  window.
- Formatting shortcuts in the raw editor: **Ctrl+B** bold, **Ctrl+I** italic, **Ctrl+U**
  underline. With text selected they wrap the selection; with nothing selected they insert
  the markers and place the caret between them. The link and image toolbar buttons insert
  sample markdown you can edit in place.
- File shortcuts: **Ctrl+O** open, **Ctrl+S** save, **Ctrl+Shift+S** save as. The File menu
  in the toolbar has the same actions plus Exit. Open and Save As use native file dialogs.
  If you have unsaved changes when opening another file or exiting, a prompt lets you save,
  discard, or cancel.

The editor stays plain markdown text at all times; the shortcuts only insert or wrap
markdown syntax, they never style the text in the editor itself.

## Configuration

There is no settings screen. The app remembers a little state between runs, stored as JSON:

- Linux: `~/.config/zmarkdown/state.json` (or `$XDG_CONFIG_HOME/zmarkdown/state.json`)
- Windows: `%APPDATA%\ZMarkdown\state.json`

It restores the window size (clamped to your current screen and never below a usable
minimum), the view mode, and the divider position. It does not reopen your previous file:
every launch starts with a fresh, empty document. The app follows your system light or dark
preference automatically. If the state file is missing or unreadable, the app starts with
sensible defaults; if the config directory cannot be written, it simply skips saving state.

## Known limitations

- The app targets Windows 11, where the Edge WebView2 runtime is always present. Earlier
  Windows versions are not supported.
- On Linux the window and taskbar icon rely on your desktop reading the installed desktop
  entry and icons (which `install.sh` sets up) and matching the application's window class.
- Native dialogs require `kdialog` or `zenity` to be installed. Without either, open, save,
  and confirmation dialogs cannot be shown; the app logs this and keeps running rather than
  failing, but those actions will not work until you install one of them.
- The markdown renderer supports CommonMark plus GitHub tables and strikethrough. Task
  lists and bare-URL autolinking are not rendered.
- The app renders your own local document and intentionally lets raw HTML in the markdown
  pass through (this is how the underline shortcut works). It does not sanitize HTML.

## License

The application is MIT licensed. The bundled fonts, Source Serif 4 and IBM Plex Mono, are
under the SIL Open Font License 1.1; their license texts are in
`src/ui/assets/fonts/`.
