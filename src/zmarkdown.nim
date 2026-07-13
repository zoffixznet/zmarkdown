## ZMarkdown: a small desktop markdown editor and viewer.
##
## The window contents (toolbar, editor, preview, divider) are HTML/CSS/JS
## embedded into this binary at compile time. All application logic (text
## transforms, markdown rendering, file IO, dialogs, state) is Nim, reached from
## the page through bound procs. The webview is only the display.

import std/[json, os, times, strutils, base64]
import std/atomics

import webview

import core/editing
import core/markdown as md
import core/state
import core/files
import core/dialogs

# On Linux we make a couple of direct GTK/GDK calls (live window size and the
# monitor geometry used to clamp the restored size), so pull in the GTK header
# for the emitted C++. On Windows these paths are compiled out.
when defined(linux):
  {.emit: "#include <gtk/gtk.h>".}

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

proc currentWindowSize(): tuple[w, h: int] =
  ## Best-effort read of the live window size so exit persists what the user
  ## actually has now, not the size we restored. Falls back to the stored size.
  result = (app.ui.width, app.ui.height)
  when defined(linux):
    # getWindow returns a GtkWindow*; gtk_window_get_size fills width/height.
    try:
      let win = getWindow(app.w)
      if win != nil:
        var ww, hh: cint
        {.emit: "gtk_window_get_size((GtkWindow*)`win`, &`ww`, &`hh`);".}
        if ww.int >= MinWidth and hh.int >= MinHeight:
          result = (ww.int, hh.int)
    except CatchableError:
      discard

proc persistNow() =
  ## Write current UI state to disk, logging but never failing on error.
  let (w, h) = currentWindowSize()
  app.ui.width = w
  app.ui.height = h
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
  discard w.bind("menuOpen", jsMenuOpen)
  discard w.bind("menuSave", jsMenuSave)
  discard w.bind("menuSaveAs", jsMenuSaveAs)
  discard w.bind("requestExit", jsRequestExit)
  discard w.bind("logMsg", jsLog)

proc setupWindow(debug: bool): Webview =
  let w = newWebview(debug = debug)
  if w == nil:
    logLine("fatal: could not create webview (is WebKitGTK/WebView2 available?)")
    quit(1)
  app.w = w
  w.title = "ZMarkdown"
  let (rw, rh) = computeRestoreSize()
  w.size = (rw, rh)
  w.setSize(MinWidth, MinHeight, WebviewHintMin)
  vlog("window size " & $rw & "x" & $rh & " (min " & $MinWidth & "x" & $MinHeight & ")")
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
  let w = setupWindow(debug = false)

  var failures: seq[string]

  # A binding JS calls once the UI is ready, handing the test results back to Nim.
  proc jsReport(id: string; req: JsonNode): string =
    try:
      let r = req[0]
      let html = r{"html"}.getStr()
      let viewAfter = r{"view"}.getStr()
      let editBold = r{"editBold"}.getStr()
      logLine("self-test: preview length " & $html.len)
      if not html.contains("<h1"): failures.add("missing <h1>")
      if not html.contains("<strong>"): failures.add("missing <strong>")
      if not html.contains("<u>"): failures.add("missing <u>")
      if not html.contains("<code>"): failures.add("missing <code>")
      if viewAfter != "preview": failures.add("view switch failed (got '" & viewAfter & "')")
      if not editBold.contains("**sel**"): failures.add("bold transform failed (got '" & editBold & "')")
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
        var sample = "# Heading\n\nThis is **bold** and <u>under</u> and `code`.\n\n- a\n- b\n";
        await window.__zm.setEditor(sample);
        var html = window.__zm.getPreviewHtml();
        var view = window.__zm.setView("preview");
        var ed = await window.__zm.runEdit("bold", "sel", 0, 3);
        await window.selfTestReport({ html: html, view: view, editBold: ed.text });
      } catch (err) {
        try { window.logMsg('driver error: ' + err); } catch (x) {}
        await window.selfTestReport({ html: '', view: '', editBold: '' });
      }
    });
  })();
  """
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
