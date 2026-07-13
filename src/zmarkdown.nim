## ZMarkdown: a small desktop markdown editor and viewer.
##
## The window contents (toolbar, editor, preview, divider) are HTML/CSS/JS
## embedded into this binary at compile time. All application logic (text
## transforms, markdown rendering, file IO, dialogs, state) is Nim, reached from
## the page through bound procs. The webview is only the display.

import std/[json, os, times, strutils, base64, options, browsers]
import std/atomics

import webview

import core/editing
import core/markdown as md
import core/state
import core/files
import core/dialogs
import core/history as histmod

# Direct native calls for window geometry and the maximized state. On Linux we
# track size and maximized live through GTK signals, so the values are captured
# while the window still exists (the webview destroys it on close, before our
# persistence runs). On Windows we read them from the window on demand. On other
# platforms these paths are compiled out.
when defined(linux):
  {.emit: """/*TYPESECTION*/
#include <gtk/gtk.h>

/* Live window geometry, kept current by GTK signal handlers. The size is
   recorded only while not maximized, so it always holds the size to restore to
   when un-maximizing. */
static int zmWinW = 0;
static int zmWinH = 0;
static int zmWinMax = 0;

static gboolean zm_on_configure(GtkWidget* wdg, GdkEvent* ev, gpointer data) {
  (void)ev; (void)data;
  if (!gtk_window_is_maximized(GTK_WINDOW(wdg))) {
    int ww = 0, hh = 0;
    gtk_window_get_size(GTK_WINDOW(wdg), &ww, &hh);
    if (ww > 0 && hh > 0) { zmWinW = ww; zmWinH = hh; }
  }
  zmWinMax = gtk_window_is_maximized(GTK_WINDOW(wdg)) ? 1 : 0;
  return FALSE;
}

static gboolean zm_on_state(GtkWidget* wdg, GdkEventWindowState* ev, gpointer data) {
  (void)wdg; (void)data;
  zmWinMax = (ev->new_window_state & GDK_WINDOW_STATE_MAXIMIZED) ? 1 : 0;
  return FALSE;
}

extern "C" void zmTrackWindow(void* win) {
  if (!win) return;
  g_signal_connect(G_OBJECT(win), "configure-event", G_CALLBACK(zm_on_configure), NULL);
  g_signal_connect(G_OBJECT(win), "window-state-event", G_CALLBACK(zm_on_state), NULL);
}
extern "C" void zmMaximizeWindow(void* win) { if (win) gtk_window_maximize(GTK_WINDOW(win)); }
extern "C" int zmGetWinW(void)   { return zmWinW; }
extern "C" int zmGetWinH(void)   { return zmWinH; }
extern "C" int zmGetWinMax(void) { return zmWinMax; }
""".}

  proc zmTrackWindow(win: pointer) {.importc, nodecl.}
  proc zmMaximizeWindow(win: pointer) {.importc, nodecl.}
  proc zmGetWinW(): cint {.importc, nodecl.}
  proc zmGetWinH(): cint {.importc, nodecl.}
  proc zmGetWinMax(): cint {.importc, nodecl.}

when defined(windows):
  {.emit: """/*TYPESECTION*/
#include <windows.h>
extern "C" void zmMaximizeWindow(void* hwnd) { if (hwnd) ShowWindow((HWND)hwnd, SW_MAXIMIZE); }
extern "C" int zmGetWinPlacement(void* hwnd, int* w, int* h, int* maxd) {
  WINDOWPLACEMENT wp; wp.length = sizeof(wp);
  if (!hwnd || !GetWindowPlacement((HWND)hwnd, &wp)) return 0;
  *w = wp.rcNormalPosition.right - wp.rcNormalPosition.left;
  *h = wp.rcNormalPosition.bottom - wp.rcNormalPosition.top;
  *maxd = (wp.showCmd == SW_SHOWMAXIMIZED) ? 1 : 0;
  return 1;
}
""".}
  proc zmMaximizeWindow(win: pointer) {.importc, nodecl.}
  proc zmGetWinPlacement(hwnd: pointer; w, h, maxd: ptr cint): cint {.importc, nodecl.}

# ---- Embedded UI assets (compiled into the binary) -------------------------

const
  uiHtml = staticRead("ui/index.html")
  uiCss = staticRead("ui/app.css")
  uiJs = staticRead("ui/app.js")
  # Fonts, embedded as base64 for data: URIs so the page needs no network.
  fontSerif400 = staticRead("ui/assets/fonts/source-serif-4-400.woff2")
  fontSerif600 = staticRead("ui/assets/fonts/source-serif-4-600.woff2")
  fontSerif700 = staticRead("ui/assets/fonts/source-serif-4-700.woff2")
  fontSerifItalic = staticRead("ui/assets/fonts/source-serif-4-400-italic.woff2")
  fontMono400 = staticRead("ui/assets/fonts/ibm-plex-mono-400.woff2")
  fontMono600 = staticRead("ui/assets/fonts/ibm-plex-mono-600.woff2")
  # App icon, embedded so the window can set it without shipping a loose file.
  # Missing at first build (the icon script generates it); guarded so a source
  # checkout without generated PNGs still compiles by falling back to empty.
  iconPng = staticRead("ui/assets/icon-128.png")

# ---- Logging ---------------------------------------------------------------

var verbose = false

proc logLine(msg: string) =
  ## Meaningful events go to stderr. Tests assert on these lines, so keep the
  ## wording stable.
  let ts = now().format("HH:mm:ss")
  stderr.writeLine("[zmarkdown " & ts & "] " & msg)
  stderr.flushFile()

proc vlog(msg: string) =
  if verbose: logLine(msg)

# ---- Font face CSS ---------------------------------------------------------

proc fontFace(family: string, weight: int, style, data: string): string =
  "@font-face{font-family:'" & family & "';font-style:" & style &
    ";font-weight:" & $weight & ";font-display:swap;src:url(data:font/woff2;base64," &
    base64.encode(data) & ") format('woff2');}\n"

proc buildFontFaces(): string =
  result = ""
  result.add fontFace("Source Serif 4", 400, "normal", fontSerif400)
  result.add fontFace("Source Serif 4", 600, "normal", fontSerif600)
  result.add fontFace("Source Serif 4", 700, "normal", fontSerif700)
  result.add fontFace("Source Serif 4", 400, "italic", fontSerifItalic)
  result.add fontFace("IBM Plex Mono", 400, "normal", fontMono400)
  result.add fontFace("IBM Plex Mono", 600, "normal", fontMono600)

# ---- Full page assembly ----------------------------------------------------

proc buildPage(): string =
  ## Inline the fonts into the CSS, then the CSS and JS into the HTML. The result
  ## is a single self-contained document with no external references.
  let css = uiCss.replace("/* FONT_FACES */", buildFontFaces())
  result = "<!doctype html><html><head><meta charset=\"utf-8\">" &
    "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">" &
    "<style>" & css & "</style></head><body>" &
    uiHtml &
    "<script>" & uiJs & "</script>" &
    "</body></html>"

# ---- Application state (Nim side) ------------------------------------------

type
  App = object
    w: Webview
    currentPath: string    ## path of the open file, "" if none
    ui: UiState            ## restored/persisted UI state
    exiting: bool

var app: App

# Plain (non-GC) handles for the watchdog thread, which must be gcsafe and so
# cannot touch the GC'd `app`. The webview handle is just a pointer.
var wdWebview: Webview
var wdDone: Atomic[bool]
var watchdogThread: Thread[void]

proc watchdogProc() {.thread.} =
  ## Terminate the webview if the self-test UI never reports within the timeout,
  ## so CI cannot hang. Touches only the atomic flag and the webview pointer.
  for _ in 0 ..< 400:  # up to ~20s in 50ms slices, so shutdown stays prompt
    sleep(50)
    if wdDone.load(): return
  try: discard wdWebview.terminate() except CatchableError: discard

proc docName(): string =
  if app.currentPath.len > 0: extractFilename(app.currentPath) else: "Untitled"

# ---- JSON helpers for the bridge -------------------------------------------

proc editResultJson(r: EditResult): JsonNode =
  %*{"text": r.text, "selStart": r.selStart, "selEnd": r.selEnd}

# ---- Bound procs (callable from JS) ----------------------------------------
#
# Each returns a JSON string (webview delivers it to JS as a resolved Promise).
# JS awaits them. Errors are caught here so a bad call cannot crash the loop.

proc jsRender(id: string; req: JsonNode): string =
  ## render(src) -> HTML fragment. Never raises; degrades to an inline error.
  let src = if req.len > 0 and req[0].kind == JString: req[0].getStr() else: ""
  let outcome = md.renderOutcome(src)
  if not outcome.ok:
    vlog("render error: " & outcome.error)
  result = $ %* outcome.html

proc jsApplyEdit(id: string; req: JsonNode): string =
  ## applyEdit(kind, text, selStart, selEnd) -> {text, selStart, selEnd}
  try:
    let
      kind = req[0].getStr()
      text = req[1].getStr()
      a = req[2].getInt()
      b = req[3].getInt()
    let r =
      case kind
      of "bold": applyBold(text, a, b)
      of "italic": applyItalic(text, a, b)
      of "underline": applyUnderline(text, a, b)
      of "link": applyLink(text, a, b)
      of "image": applyImage(text, a, b)
      else: EditResult(text: text, selStart: a, selEnd: b)
    result = $ editResultJson(r)
  except CatchableError as e:
    vlog("applyEdit failed: " & e.msg)
    # Return the input unchanged so the editor is never corrupted.
    result = $ %*{"text": (if req.len > 1: req[1].getStr() else: ""),
                  "selStart": 0, "selEnd": 0}

proc jsLoadInitialState(id: string; req: JsonNode): string =
  ## loadInitialState() -> the restored UI state (view and split ratio matter to JS).
  result = $ app.ui.toJson()

proc jsPersistState(id: string; req: JsonNode): string =
  ## persistState(view, ratio). Updates the in-memory state; the actual disk
  ## write happens on exit (and here opportunistically). Fire and forget.
  try:
    if req.len >= 2:
      case req[0].getStr()
      of "text": app.ui.view = vmText
      of "split": app.ui.view = vmSplit
      of "preview": app.ui.view = vmPreview
      else: discard
      app.ui.splitRatio = clampRatio(req[1].getFloat())
  except CatchableError:
    discard
  result = "true"

proc jsSaveSettings(id: string; req: JsonNode): string =
  ## saveSettings(fontChoice, bgColor, textColor). Updates the in-memory settings;
  ## the disk write happens on exit like the other UI state.
  try:
    if req.len >= 1 and req[0].kind == JString: app.ui.fontChoice = req[0].getStr()
    if req.len >= 2 and req[1].kind == JString: app.ui.bgColor = req[1].getStr()
    if req.len >= 3 and req[2].kind == JString: app.ui.textColor = req[2].getStr()
  except CatchableError:
    discard
  result = "true"

proc captureWindowState(): tuple[w, h, maximized: int] =
  ## Read the window's current non-maximized size and whether it is maximized, so
  ## exit persists what the user actually has now. Falls back to the stored values
  ## when the live ones are not available.
  result = (app.ui.width, app.ui.height, (if app.ui.maximized: 1 else: 0))
  when defined(linux):
    # Values tracked live via GTK signals; zmGetWinW/H hold the last size seen
    # while not maximized, so un-maximizing restores to it.
    let lw = zmGetWinW().int
    let lh = zmGetWinH().int
    if lw >= MinWidth and lh >= MinHeight:
      result.w = lw
      result.h = lh
    result.maximized = zmGetWinMax().int
  when defined(windows):
    try:
      let win = getWindow(app.w)
      if win != nil:
        var ww, hh, mx: cint
        if zmGetWinPlacement(win, addr ww, addr hh, addr mx) != 0:
          if ww.int >= MinWidth and hh.int >= MinHeight:
            result.w = ww.int
            result.h = hh.int
          result.maximized = mx.int
    except CatchableError:
      discard

proc persistNow() =
  ## Write current UI state to disk, logging but never failing on error.
  let s = captureWindowState()
  app.ui.width = s.w
  app.ui.height = s.h
  app.ui.maximized = s.maximized != 0
  if saveState(app.ui):
    vlog("state saved: " & statePath())
  else:
    logLine("could not save state (skipping persistence): " & statePath())

# ---- File operations -------------------------------------------------------

proc doOpen(text: string): tuple[opened: bool, content, title: string] =
  ## Show an open dialog and read the chosen file. Errors show a dialog and leave
  ## the current document intact.
  let path = openFileDialog("Open")
  if path.len == 0:
    return (false, "", "")
  let r = readTextFile(path)
  if not r.ok:
    logLine("open failed: " & r.error)
    errorDialog("Open failed", r.error)
    return (false, "", "")
  app.currentPath = path
  logLine("opened " & path)
  (true, r.value, docName())

proc doSaveTo(path, text: string): bool =
  let r = writeTextFile(path, text)
  if not r.ok:
    logLine("save failed: " & r.error)
    errorDialog("Save failed", r.error)
    return false
  app.currentPath = path
  logLine("saved " & path)
  true

proc doSave(text: string): tuple[saved: bool, title: string] =
  ## Save to the current path, or fall through to Save As if there is none.
  if app.currentPath.len == 0:
    let path = saveFileDialog("Save As", "untitled.md")
    if path.len == 0: return (false, docName())
    return (doSaveTo(path, text), docName())
  (doSaveTo(app.currentPath, text), docName())

proc doSaveAs(text: string): tuple[saved: bool, title: string] =
  let suggested = if app.currentPath.len > 0: extractFilename(app.currentPath) else: "untitled.md"
  let path = saveFileDialog("Save As", suggested)
  if path.len == 0: return (false, docName())
  (doSaveTo(path, text), docName())

proc guardUnsaved(dirty: bool, text: string): bool =
  ## When there are unsaved changes, prompt Save / Don't Save / Cancel. Returns
  ## true if it is safe to proceed (saved or discarded), false to abort.
  if not dirty:
    return true
  case unsavedChangesPrompt()
  of spSave:
    let res = doSave(text)
    res.saved
  of spDontSave:
    true
  of spCancel:
    false

proc jsMenuOpen(id: string; req: JsonNode): string =
  ## menuOpen(dirty, text) -> {opened, text, title}
  let dirty = req.len > 0 and req[0].kind == JBool and req[0].getBool()
  let text = if req.len > 1: req[1].getStr() else: ""
  if not guardUnsaved(dirty, text):
    return $ %*{"opened": false}
  let r = doOpen(text)
  $ %*{"opened": r.opened, "text": r.content, "title": r.title}

proc jsMenuNew(id: string; req: JsonNode): string =
  ## menuNew(dirty, text) -> {ok, title}. Guards unsaved changes, then starts a
  ## fresh empty document and forgets the current file path.
  let dirty = req.len > 0 and req[0].kind == JBool and req[0].getBool()
  let text = if req.len > 1: req[1].getStr() else: ""
  if not guardUnsaved(dirty, text):
    return $ %*{"ok": false}
  app.currentPath = ""
  logLine("new document")
  $ %*{"ok": true, "title": docName()}

proc jsOpenPath(id: string; req: JsonNode): string =
  ## openPath(dirty, currentText, path) -> {opened, text, title}. Opens a specific
  ## file (from a drag-and-drop) through the same guard and read path as Open.
  let dirty = req.len > 0 and req[0].kind == JBool and req[0].getBool()
  let curText = if req.len > 1: req[1].getStr() else: ""
  let path = if req.len > 2 and req[2].kind == JString: req[2].getStr() else: ""
  if path.len == 0:
    return $ %*{"opened": false}
  if not guardUnsaved(dirty, curText):
    return $ %*{"opened": false}
  let r = readTextFile(path)
  if not r.ok:
    logLine("open (drop) failed: " & r.error)
    errorDialog("Open failed", r.error)
    return $ %*{"opened": false}
  app.currentPath = path
  logLine("opened (drop) " & path)
  $ %*{"opened": true, "text": r.value, "title": docName()}

proc jsOpenExternal(id: string; req: JsonNode): string =
  ## openExternal(url). Opens an http(s) URL in the system browser so a link in
  ## the preview does not navigate the app's own webview away.
  try:
    if req.len > 0 and req[0].kind == JString:
      let url = req[0].getStr()
      if url.startsWith("http://") or url.startsWith("https://"):
        openDefaultBrowser(url)
  except CatchableError as e:
    vlog("openExternal failed: " & e.msg)
  result = "true"

proc jsMenuSave(id: string; req: JsonNode): string =
  let text = if req.len > 0: req[0].getStr() else: ""
  let r = doSave(text)
  $ %*{"saved": r.saved, "title": r.title}

proc jsMenuSaveAs(id: string; req: JsonNode): string =
  let text = if req.len > 0: req[0].getStr() else: ""
  let r = doSaveAs(text)
  $ %*{"saved": r.saved, "title": r.title}

proc jsRequestExit(id: string; req: JsonNode): string =
  ## requestExit(dirty, text). Honors the unsaved-changes guard, then exits.
  let dirty = req.len > 0 and req[0].kind == JBool and req[0].getBool()
  let text = if req.len > 1: req[1].getStr() else: ""
  if not guardUnsaved(dirty, text):
    return $ %*{"exit": false}
  logLine("exiting")
  app.exiting = true
  persistNow()
  discard app.w.terminate()
  $ %*{"exit": true}

proc jsLog(id: string; req: JsonNode): string =
  if req.len > 0 and req[0].kind == JString:
    vlog("ui: " & req[0].getStr())
  "true"

# ---- Undo/redo history (bounded by memory, not step count) -----------------

var history = initHistory()

proc historyStatus(): JsonNode =
  %*{"canUndo": history.canUndo, "canRedo": history.canRedo}

proc snapshotJson(s: Snapshot): JsonNode =
  %*{"ok": true, "text": s.text, "selStart": s.selStart, "selEnd": s.selEnd,
     "canUndo": history.canUndo, "canRedo": history.canRedo}

proc jsHistoryReset(id: string; req: JsonNode): string =
  ## historyReset(text). Start history over for a new document.
  let text = if req.len > 0 and req[0].kind == JString: req[0].getStr() else: ""
  history.reset(text)
  $ historyStatus()

proc jsHistoryRecord(id: string; req: JsonNode): string =
  ## historyRecord(text, selStart, selEnd). Commit a new editor state.
  try:
    let text = req[0].getStr()
    let a = if req.len > 1: req[1].getInt() else: 0
    let b = if req.len > 2: req[2].getInt() else: 0
    history.record(text, a, b)
  except CatchableError as e:
    vlog("historyRecord failed: " & e.msg)
  $ historyStatus()

proc jsHistoryUndo(id: string; req: JsonNode): string =
  ## historyUndo() -> {ok, text, selStart, selEnd, canUndo, canRedo}
  let u = history.undo()
  if u.isSome: $ snapshotJson(u.get())
  else: $ %*{"ok": false, "canUndo": history.canUndo, "canRedo": history.canRedo}

proc jsHistoryRedo(id: string; req: JsonNode): string =
  ## historyRedo() -> {ok, text, selStart, selEnd, canUndo, canRedo}
  let r = history.redo()
  if r.isSome: $ snapshotJson(r.get())
  else: $ %*{"ok": false, "canUndo": history.canUndo, "canRedo": history.canRedo}

# ---- Window construction ---------------------------------------------------

proc computeRestoreSize(): tuple[w, h: int] =
  ## Clamp the restored size against the current screen so a size saved on a
  ## bigger display cannot exceed this one, and it is never below the minimum.
  var screenW, screenH = 0
  when defined(linux):
    # Read the primary monitor geometry via GDK. Wrapped defensively.
    try:
      {.emit: """
      GdkDisplay* _disp = gdk_display_get_default();
      if (_disp) {
        GdkMonitor* _mon = gdk_display_get_primary_monitor(_disp);
        if (!_mon) _mon = gdk_display_get_monitor(_disp, 0);
        if (_mon) {
          GdkRectangle _r;
          gdk_monitor_get_geometry(_mon, &_r);
          `screenW` = _r.width;
          `screenH` = _r.height;
        }
      }
      """.}
    except CatchableError:
      discard
  clampSize(app.ui.width, app.ui.height, screenW, screenH)

proc bindAll(w: Webview) =
  discard w.bind("render", jsRender)
  discard w.bind("applyEdit", jsApplyEdit)
  discard w.bind("loadInitialState", jsLoadInitialState)
  discard w.bind("persistState", jsPersistState)
  discard w.bind("saveSettings", jsSaveSettings)
  discard w.bind("menuOpen", jsMenuOpen)
  discard w.bind("menuNew", jsMenuNew)
  discard w.bind("openPath", jsOpenPath)
  discard w.bind("openExternal", jsOpenExternal)
  discard w.bind("menuSave", jsMenuSave)
  discard w.bind("menuSaveAs", jsMenuSaveAs)
  discard w.bind("requestExit", jsRequestExit)
  discard w.bind("logMsg", jsLog)
  discard w.bind("historyReset", jsHistoryReset)
  discard w.bind("historyRecord", jsHistoryRecord)
  discard w.bind("historyUndo", jsHistoryUndo)
  discard w.bind("historyRedo", jsHistoryRedo)

proc setWindowIcon(w: Webview) =
  ## Set the window/taskbar icon from the embedded PNG. Linux only; on Windows
  ## the icon comes from the .ico compiled into the executable as a resource.
  ## Wrapped defensively so a failure never stops startup.
  when defined(linux):
    if iconPng.len == 0: return
    try:
      let win = getWindow(w)
      if win == nil: return
      let data = iconPng.cstring
      let dataLen = iconPng.len.cint
      {.emit: """
      GError* _err = NULL;
      GdkPixbufLoader* _ld = gdk_pixbuf_loader_new();
      if (_ld) {
        if (gdk_pixbuf_loader_write(_ld, (const guchar*)`data`, (gsize)`dataLen`, &_err)
            && gdk_pixbuf_loader_close(_ld, &_err)) {
          GdkPixbuf* _pb = gdk_pixbuf_loader_get_pixbuf(_ld);
          if (_pb) gtk_window_set_icon((GtkWindow*)`win`, _pb);
        }
        if (_err) g_error_free(_err);
        g_object_unref(_ld);
      }
      """.}
    except CatchableError:
      discard

proc setupWindow(debug: bool): Webview =
  let w = newWebview(debug = debug)
  if w == nil:
    logLine("fatal: could not create webview (is WebKitGTK/WebView2 available?)")
    quit(1)
  app.w = w
  w.title = "ZMarkdown"
  setWindowIcon(w)
  let (rw, rh) = computeRestoreSize()
  w.size = (rw, rh)
  w.setSize(MinWidth, MinHeight, WebviewHintMin)
  vlog("window size " & $rw & "x" & $rh & " (min " & $MinWidth & "x" & $MinHeight & ")")

  # Track live geometry (Linux) and restore the maximized state if it was saved.
  let win = getWindow(w)
  when defined(linux):
    if win != nil: zmTrackWindow(win)
  when defined(linux) or defined(windows):
    if app.ui.maximized and win != nil:
      zmMaximizeWindow(win)
      vlog("restoring maximized window")

  bindAll(w)
  setDialogLogger(proc (m: string) {.gcsafe.} = logLine(m))
  w.html = buildPage()
  w

# ---- Self-test -------------------------------------------------------------

proc runSelfTest(): int =
  ## Boot the real webview, drive a render and view switching through the bridge,
  ## read the preview back, and assert on it. Prints a clear PASS/FAIL line and
  ## returns 0/1. Meant to run under xvfb on Linux/CI.
  logLine("self-test: starting")
  verbose = true
  app.ui = defaultState()

  # A temp file the driver opens through openPath(), exercising the same code the
  # drag-and-drop uses (the drag gesture itself cannot be simulated headlessly).
  let dropPath = getTempDir() / "zmarkdown-selftest-drop.md"
  try: writeFile(dropPath, "# Dropped\n\ndropped body\n")
  except CatchableError: discard

  let w = setupWindow(debug = false)

  var failures: seq[string]

  # A binding JS calls once the UI is ready, handing the test results back to Nim.
  proc jsReport(id: string; req: JsonNode): string =
    try:
      let r = req[0]
      let html = r{"html"}.getStr()
      let viewAfter = r{"view"}.getStr()
      let editBold = r{"editBold"}.getStr()
      let undoText = r{"undoText"}.getStr()
      let dropText = r{"dropText"}.getStr()
      let dropHandler = r{"dropHandler"}.getStr()
      logLine("self-test: preview length " & $html.len)
      if not html.contains("<h1"): failures.add("missing <h1>")
      if not html.contains("<strong>"): failures.add("missing <strong>")
      if not html.contains("<u>"): failures.add("missing <u>")
      if not html.contains("<code>"): failures.add("missing <code>")
      # Regression guard for the json_escape UTF-8 fix: a bound call's result
      # carrying non-ASCII must survive the bridge intact.
      if not html.contains("—"): failures.add("em dash lost in preview (UTF-8 bridge)")
      if viewAfter != "preview": failures.add("view switch failed (got '" & viewAfter & "')")
      if not editBold.contains("**sel**"): failures.add("bold transform failed (got '" & editBold & "')")
      if undoText != "start": failures.add("undo did not restore prior text (got '" & undoText & "')")
      if not dropText.contains("dropped body"): failures.add("openPath did not return file content (got '" & dropText & "')")
      # The drop handler should have opened the temp file into the editor.
      if dropHandler.startsWith("ERR:"):
        logLine("self-test: note: synthetic drop unsupported here (" & dropHandler & ")")
      elif not dropHandler.contains("dropped body"):
        failures.add("drop handler did not open the dropped file (got '" & dropHandler & "')")
    except CatchableError as e:
      failures.add("report parse error: " & e.msg)
    app.exiting = true
    wdDone.store(true)
    discard app.w.terminate()
    "true"
  discard w.bind("selfTestReport", jsReport)

  # Drive the UI once it is ready: set a known sample, render, switch to preview,
  # exercise a bold transform, then report everything back in one call.
  const driver = """
  (function () {
    window.onerror = function (m, s, l, c, e) {
      try { window.logMsg('JS error: ' + m + ' @' + l + ':' + c); } catch (x) {}
      return false;
    };
    function waitReady(cb) {
      if (window.__zm && window.__zm.ready) return cb();
      setTimeout(function () { waitReady(cb); }, 25);
    }
    waitReady(async function () {
      try {
        var sample = "# Heading — dash\n\nThis is **bold** and <u>under</u> and `code`.\n\n- a\n- b\n";
        await window.__zm.setEditor(sample);
        var html = window.__zm.getPreviewHtml();
        var view = window.__zm.setView("preview");
        var ed = await window.__zm.runEdit("bold", "sel", 0, 3);
        await window.historyReset("start");
        await window.historyRecord("start EDITED", 0, 0);
        var u = await window.historyUndo();
        var undoText = (u && u.ok) ? u.text : "";
        var op = await window.openPath(false, "", window.__zmDropPath);
        var dropText = (op && op.opened) ? op.text : "";
        // Exercise the real drop handler with a synthetic file drop.
        var dropHandler = "";
        try {
          window.__zm.markClean();
          document.getElementById("editor").value = "BEFORE_DROP";
          var dt = new DataTransfer();
          dt.setData("text/uri-list", "file://" + encodeURI(window.__zmDropPath));
          document.dispatchEvent(new DragEvent("drop", { bubbles: true, cancelable: true, dataTransfer: dt }));
          await new Promise(function (r) { setTimeout(r, 600); });
          dropHandler = document.getElementById("editor").value;
        } catch (e) { dropHandler = "ERR:" + e; }
        await window.selfTestReport({ html: html, view: view, editBold: ed.text, undoText: undoText, dropText: dropText, dropHandler: dropHandler });
      } catch (err) {
        try { window.logMsg('driver error: ' + err); } catch (x) {}
        await window.selfTestReport({ html: '', view: '', editBold: '', undoText: '', dropText: '', dropHandler: '' });
      }
    });
  })();
  """
  let dropInit = "window.__zmDropPath = " & $(%dropPath) & ";"
  discard w.init(dropInit.cstring)
  discard w.init(driver)

  # Safety valve: if the UI never reports, terminate after a timeout so CI does
  # not hang. The watchdog is gcsafe: it only touches an atomic flag and the
  # webview pointer, never GC'd state.
  wdWebview = w
  wdDone.store(false)
  createThread(watchdogThread, watchdogProc)

  discard w.run()
  discard w.destroy()

  # If the loop ended without the UI ever reporting, the watchdog fired.
  if not wdDone.load():
    failures.add("timed out waiting for UI report")

  if failures.len == 0:
    logLine("self-test: PASS")
    stdout.writeLine("SELF-TEST PASS")
    0
  else:
    for f in failures: logLine("self-test: FAIL - " & f)
    stdout.writeLine("SELF-TEST FAIL: " & failures.join("; "))
    1

# ---- Main ------------------------------------------------------------------

proc printVersion() =
  stdout.writeLine("ZMarkdown 0.1.0")

proc printHelp() =
  stdout.writeLine("""ZMarkdown - a small markdown editor and viewer

Usage: zmarkdown [options]

Options:
  --self-test    Run the headless end-to-end self-test and exit 0/1.
  --verbose      Log more detail to stderr.
  --version      Print the version and exit.
  --help         Show this help and exit.""")

proc main() =
  var wantSelfTest = false
  for i in 1 .. paramCount():
    case paramStr(i)
    of "--self-test": wantSelfTest = true
    of "--verbose", "-v": verbose = true
    of "--version": printVersion(); return
    of "--help", "-h": printHelp(); return
    else:
      when defined(debug): verbose = true
      logLine("ignoring unknown argument: " & paramStr(i))

  when defined(debug): verbose = true

  logLine("ZMarkdown 0.1.0 starting")

  if wantSelfTest:
    quit(runSelfTest())

  # Normal launch: fresh empty document, restored UI state (never the old file).
  app.ui = loadState()
  vlog("state loaded: view=" & $app.ui.view & " ratio=" & $app.ui.splitRatio)
  let debug = defined(debug)
  let w = setupWindow(debug = debug)
  discard w.run()
  if not app.exiting:
    # Window closed via the window manager rather than the Exit menu; still
    # persist state so the size/view are remembered.
    persistNow()
  discard w.destroy()
  logLine("stopped")

when isMainModule:
  main()
