## ZMarkdown: a small desktop markdown editor and viewer.
##
## The window contents (toolbar, editor, preview, divider) are HTML/CSS/JS
## embedded into this binary at compile time. All application logic (text
## transforms, markdown rendering, file IO, dialogs, state) is Nim, reached from
## the page through bound procs. The webview is only the display.

import std/[json, os, times, strutils, base64, options, browsers, uri]
import std/atomics
import std/osproc
import std/streams
import std/strtabs

const AppVersion = "1.0.2"

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

/* Native file-drop handling. WebKitGTK does not hand file drags to JavaScript
   (uri-list/plain/files all come back empty), so intercept the drop on the web
   view widget, where GTK delivers the file URIs, and pass the local path to a
   Nim callback. */
typedef void (*zm_drop_cb)(const char*);
/* A file drag merely passing over the window makes WebKit request the drop data
   during drag-motion, which would load the file before the user actually drops
   it. Only act on a real drop: the drag-drop signal (fired on release) sets this
   flag, and drag-data-received ignores any data delivered without it. */
static int zm_drop_pending = 0;
static gboolean zm_on_drag_drop(GtkWidget* w, GdkDragContext* ctx, gint x, gint y,
                                guint t, gpointer u) {
  (void)w; (void)ctx; (void)x; (void)y; (void)t; (void)u;
  zm_drop_pending = 1;
  return FALSE; /* let the default handler fetch the data (fires drag-data-received) */
}
static void zm_on_drop_data(GtkWidget* w, GdkDragContext* ctx, gint x, gint y,
                            GtkSelectionData* data, guint info, guint t, gpointer cb) {
  (void)x; (void)y; (void)info;
  if (!zm_drop_pending) return; /* data requested during drag-motion, not a drop */
  zm_drop_pending = 0;
  gchar** uris = gtk_selection_data_get_uris(data);
  gboolean ok = FALSE;
  if (uris && uris[0]) {
    gchar* fn = g_filename_from_uri(uris[0], NULL, NULL);
    if (fn) { ((zm_drop_cb)cb)(fn); g_free(fn); ok = TRUE; }
  }
  if (uris) g_strfreev(uris);
  gtk_drag_finish(ctx, ok, FALSE, t);
  g_signal_stop_emission_by_name(w, "drag-data-received");
}
extern "C" void zmSetupDrop(void* window, void* cb) {
  if (!window) return;
  /* The window's child is the WebKitWebView widget (the topmost drop target). */
  GtkWidget* target_widget = gtk_bin_get_child(GTK_BIN(window));
  if (!target_widget) target_widget = GTK_WIDGET(window);
  GtkTargetEntry target;
  target.target = (gchar*)"text/uri-list";
  target.flags = 0;
  target.info = 0;
  gtk_drag_dest_set(target_widget, GTK_DEST_DEFAULT_ALL, &target, 1, GDK_ACTION_COPY);
  g_signal_connect(target_widget, "drag-drop", G_CALLBACK(zm_on_drag_drop), NULL);
  g_signal_connect(target_widget, "drag-data-received", G_CALLBACK(zm_on_drop_data), cb);
}

/* Graphics capability probe. WebKitGTK insists on bringing up GPU-accelerated
   rendering; on displays with no working 3D (typically a VM without guest 3D
   acceleration) those attempts fail slowly in every WebKit subprocess, which
   both delays startup by many seconds and leaves rendering janky. This probe
   answers "does this display have working hardware GL?" so the app can tell
   WebKit to render on the CPU instead.

   It runs inside a dedicated `zmarkdown --probe-gl` subprocess (spawned by
   zmRunProbe below), so a crashing or hanging driver can never take the app
   down: everything is dlopen'd at run time, stderr is silenced to keep libEGL
   warning spew out of the terminal, and an alarm() aborts the process if a
   driver call hangs. The same isolated-helper pattern is what Firefox uses
   (its "glxtest" process). */
#include <dlfcn.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>

/* Minimal EGL/GL constants so no EGL headers are needed at build time. */
#define ZM_EGL_SURFACE_TYPE            0x3033
#define ZM_EGL_PBUFFER_BIT             0x0001
#define ZM_EGL_RENDERABLE_TYPE         0x3040
#define ZM_EGL_OPENGL_ES2_BIT          0x0004
#define ZM_EGL_NONE                    0x3038
#define ZM_EGL_CONTEXT_CLIENT_VERSION  0x3098
#define ZM_EGL_OPENGL_ES_API           0x30A0
#define ZM_EGL_WIDTH                   0x3057
#define ZM_EGL_HEIGHT                  0x3056
#define ZM_GL_RENDERER                 0x1F01

/* Case-insensitive substring test (strcasestr is not portable). */
static int zm_has_ci(const char* hay, const char* needle) {
  size_t nl = strlen(needle);
  for (; *hay; hay++) {
    size_t i = 0;
    while (i < nl && hay[i] &&
           (hay[i] | 32) == (needle[i] | 32)) i++;
    if (i == nl) return 1;
  }
  return 0;
}

/* Try to bring up a real EGL context and identify the renderer.
   Returns 1 = working hardware GL; 0 = no usable/software-only GL.
   Writes a short human-readable reason or renderer name into `out`. */
extern "C" int zmProbeAccelInline(char* out, int cap) {
  #define ZM_SAY(s) do { strncpy(out, (s), (size_t)cap - 1); out[cap - 1] = 0; } while (0)
  ZM_SAY("unknown");

  /* Silence libEGL/Mesa warning spew; the parent only reads our stdout. */
  int devnull = open("/dev/null", O_WRONLY);
  if (devnull >= 0) { dup2(devnull, 2); close(devnull); }
  /* If any driver call hangs, die instead of hanging the probe. The parent
     also enforces its own timeout; this catches the orphan case. */
  alarm(10);

  void* egl = dlopen("libEGL.so.1", RTLD_NOW | RTLD_LOCAL);
  if (!egl) egl = dlopen("libEGL.so", RTLD_NOW | RTLD_LOCAL);
  if (!egl) { ZM_SAY("libEGL not found"); return 0; }

  typedef void* (*zm_get_display_t)(void*);
  typedef unsigned (*zm_initialize_t)(void*, int*, int*);
  typedef unsigned (*zm_bind_api_t)(unsigned);
  typedef unsigned (*zm_choose_config_t)(void*, const int*, void**, int, int*);
  typedef void* (*zm_create_context_t)(void*, void*, void*, const int*);
  typedef void* (*zm_create_pbuffer_t)(void*, void*, const int*);
  typedef unsigned (*zm_make_current_t)(void*, void*, void*, void*);
  typedef void* (*zm_get_proc_t)(const char*);
  typedef const unsigned char* (*zm_glgetstring_t)(unsigned);

  zm_get_display_t   eglGetDisplay   = (zm_get_display_t)dlsym(egl, "eglGetDisplay");
  zm_initialize_t    eglInitialize   = (zm_initialize_t)dlsym(egl, "eglInitialize");
  zm_bind_api_t      eglBindAPI      = (zm_bind_api_t)dlsym(egl, "eglBindAPI");
  zm_choose_config_t eglChooseConfig = (zm_choose_config_t)dlsym(egl, "eglChooseConfig");
  zm_create_context_t eglCreateContext = (zm_create_context_t)dlsym(egl, "eglCreateContext");
  zm_create_pbuffer_t eglCreatePbuffer = (zm_create_pbuffer_t)dlsym(egl, "eglCreatePbufferSurface");
  zm_make_current_t  eglMakeCurrent  = (zm_make_current_t)dlsym(egl, "eglMakeCurrent");
  zm_get_proc_t      eglGetProcAddress = (zm_get_proc_t)dlsym(egl, "eglGetProcAddress");
  if (!eglGetDisplay || !eglInitialize || !eglBindAPI || !eglChooseConfig ||
      !eglCreateContext || !eglMakeCurrent) { ZM_SAY("libEGL incomplete"); return 0; }

  void* dpy = eglGetDisplay((void*)0 /* EGL_DEFAULT_DISPLAY */);
  if (!dpy) { ZM_SAY("no EGL display"); return 0; }
  if (!eglInitialize(dpy, 0, 0)) { ZM_SAY("EGL initialization failed"); return 0; }

  eglBindAPI(ZM_EGL_OPENGL_ES_API);
  const int cfg_attrs[] = { ZM_EGL_SURFACE_TYPE, ZM_EGL_PBUFFER_BIT,
                            ZM_EGL_RENDERABLE_TYPE, ZM_EGL_OPENGL_ES2_BIT,
                            ZM_EGL_NONE };
  void* cfg = 0; int ncfg = 0;
  if (!eglChooseConfig(dpy, cfg_attrs, &cfg, 1, &ncfg) || ncfg < 1) {
    ZM_SAY("no EGL config"); return 0;
  }
  const int ctx_attrs[] = { ZM_EGL_CONTEXT_CLIENT_VERSION, 2, ZM_EGL_NONE };
  void* ctx = eglCreateContext(dpy, cfg, (void*)0, ctx_attrs);
  if (!ctx) { ZM_SAY("EGL context creation failed"); return 0; }

  /* Prefer a surfaceless current (universally supported by Mesa); fall back to
     a 1x1 pbuffer for drivers that require a surface. */
  if (!eglMakeCurrent(dpy, (void*)0, (void*)0, ctx)) {
    void* surf = 0;
    if (eglCreatePbuffer) {
      const int pb_attrs[] = { ZM_EGL_WIDTH, 1, ZM_EGL_HEIGHT, 1, ZM_EGL_NONE };
      surf = eglCreatePbuffer(dpy, cfg, pb_attrs);
    }
    if (!surf || !eglMakeCurrent(dpy, surf, surf, ctx)) {
      ZM_SAY("EGL make-current failed"); return 0;
    }
  }

  zm_glgetstring_t glGetString =
      eglGetProcAddress ? (zm_glgetstring_t)eglGetProcAddress("glGetString") : 0;
  if (!glGetString) {
    void* gles = dlopen("libGLESv2.so.2", RTLD_NOW | RTLD_LOCAL);
    if (gles) glGetString = (zm_glgetstring_t)dlsym(gles, "glGetString");
  }
  if (!glGetString) { ZM_SAY("working GL (renderer unknown)"); return 1; }

  const char* renderer = (const char*)glGetString(ZM_GL_RENDERER);
  if (!renderer) { ZM_SAY("working GL (renderer unknown)"); return 1; }
  ZM_SAY(renderer);
  /* A context that works but renders on the CPU (Mesa's fallbacks) is worse
     than WebKit's own CPU path: report it as "no usable acceleration". */
  if (zm_has_ci(renderer, "llvmpipe") || zm_has_ci(renderer, "softpipe") ||
      zm_has_ci(renderer, "swrast") || zm_has_ci(renderer, "software") ||
      zm_has_ci(renderer, "Mesa X11"))
    return 0;
  return 1;
  #undef ZM_SAY
}

/* Belt to the env-var braces: also tell this WebKitWebView instance itself to
   never use hardware acceleration (the supported API knob; the env vars are
   documented as unstable across WebKit versions). Runs right after the webview
   is created, before the first page load spawns the web process. WebGL and
   GPU-accelerated 2D canvas are switched off too: a markdown preview needs
   neither, and they are the remaining GPU touchpoints the policy alone does
   not cover. */
#include <webkit2/webkit2.h>
extern "C" void zmForceCpuRendering(void* window) {
  if (!window) return;
  GtkWidget* child = gtk_bin_get_child(GTK_BIN(window));
  if (!child || !WEBKIT_IS_WEB_VIEW(child)) return;
  WebKitSettings* s = webkit_web_view_get_settings(WEBKIT_WEB_VIEW(child));
  if (!s) return;
  webkit_settings_set_hardware_acceleration_policy(
      s, WEBKIT_HARDWARE_ACCELERATION_POLICY_NEVER);
  webkit_settings_set_enable_webgl(s, FALSE);
  /* Property exists only on WebKitGTK 2.46+; probe before setting. */
  if (g_object_class_find_property(G_OBJECT_GET_CLASS(s),
                                   "enable-2d-canvas-acceleration"))
    g_object_set(G_OBJECT(s), "enable-2d-canvas-acceleration", FALSE, NULL);
}

/* WebKitGTK runtime version check, callable before any webview exists. */
extern "C" int zmWebKitAtLeast(int major, int minor) {
  unsigned mj = webkit_get_major_version();
  unsigned mn = webkit_get_minor_version();
  return (mj > (unsigned)major ||
          (mj == (unsigned)major && mn >= (unsigned)minor)) ? 1 : 0;
}
""".}

  proc zmTrackWindow(win: pointer) {.importc, nodecl.}
  proc zmMaximizeWindow(win: pointer) {.importc, nodecl.}
  proc zmGetWinW(): cint {.importc, nodecl.}
  proc zmGetWinH(): cint {.importc, nodecl.}
  proc zmGetWinMax(): cint {.importc, nodecl.}
  proc zmSetupDrop(widget, cb: pointer) {.importc, nodecl.}
  proc zmProbeAccelInline(outBuf: cstring; cap: cint): cint {.importc, nodecl.}
  proc zmForceCpuRendering(win: pointer) {.importc, nodecl.}
  proc zmWebKitAtLeast(major, minor: cint): cint {.importc, nodecl.}

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
let appStartTime = epochTime()

proc logLine(msg: string) =
  ## Meaningful events go to stderr. Tests assert on these lines, so keep the
  ## wording stable.
  let ts = now().format("HH:mm:ss")
  stderr.writeLine("[zmarkdown " & ts & "] " & msg)
  stderr.flushFile()

proc vlog(msg: string) =
  if verbose: logLine(msg)

# ---- Graphics mode (Linux) --------------------------------------------------
#
# WebKitGTK starts up trying to use GPU-accelerated rendering. On a display
# with no working 3D (typically a VM without guest acceleration) every WebKit
# subprocess slowly fails through the EGL/DRI stack, delaying startup by many
# seconds and leaving rendering laggy. Editing markdown needs none of that, so:
# probe once whether hardware GL actually works (in an isolated helper process,
# `zmarkdown --probe-gl`), cache the verdict in the persisted state, and when
# it is "cpu" tell WebKit to render in software. On machines with working
# acceleration the probe reports "gpu" and nothing about rendering changes.
# Overrides: --no-gpu / --gpu flags, or ZMARKDOWN_NO_GPU=1 in the environment.

when defined(linux):
  const ProbeTimeoutMs = 5000

  var cpuRendering = false          ## the decision for this run
  var probeRefresh: Atomic[int]     ## background re-probe: 0 pending, 1 gpu, 2 cpu
  var probeAbort: Atomic[bool]      ## set at exit so a hung probe never stalls shutdown
  var probeThread: Thread[seq[(string, string)]]
  var probeThreadStarted = false

  proc runProbeMode(): int =
    ## The `--probe-gl` helper process: report GL capability on stdout as one
    ## line, "gpu <renderer>" or "cpu <reason>", and exit. Isolated in its own
    ## process so a crashing or hanging graphics driver cannot harm the app.
    var buf = newString(256)
    let ok = zmProbeAccelInline(buf.cstring, buf.len.cint)
    stdout.writeLine((if ok == 1: "gpu " else: "cpu ") & $buf.cstring)
    stdout.flushFile()
    0

  proc probeOnce(env: StringTableRef = nil): tuple[mode: string, detail: string] =
    ## Run the probe helper and interpret its report. A helper that reports
    ## failure, crashes, or hangs means the GL stack is unusable -> "cpu". Not
    ## being able to launch the helper at all says nothing about GL, so that
    ## returns mode "" (leave the defaults alone).
    ##
    ## `env`: nil inherits the process environment - only safe while the
    ## process is single-threaded (a spawn reading `environ` while another
    ## thread setenvs is undefined behavior). The background re-probe thread
    ## passes an explicit snapshot instead.
    var p: Process
    try:
      # options = {} (not the poStdErrToStdOut default): the helper's stderr
      # must stay out of the verdict pipe, or a stray loader warning printed
      # before the helper silences fd 2 would corrupt the report.
      p = startProcess(getAppFilename(), args = ["--probe-gl"],
                       env = env, options = {})
    except CatchableError as e:
      return ("", "could not run the probe helper: " & e.msg)
    defer: p.close()
    var waited = 0
    while p.running and waited < ProbeTimeoutMs and not probeAbort.load():
      sleep(20)
      waited += 20
    if p.running:
      p.kill()
      discard p.waitForExit()
      if probeAbort.load():
        return ("", "probe abandoned at exit")
      return ("cpu", "GL probe hung; assuming a broken driver")
    discard p.waitForExit()
    # Scan the whole report for the verdict line rather than trusting the
    # first line to be it.
    try:
      for line in p.outputStream.lines:
        if line.startsWith("gpu "): return ("gpu", line[4 .. ^1])
        if line.startsWith("cpu "): return ("cpu", line[4 .. ^1])
    except CatchableError, IOError:
      discard
    ("cpu", "GL probe crashed; assuming a broken driver")

  proc applyCpuRendering() =
    ## Route all WebKit rendering to the CPU. Must run before the webview is
    ## created: the variables are read by WebKitGTK at startup and propagate to
    ## its subprocesses. Different WebKitGTK generations honor different
    ## switches, so set every applicable one; anything the user already set wins.
    var vars = @[
      # 2.40+: never use accelerated compositing. On 2.46+ this also skips the
      # UI process's EGL probing entirely - the slow part on broken GL stacks.
      ("WEBKIT_DISABLE_COMPOSITING_MODE", "1"),
      # 2.42+: no DMA-BUF renderer; on 2.44+ this too skips all UI-process EGL.
      ("WEBKIT_DISABLE_DMABUF_RENDERER", "1"),
    ]
    # 2.46+ (Skia): paint tiles/canvas/filters on the CPU as well. Gated to
    # 2.48+, where a crash with this variable enabled was fixed; on 2.46 the
    # two variables above already force the software path.
    if zmWebKitAtLeast(2, 48) == 1:
      vars.add(("WEBKIT_SKIA_ENABLE_CPU_RENDERING", "1"))
    for (k, v) in vars:
      if getEnv(k).len == 0: putEnv(k, v)

  proc decideRenderMode(forceCpu, forceGpu: bool; cached: string): string =
    ## Pick the rendering for this run: explicit override, then the cached
    ## verdict, then a fresh probe. Returns "cpu", "gpu", or "" when the probe
    ## could not run at all (keep the defaults, cache nothing).
    if forceCpu:
      logLine("graphics: CPU rendering forced")
      return "cpu"
    if forceGpu:
      logLine("graphics: GPU rendering forced")
      return "gpu"
    if cached == "cpu":
      logLine("graphics: CPU rendering (cached verdict; re-checking in background)")
      return "cpu"
    if cached == "gpu":
      vlog("graphics: hardware acceleration (cached verdict; re-checking in background)")
      return "gpu"
    let (mode, detail) = probeOnce()
    case mode
    of "cpu":
      logLine("graphics: no usable 3D acceleration (" & detail & "); rendering on the CPU")
    of "gpu":
      logLine("graphics: hardware acceleration available (" & detail & ")")
    else:
      vlog("graphics: " & detail & "; keeping the default rendering path")
    mode

  proc probeRefreshProc(envSnapshot: seq[(string, string)]) {.thread.} =
    ## Background re-probe. The cached verdict decided this run already; this
    ## keeps the cache honest for the NEXT run (e.g. 3D acceleration enabled or
    ## broken since last time). Result lands in an atomic; persistNow folds it
    ## into the saved state. The environment snapshot was taken on the main
    ## thread; the helper is spawned with it so the spawn never reads `environ`
    ## concurrently with a setenv on the main thread.
    var env = newStringTable(modeCaseSensitive)
    for (k, v) in envSnapshot:
      env[k] = v
    let r = probeOnce(env)
    case r.mode
    of "gpu": probeRefresh.store(1)
    of "cpu": probeRefresh.store(2)
    else: discard

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
    startupFile: string    ## file to open on launch (from the command line), "" if none
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

proc jsStartupFile(id: string; req: JsonNode): string =
  ## startupFile() -> {path}. A file passed on the command line (e.g. opened from
  ## the file manager), or empty. Cleared after the first read so it does not
  ## reopen on any later query.
  result = $ %*{"path": app.startupFile}
  app.startupFile = ""

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

when defined(linux):
  proc foldProbeVerdict() =
    ## Fold a finished background graphics re-probe into the in-memory state,
    ## so the next launch starts with a fresh verdict.
    case probeRefresh.load()
    of 1: app.ui.renderMode = "gpu"
    of 2: app.ui.renderMode = "cpu"
    else: discard

proc persistNow() =
  ## Write current UI state to disk, logging but never failing on error.
  let s = captureWindowState()
  app.ui.width = s.w
  app.ui.height = s.h
  app.ui.maximized = s.maximized != 0
  when defined(linux):
    foldProbeVerdict()
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
    logLine("open failed (" & path & "): " & r.error)
    errorDialog("Open failed", r.error)
    return $ %*{"opened": false}
  app.currentPath = path
  logLine("opened " & path)
  $ %*{"opened": true, "text": r.value, "title": docName()}

proc jsLoadDropped(id: string; req: JsonNode): string =
  ## loadDropped(dirty, currentText, name) -> {ok, title}. Used when a dropped
  ## file gives us its content but no path (JS reads the content and sets the
  ## editor). Guards unsaved changes and starts a fresh unsaved document, so Save
  ## does not overwrite an unrelated file.
  let dirty = req.len > 0 and req[0].kind == JBool and req[0].getBool()
  let curText = if req.len > 1: req[1].getStr() else: ""
  let name = if req.len > 2 and req[2].kind == JString: req[2].getStr() else: ""
  if not guardUnsaved(dirty, curText):
    return $ %*{"ok": false}
  app.currentPath = ""
  logLine("loaded dropped content" & (if name.len > 0: " (" & name & ")" else: ""))
  $ %*{"ok": true, "title": (if name.len > 0: name else: "Untitled")}

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
    let msg = req[0].getStr()
    if msg == "ui ready":
      # Always logged, with startup time: the one number that matters when
      # someone reports "it takes forever to start".
      logLine("ui ready " &
        formatFloat(epochTime() - appStartTime, ffDecimal, 1) & "s after launch")
    else:
      vlog("ui: " & msg)
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
  discard w.bind("startupFile", jsStartupFile)
  discard w.bind("persistState", jsPersistState)
  discard w.bind("saveSettings", jsSaveSettings)
  discard w.bind("menuOpen", jsMenuOpen)
  discard w.bind("menuNew", jsMenuNew)
  discard w.bind("openPath", jsOpenPath)
  discard w.bind("loadDropped", jsLoadDropped)
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

when defined(linux):
  proc onNativeDrop(path: cstring) {.cdecl.} =
    ## Called from the GTK drop handler with a local filesystem path. Hands it to
    ## the JS open flow (unsaved guard + read), reusing the existing bridge.
    try:
      let p = $path
      vlog("native drop: " & p)
      let js = "if(window.__zmDropOpen){window.__zmDropOpen(" & $(%p) & ");}"
      discard app.w.eval(js.cstring)
    except CatchableError as e:
      vlog("native drop failed: " & e.msg)

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
    # In CPU mode, also pin this web view itself to software rendering (the
    # environment variables applied before creation cover the subprocesses).
    if cpuRendering and win != nil:
      zmForceCpuRendering(win)
      vlog("webview hardware acceleration policy: never")
  when defined(linux) or defined(windows):
    if app.ui.maximized and win != nil:
      zmMaximizeWindow(win)
      vlog("restoring maximized window")

  bindAll(w)
  setDialogLogger(proc (m: string) {.gcsafe.} = logLine(m))
  w.html = buildPage()

  # WebKitGTK does not expose file drops to JavaScript, so intercept them on the
  # web view widget at the GTK level and hand the path to the JS open flow.
  when defined(linux):
    let dropWin = getWindow(w)
    if dropWin != nil:
      zmSetupDrop(dropWin, cast[pointer](onNativeDrop))
      vlog("native file-drop handler installed")
    else:
      vlog("native file-drop: no window handle")

  w

# ---- Self-test -------------------------------------------------------------

proc runSelfTest(forceCpu, forceGpu: bool): int =
  ## Boot the real webview, drive a render and view switching through the bridge,
  ## read the preview back, and assert on it. Prints a clear PASS/FAIL line and
  ## returns 0/1. Meant to run under xvfb on Linux/CI.
  logLine("self-test: starting")
  verbose = true
  app.ui = defaultState()

  # The self-test runs wherever CI puts it (usually xvfb, which has no GPU), so
  # make the same rendering decision a real launch would - honoring the same
  # overrides, probing fresh, never touching the user's cached verdict.
  when defined(linux):
    cpuRendering = decideRenderMode(forceCpu, forceGpu, "") == "cpu"
    if cpuRendering:
      applyCpuRendering()

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
      let dropUri = r{"dropUri"}.getStr()
      let dropFile = r{"dropFile"}.getStr()
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
      # Drop handler, uri-list form: opens the temp file through a path.
      if dropUri.startsWith("ERR:"):
        logLine("self-test: note: uri-list drop unsupported here (" & dropUri & ")")
      elif not dropUri.contains("dropped body"):
        failures.add("uri-list drop did not open the file (got '" & dropUri & "')")
      # Drop handler, File form: reads the content directly (the WebKitGTK case).
      if dropFile.startsWith("ERR:"):
        logLine("self-test: note: File drop unsupported here (" & dropFile & ")")
      elif not dropFile.contains("dropped file body"):
        failures.add("File drop did not load the content (got '" & dropFile & "')")
      # Renders are skipped while the preview is hidden and caught up on switch.
      if not r{"staleOk"}.getBool():
        failures.add("hidden-preview render skip/catch-up failed")
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
        // Exercise the real drop handler two ways: a uri-list drop (opens via a
        // path) and a File drop (the WebKitGTK case: read the content directly).
        function synthDrop(dt) {
          window.__zm.markClean();
          document.getElementById("editor").value = "BEFORE_DROP";
          document.dispatchEvent(new DragEvent("drop", { bubbles: true, cancelable: true, dataTransfer: dt }));
        }
        var dropUri = "", dropFile = "";
        try {
          var dtu = new DataTransfer();
          dtu.setData("text/uri-list", "file://" + encodeURI(window.__zmDropPath));
          synthDrop(dtu);
          await new Promise(function (r) { setTimeout(r, 500); });
          dropUri = document.getElementById("editor").value;
        } catch (e) { dropUri = "ERR:" + e; }
        try {
          var dtf = new DataTransfer();
          dtf.items.add(new File(["dropped file body\n"], "dropped.md", { type: "text/markdown" }));
          synthDrop(dtf);
          await new Promise(function (r) { setTimeout(r, 500); });
          dropFile = document.getElementById("editor").value;
        } catch (e) { dropFile = "ERR:" + e; }
        // Typing while the preview is hidden must skip rendering, and switching
        // the preview back in must catch up on the skipped render.
        var staleOk = false;
        try {
          window.__zm.setView("text");
          var edEl = document.getElementById("editor");
          edEl.value = "# StaleCheck";
          edEl.dispatchEvent(new Event("input", { bubbles: true }));
          await new Promise(function (r) { setTimeout(r, 300); }); // past the 120ms debounce
          var skipped = window.__zm.getPreviewHtml().indexOf("StaleCheck") === -1;
          window.__zm.setView("split");
          await new Promise(function (r) { setTimeout(r, 400); });
          var caughtUp = window.__zm.getPreviewHtml().indexOf("StaleCheck") !== -1;
          staleOk = skipped && caughtUp;
        } catch (e) { staleOk = false; }
        await window.selfTestReport({ html: html, view: view, editBold: ed.text, undoText: undoText, dropText: dropText, dropUri: dropUri, dropFile: dropFile, staleOk: staleOk });
      } catch (err) {
        try { window.logMsg('driver error: ' + err); } catch (x) {}
        await window.selfTestReport({ html: '', view: '', editBold: '', undoText: '', dropText: '', dropUri: '', dropFile: '', staleOk: false });
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
  stdout.writeLine("ZMarkdown " & AppVersion)

proc printHelp() =
  stdout.writeLine("""ZMarkdown - a small markdown editor and viewer

Usage: zmarkdown [options] [file]

Open a markdown file by passing its path (this is how the file manager opens it).

Options:""")
  when defined(linux):
    stdout.writeLine("""  --no-gpu       Render without GPU acceleration. Normally detected
                 automatically (e.g. in a VM without 3D acceleration);
                 ZMARKDOWN_NO_GPU=1 in the environment does the same.
  --gpu          Force the default GPU rendering path, skipping the
                 automatic detection.""")
  stdout.writeLine("""  --self-test    Run the headless end-to-end self-test and exit 0/1.
  --verbose      Log more detail to stderr.
  --version      Print the version and exit.
  --help         Show this help and exit.""")

proc main() =
  var wantSelfTest = false
  var wantProbeMode = false
  var forceCpu = false
  var forceGpu = false
  var fileArg = ""
  for i in 1 .. paramCount():
    let arg = paramStr(i)
    case arg
    of "--self-test": wantSelfTest = true
    of "--probe-gl": wantProbeMode = true  # internal: the isolated GL probe helper
    of "--no-gpu": forceCpu = true
    of "--gpu": forceGpu = true
    of "--verbose", "-v": verbose = true
    of "--version": printVersion(); return
    of "--help", "-h": printHelp(); return
    else:
      if not arg.startsWith("-") and fileArg.len == 0:
        fileArg = arg  # a file path (e.g. from the file manager)
      else:
        when defined(debug): verbose = true
        logLine("ignoring unknown argument: " & arg)

  when defined(debug): verbose = true

  if wantProbeMode:
    when defined(linux):
      quit(runProbeMode())
    else:
      quit(0)

  logLine("ZMarkdown " & AppVersion & " starting")
  # The environment override applies only when no explicit flag was given: a
  # command-line --gpu/--no-gpu always beats a lingering exported variable.
  if not forceCpu and not forceGpu and
      getEnv("ZMARKDOWN_NO_GPU").len > 0 and getEnv("ZMARKDOWN_NO_GPU") != "0":
    forceCpu = true
  when not defined(linux):
    if forceCpu or forceGpu:
      logLine("--no-gpu/--gpu have no effect on this platform")

  if wantSelfTest:
    quit(runSelfTest(forceCpu, forceGpu))

  # Normal launch: fresh empty document, restored UI state (never the old file).
  app.ui = loadState()
  vlog("state loaded: view=" & $app.ui.view & " ratio=" & $app.ui.splitRatio)

  # Decide how WebKit should render BEFORE it is created. A fresh probe verdict
  # is cached immediately (the window does not exist yet, so this is a plain
  # state write); a cached verdict is re-checked in the background and folded
  # into the state at exit.
  var wantProbeRefresh = false
  when defined(linux):
    let cachedVerdict = app.ui.renderMode
    let mode = decideRenderMode(forceCpu, forceGpu, cachedVerdict)
    cpuRendering = mode == "cpu"
    if cpuRendering:
      applyCpuRendering()
    if not (forceCpu or forceGpu):
      if cachedVerdict == "":
        if mode in ["gpu", "cpu"]:  # cache only a real verdict
          app.ui.renderMode = mode
          discard saveState(app.ui)
      else:
        # This run used the cache; re-check in the background (started after
        # the window is up, so startup does not compete with it).
        wantProbeRefresh = true

  # A file given on the command line (e.g. opened from the file manager) is loaded
  # on launch. This is separate from the previously open file, which is never
  # reopened on its own.
  if fileArg.len > 0:
    var p = fileArg
    if p.toLowerAscii().startsWith("file://"):
      p = p[7 .. ^1]
      try: p = decodeUrl(p, decodePlus = false)
      except CatchableError: discard
    try: app.startupFile = absolutePath(p)
    except CatchableError: app.startupFile = p
    vlog("startup file: " & app.startupFile)
  let debug = defined(debug)
  let w = setupWindow(debug = debug)
  when defined(linux):
    if wantProbeRefresh:
      # Snapshot the environment here on the main thread (nothing else is
      # running that could mutate it mid-read) and hand the copy to the thread.
      var envSnapshot: seq[(string, string)]
      for k, v in envPairs():
        envSnapshot.add((k, v))
      createThread(probeThread, probeRefreshProc, envSnapshot)
      probeThreadStarted = true
  discard w.run()
  when defined(linux):
    # Collect the background re-probe. The abort flag makes a still-waiting
    # probe give up immediately, so exit is never held up by a hung driver.
    if probeThreadStarted:
      probeAbort.store(true)
      joinThread(probeThread)
      if app.exiting and probeRefresh.load() != 0:
        # Exit came through the menu, which persisted before the re-probe was
        # done; fold the late verdict into the already-written state.
        foldProbeVerdict()
        discard saveState(app.ui)
  if not app.exiting:
    # Window closed via the window manager rather than the Exit menu; still
    # persist state so the size/view are remembered.
    persistNow()
  discard w.destroy()
  logLine("stopped")

when isMainModule:
  main()
