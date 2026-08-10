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

const AppVersion = "1.3.0"

import webview

import core/editing
import core/markdown as md
import core/state
import core/files
import core/dialogs
import core/history as histmod
import core/search as srch
import core/images as imgs

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
    diskStamp: FileStamp   ## how that file looked when we last read or wrote it,
                           ## so a change made behind our back can be noticed
    ui: UiState            ## restored/persisted UI state
    startupFile: string    ## file to open on launch (from the command line), "" if none
    exiting: bool

var app: App

# Local images the preview may ask for, by the token the rendered HTML carries.
var imageReg = initImageRegistry()

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

proc setCurrentFile(path: string) =
  ## Point the app at a file (or, with "", at nothing) and record how that file
  ## looks right now. Every later comparison against disk is against this stamp,
  ## so it has to be taken everywhere the open document changes.
  app.currentPath = path
  app.diskStamp = fileStamp(path)

proc diskMovedOn(): bool =
  ## Has the open file been changed by something other than us since we last
  ## read or wrote it?
  app.currentPath.len > 0 and changed(app.diskStamp, fileStamp(app.currentPath))

# ---- JSON helpers for the bridge -------------------------------------------

proc editResultJson(r: EditResult): JsonNode =
  %*{"text": r.text, "selStart": r.selStart, "selEnd": r.selEnd}

# ---- Bound procs (callable from JS) ----------------------------------------
#
# Each returns a JSON string (webview delivers it to JS as a resolved Promise).
# JS awaits them. Errors are caught here so a bad call cannot crash the loop.

proc docBaseDir(): string =
  ## What a relative image path in the document is relative to: the directory of
  ## the open file, or the working directory for a document that has none.
  if app.currentPath.len > 0:
    app.currentPath.parentDir()
  else:
    try: getCurrentDir()
    except CatchableError: ""

proc jsRender(id: string; req: JsonNode): string =
  ## render(src) -> HTML fragment. Never raises; degrades to an inline error.
  let src = if req.len > 0 and req[0].kind == JString: req[0].getStr() else: ""
  let outcome = md.renderOutcome(src)
  if not outcome.ok:
    vlog("render error: " & outcome.error)
  var html = outcome.html
  # The page has no base URL and cannot read the disk, so a local image is
  # replaced by a token it redeems through imageData below. Remote and inline
  # sources are left for the page to load itself.
  try:
    html = rewriteImages(html, docBaseDir(), imageReg)
  except CatchableError as e:
    vlog("image resolution failed: " & e.msg)
  result = $ %* html

proc jsImageData(id: string; req: JsonNode): string =
  ## imageData(token) -> {uri, error}. The bytes of one local image, as a data:
  ## URI. A token whose file has gone away since the render was made gets the
  ## same placeholder a missing image gets, so the preview always shows
  ## something rather than an empty gap - and an empty token asks for that
  ## placeholder deliberately, which is how the page dresses up an image it
  ## failed to fetch by itself.
  var r: tuple[uri, error: string] = ("", "Image could not be read")
  try:
    if req.len > 0 and req[0].kind == JString:
      r = imageDataUri(imageReg, req[0].getStr())
  except CatchableError as e:
    vlog("imageData failed: " & e.msg)
    r = ("", "Image could not be read")
  if r.uri.len == 0:
    vlog("imageData: " & r.error)
    return $ %*{"uri": missingImageUri, "error": r.error}
  $ %*{"uri": r.uri, "error": ""}

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

# ---- Find and replace ------------------------------------------------------
#
# The matching itself lives in core/search, which speaks UTF-16 code unit
# offsets so the results can be handed straight to the textarea's selection.

proc searchOpts(req: JsonNode; caseIdx, wordIdx: int): SearchOpts =
  ## Read the two option toggles out of a bridge call, defaulting to off.
  proc flag(i: int): bool =
    req.len > i and req[i].kind == JBool and req[i].getBool()
  SearchOpts(matchCase: flag(caseIdx), wholeWord: flag(wordIdx))

proc jsSearchFind(id: string; req: JsonNode): string =
  ## searchFind(text, needle, matchCase, wholeWord)
  ##   -> {offsets, total, capped}
  ##
  ## `offsets` is a flat array of start/stop pairs (s0, e0, s1, e1, ...) rather
  ## than an array of objects: this crosses the bridge on every keystroke and
  ## the flat form is a fraction of the JSON.
  # Indexing a short argument list would raise IndexDefect, which `except
  # CatchableError` does not catch, so arity is checked first (as every other
  # bound proc here does).
  if req.len < 2:
    return $ %*{"offsets": newJArray(), "total": 0, "capped": false}
  try:
    let
      text = req[0].getStr()
      needle = req[1].getStr()
      r = srch.find(text, needle, searchOpts(req, 2, 3))
    var offsets = newJArray()
    for m in r.matches:
      offsets.add(%m.start)
      offsets.add(%m.stop)
    result = $ %*{"offsets": offsets, "total": r.total, "capped": r.capped}
  except CatchableError as e:
    vlog("searchFind failed: " & e.msg)
    result = $ %*{"offsets": newJArray(), "total": 0, "capped": false}

proc replaceResultJson(r: ReplaceResult): JsonNode =
  %*{"text": r.text, "selStart": r.selStart, "selEnd": r.selEnd,
     "replaced": r.replaced}

proc jsSearchReplace(id: string; req: JsonNode): string =
  ## searchReplace(text, needle, replacement, matchCase, wholeWord,
  ##               selStart, selEnd) -> {text, selStart, selEnd, replaced}
  ##
  ## Replaces only when the selection sits exactly on a match, so pressing
  ## Replace without having landed on one is a no-op rather than a surprise.
  if req.len < 7:
    return $ %*{"text": (if req.len > 0: req[0].getStr() else: ""),
                "selStart": 0, "selEnd": 0, "replaced": 0}
  try:
    let
      text = req[0].getStr()
      needle = req[1].getStr()
      repl = req[2].getStr()
      a = req[5].getInt()
      b = req[6].getInt()
    result = $ replaceResultJson(
      replaceOne(text, needle, repl, searchOpts(req, 3, 4), a, b))
  except CatchableError as e:
    vlog("searchReplace failed: " & e.msg)
    # Hand the input back untouched so the editor is never corrupted.
    result = $ %*{"text": (if req.len > 0: req[0].getStr() else: ""),
                  "selStart": 0, "selEnd": 0, "replaced": 0}

proc jsSearchReplaceAll(id: string; req: JsonNode): string =
  ## searchReplaceAll(text, needle, replacement, matchCase, wholeWord)
  ##   -> {text, selStart, selEnd, replaced}. One edit, so one undo step.
  if req.len < 3:
    return $ %*{"text": (if req.len > 0: req[0].getStr() else: ""),
                "selStart": 0, "selEnd": 0, "replaced": 0}
  try:
    let
      text = req[0].getStr()
      needle = req[1].getStr()
      repl = req[2].getStr()
    result = $ replaceResultJson(
      replaceAll(text, needle, repl, searchOpts(req, 3, 4)))
  except CatchableError as e:
    vlog("searchReplaceAll failed: " & e.msg)
    result = $ %*{"text": (if req.len > 0: req[0].getStr() else: ""),
                  "selStart": 0, "selEnd": 0, "replaced": 0}

proc jsLoadInitialState(id: string; req: JsonNode): string =
  ## loadInitialState() -> the restored UI state (view and split ratio matter to JS).
  result = $ app.ui.toJson()

proc jsStartupFile(id: string; req: JsonNode): string =
  ## startupFile() -> {path, text, title, created}. The file passed on the
  ## command line (e.g. opened from the file manager), read and ready for the
  ## editor, or `{path: ""}` when there was none.
  ##
  ## A path that does not exist yet is not an error: the editor opens empty
  ## under that name and the file is written on the first save, so
  ## `zmarkdown notes.md` is a way to start a new document as well as to open
  ## one. The startup file is cleared after this first read so it cannot reopen
  ## later in the session.
  let path = app.startupFile
  app.startupFile = ""
  if path.len == 0:
    return $ %*{"path": ""}
  if dirExists(path):
    logLine("open failed (" & path & "): it is a directory")
    errorDialog("Open failed", "That path is a directory, not a file:\n" & path)
    return $ %*{"path": ""}
  if not fileExists(path):
    setCurrentFile(path)
    logLine("new file " & path & " (written on the first save)")
    return $ %*{"path": path, "text": "", "title": docName(), "created": true}
  let r = readTextFile(path)
  if not r.ok:
    logLine("open failed (" & path & "): " & r.error)
    errorDialog("Open failed", r.error)
    return $ %*{"path": ""}
  setCurrentFile(path)
  logLine("opened " & path)
  $ %*{"path": path, "text": r.value, "title": docName(), "created": false}

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
  setCurrentFile(path)
  logLine("opened " & path)
  (true, r.value, docName())

proc doSaveTo(path, text: string): bool =
  # The directory may not exist yet: a path named on the command line can point
  # anywhere (`zmarkdown notes/today/plan.md`), and writeTextFile creates it.
  let dir = path.parentDir()
  let dirIsNew = dir.len > 0 and not dirExists(dir)
  let r = writeTextFile(path, text)
  if not r.ok:
    logLine("save failed: " & r.error)
    errorDialog("Save failed", r.error)
    return false
  if dirIsNew:
    logLine("created directory " & dir)
  setCurrentFile(path)
  logLine("saved " & path)
  true

proc doSaveAs(text: string): tuple[saved: bool, title: string] =
  let suggested = if app.currentPath.len > 0: extractFilename(app.currentPath) else: "untitled.md"
  let path = saveFileDialog("Save As", suggested)
  if path.len == 0: return (false, docName())
  (doSaveTo(path, text), docName())

proc doSave(text: string): tuple[saved: bool, title: string] =
  ## Save to the current path, or fall through to Save As if there is none.
  if app.currentPath.len == 0:
    let path = saveFileDialog("Save As", "untitled.md")
    if path.len == 0: return (false, docName())
    return (doSaveTo(path, text), docName())
  # Somebody else may have written to this file since we last read or wrote it.
  # Overwriting it without a word would throw their work away silently, so ask.
  if diskMovedOn():
    let gone = not fileStamp(app.currentPath).exists
    logLine("save: " & app.currentPath &
      (if gone: " is no longer on disk" else: " changed on disk since it was opened"))
    case diskConflictPrompt(docName(), gone)
    of ccOverwrite:
      logLine("save: overwriting the changed file at the user's request")
    of ccSaveAs:
      return doSaveAs(text)
    of ccCancel:
      logLine("save cancelled")
      return (false, docName())
  (doSaveTo(app.currentPath, text), docName())

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
  setCurrentFile("")
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
  setCurrentFile(path)
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
  setCurrentFile("")
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

proc jsReloadFile(id: string; req: JsonNode): string =
  ## reloadFile(dirty) -> {ok, text, title}. F5: read the open file from disk
  ## again, so a document edited elsewhere can be picked up without reopening
  ## it. Unsaved changes are discarded only after asking.
  let dirty = req.len > 0 and req[0].kind == JBool and req[0].getBool()
  if app.currentPath.len == 0:
    infoDialog("Nothing to reload",
      "This document has never been saved, so there is no file on disk to " &
      "reload it from.")
    return $ %*{"ok": false}
  if not fileExists(app.currentPath):
    let hadFile = app.diskStamp.exists
    logLine("reload: " & app.currentPath & " is not on disk")
    infoDialog("Nothing to reload",
      (if hadFile: "This file is no longer on disk:\n"
       else: "This document has not been written to disk yet:\n") &
      app.currentPath)
    return $ %*{"ok": false}
  if dirty and not confirmPrompt("Reload from disk",
      "This document has unsaved changes, and reloading will throw them away.\n\n" &
      "Reload " & docName() & " from disk?"):
    logLine("reload cancelled (unsaved changes kept)")
    return $ %*{"ok": false}
  let r = readTextFile(app.currentPath)
  if not r.ok:
    logLine("reload failed (" & app.currentPath & "): " & r.error)
    errorDialog("Reload failed", r.error)
    return $ %*{"ok": false}
  app.diskStamp = fileStamp(app.currentPath)
  logLine("reloaded " & app.currentPath)
  $ %*{"ok": true, "text": r.value, "title": docName()}

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
  discard w.bind("imageData", jsImageData)
  discard w.bind("applyEdit", jsApplyEdit)
  discard w.bind("searchFind", jsSearchFind)
  discard w.bind("searchReplace", jsSearchReplace)
  discard w.bind("searchReplaceAll", jsSearchReplaceAll)
  discard w.bind("loadInitialState", jsLoadInitialState)
  discard w.bind("startupFile", jsStartupFile)
  discard w.bind("persistState", jsPersistState)
  discard w.bind("saveSettings", jsSaveSettings)
  discard w.bind("menuOpen", jsMenuOpen)
  discard w.bind("menuNew", jsMenuNew)
  discard w.bind("openPath", jsOpenPath)
  discard w.bind("loadDropped", jsLoadDropped)
  discard w.bind("openExternal", jsOpenExternal)
  discard w.bind("reloadFile", jsReloadFile)
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

# ---- Scripted dialog answers (self-test only) -------------------------------
#
# The headless self-test has nobody to click a dialog's buttons, and the flows
# behind them - reloading over unsaved changes, saving onto a file that changed
# underneath - are worth testing through rather than around. These are plain
# integers in fixed arrays so the hook the dialogs call can stay gcsafe;
# nothing but runSelfTest ever fills them in.

const MaxScriptedAnswers = 16

var
  scriptedReplies: array[MaxScriptedAnswers, cint]  ## answers, in the order asked
  scriptedAsked: array[MaxScriptedAnswers, cint]    ## which prompt each answered
  scriptedCount = 0
  scriptedUsed = 0

proc scriptedDialogAnswer(kind: string): int {.gcsafe.} =
  ## Hand back the next scripted answer, recording which prompt asked for it so
  ## the test can assert that the expected questions were the ones put.
  if scriptedUsed >= scriptedCount:
    return -1  # nothing scripted: a real run would ask a person
  scriptedAsked[scriptedUsed] =
    case kind
    of "unsaved": 1.cint
    of "confirm": 2.cint
    of "conflict": 3.cint
    else: 0.cint
  result = scriptedReplies[scriptedUsed].int
  scriptedUsed += 1

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

  # A real picture beside the "document", so the preview's image handling is
  # driven end to end: the embedded app icon is a PNG, so it doubles as one.
  let imgName = "zmarkdown-selftest-image.png"
  let imgPath = getTempDir() / imgName
  try: writeFile(imgPath, iconPng)
  except CatchableError: discard

  # Launching with a file that does not exist must boot an empty document under
  # that name and create the file on the first save. The startup file also gives
  # the document a directory, which is what relative image paths resolve against.
  let newPath = getTempDir() / "zmarkdown-selftest-new.md"
  try: removeFile(newPath)
  except CatchableError: discard
  app.startupFile = newPath

  # Answers for the prompts the driver is about to provoke, in the order it
  # provokes them: refuse the first reload over unsaved changes, allow the
  # second, cancel the first save onto a file that changed underneath, and
  # overwrite on the second.
  scriptedReplies[0] = 0  # confirm: no, keep my unsaved changes
  scriptedReplies[1] = 1  # confirm: yes, reload from disk
  scriptedReplies[2] = 0  # conflict: cancel the save
  scriptedReplies[3] = 1  # conflict: overwrite
  scriptedCount = 4
  scriptedUsed = 0
  setDialogAnswerHook(scriptedDialogAnswer)

  let w = setupWindow(debug = false)

  var failures: seq[string]

  proc jsSelfTestDisk(id: string; req: JsonNode): string =
    ## selfTestDisk(text) -> {content}. Self-test only: write the open file
    ## behind the app's back the way another program would (when `text` is not
    ## empty), and report what is on disk now either way.
    try:
      if req.len > 0 and req[0].kind == JString and req[0].getStr().len > 0:
        writeFile(newPath, req[0].getStr())
    except CatchableError as e:
      vlog("selfTestDisk write failed: " & e.msg)
    var content = ""
    try: content = readFile(newPath)
    except CatchableError: discard
    $ %*{"content": content}
  discard w.bind("selfTestDisk", jsSelfTestDisk)

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
      # Images: a real file beside the document, a name that is not there, and a
      # remote source the app has no business rewriting.
      let img = r{"img"}
      if img == nil or img.kind != JObject or img{"error"}.getStr().len > 0:
        failures.add("image self-test did not report" &
          (if img != nil and img{"error"}.getStr().len > 0: ": " & img{"error"}.getStr() else: ""))
      else:
        # What Nim handed the page: a token for the local file, a flagged
        # placeholder for the one that is not there, the remote source verbatim.
        let rendered = img{"html"}.getStr()
        if not rendered.contains("data-zm-img=\""):
          failures.add("local image was not given a token")
        if not rendered.contains("data-zm-missing=\"Image not found"):
          failures.add("missing image was not flagged in the rendered HTML")
        if not rendered.contains("https://example.invalid/x.png"):
          failures.add("remote image source did not survive rewriting")
        let list = img{"list"}
        if list == nil or list.kind != JArray or list.len != 3:
          failures.add("image self-test: expected 3 images, got " &
            $(if list == nil or list.kind != JArray: 0 else: list.len))
        else:
          let local = list[0]
          if not local{"src"}.getStr().startsWith("data:image/png;base64,"):
            failures.add("local image was not inlined (src '" & local{"src"}.getStr() & "')")
          if not local{"ok"}.getBool():
            failures.add("local image did not load")
          if local{"missing"}.getStr().len > 0:
            failures.add("local image reported as missing: " & local{"missing"}.getStr())
          let gone = list[1]
          if not gone{"missing"}.getStr().startsWith("Image not found"):
            failures.add("missing image was not flagged (got '" & gone{"missing"}.getStr() & "')")
          if not gone{"src"}.getStr().startsWith("data:image/svg+xml;base64,"):
            failures.add("missing image got no placeholder (src '" & gone{"src"}.getStr() & "')")
          # The remote one is left to the page, which here has no network to
          # fetch it with; that it was passed through is asserted on the
          # rendered HTML above, where a failed load cannot have rewritten it.
      # Launched with a path that has no file: empty document, right title, and
      # the first save creates it.
      let st = r{"startup"}
      if st == nil or st.kind != JObject:
        failures.add("startup-file self-test did not report")
      else:
        if st{"error"}.getStr().len > 0:
          failures.add("startup-file driver error: " & st{"error"}.getStr())
        if st{"text"}.getStr().len != 0:
          failures.add("launching with a nonexistent file did not start empty (got '" &
            st{"text"}.getStr() & "')")
        if st{"title"}.getStr() != extractFilename(newPath):
          failures.add("startup title: expected '" & extractFilename(newPath) &
            "', got '" & st{"title"}.getStr() & "'")
        if not st{"saved"}.getBool():
          failures.add("saving the new document reported failure")
        if not fileExists(newPath):
          failures.add("the first save did not create " & newPath)
        if st{"written"}.getStr() != "# Created on save\n":
          failures.add("the created file held '" & st{"written"}.getStr() & "'")
      # Reloading from disk, and saving onto a file changed underneath us.
      let disk = r{"disk"}
      if disk == nil or disk.kind != JObject or disk{"error"}.getStr().len > 0:
        failures.add("disk self-test did not report" &
          (if disk != nil and disk{"error"}.getStr().len > 0:
             ": " & disk{"error"}.getStr() else: ""))
      else:
        if disk{"keptEdit"}.getStr() != "# My unsaved edit\n":
          failures.add("F5 threw away unsaved changes after the prompt was declined (editor holds '" &
            disk{"keptEdit"}.getStr() & "')")
        if disk{"reloaded"}.getStr() != "# Changed on disk by someone else\n":
          failures.add("F5 did not reload the file from disk (editor holds '" &
            disk{"reloaded"}.getStr() & "')")
        if not disk{"saveStopped"}.getBool():
          failures.add("saving onto a file changed on disk was not stopped")
        if disk{"afterCancel"}.getStr() != "# Changed yet again, by someone else\n":
          failures.add("a cancelled save wrote the file anyway (it holds '" &
            disk{"afterCancel"}.getStr() & "')")
        if not disk{"saveOverwrote"}.getBool():
          failures.add("overwriting the changed file was refused")
        if disk{"afterOverwrite"}.getStr() != "# Mine\n":
          failures.add("the overwrite did not write our text (file holds '" &
            disk{"afterOverwrite"}.getStr() & "')")
      # ...and the questions asked were the ones expected, in that order.
      if scriptedUsed != 4:
        failures.add("expected 4 prompts, " & $scriptedUsed & " were asked")
      elif scriptedAsked[0] != 2 or scriptedAsked[1] != 2 or
           scriptedAsked[2] != 3 or scriptedAsked[3] != 3:
        failures.add("the prompts asked were not reload, reload, conflict, conflict")
      # Find and replace, driven through the real bar.
      let f = r{"find"}
      if f == nil or f.kind != JObject:
        failures.add("find self-test did not report")
      else:
        proc want(key, expect: string) =
          let got = f{key}.getStr()
          if got != expect:
            failures.add("find " & key & ": expected '" & expect & "', got '" & got & "'")
        proc wantInt(key: string, expect: int) =
          let got = f{key}.getInt()
          if got != expect:
            failures.add("find " & key & ": expected " & $expect & ", got " & $got)
        if f{"error"}.getStr().len > 0:
          failures.add("find driver error: " & f{"error"}.getStr())
        # Document: "a **cat** and a Cat and cats here"
        want("count", "1 / 3")        # three matches, sitting on the first
        want("next", "2 / 3")         # Enter advances
        want("wrap", "1 / 3")         # and wraps past the last one
        want("selected", "cat")       # the match is selected in the editor
        wantInt("editorMarks", 3)     # all three painted in the highlight layer
        wantInt("caseTotal", 1)       # Match case: only the capitalized "Cat"
        wantInt("wordTotal", 2)       # Whole word: not the "cat" inside "cats"
        if not f{"caretKept"}.getBool():
          failures.add("typing with the find bar open moved the caret onto a match")
        want("replaced", "a **dog** and a Cat and cats here")
        want("replacedAll", "a **dog** and a dog and dogs here")
        # Replace All is one undo step: undoing lands on the pre-Replace-All text.
        want("undone", "a **dog** and a Cat and cats here")
        want("previewCount", "1 / 3") # Preview view searches the rendered text
        wantInt("previewMarks", 3)
        # The emphasis is stripped in the rendered text, so marking "cat" there
        # only works if the rendered offsets (not the source's) were used.
        want("previewMarkText", "cat")
        if not f{"closed"}.getBool():
          failures.add("closing the find bar left highlights behind")
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
        // What launching with a file that does not exist yet left behind: an
        // empty document titled after the file. Read before anything types.
        var startup = { text: window.__zm.getEditorValue(), title: window.__zm.getTitle() };
        var sample = "# Heading — dash\n\nThis is **bold** and <u>under</u> and `code`.\n\n- a\n- b\n";
        await window.__zm.setEditor(sample);
        var html = window.__zm.getPreviewHtml();
        var view = window.__zm.setView("preview");
        var ed = await window.__zm.runEdit("bold", "sel", 0, 3);
        await window.historyReset("start");
        await window.historyRecord("start EDITED", 0, 0);
        var u = await window.historyUndo();
        var undoText = (u && u.ok) ? u.text : "";
        // Images, while the document still lives beside the test picture: one
        // real file (relative to the document), one that is not there, and one
        // remote source the app must hand to the page untouched.
        var img = {};
        try {
          await window.__zm.setEditor(
            "![local](" + window.__zmImgRel + ")\n\n" +
            "![gone](zmarkdown-selftest-no-such-image.png)\n\n" +
            "![remote](https://example.invalid/x.png)\n");
          // What Nim rewrote, before the page touched any of it: a source the
          // page loads itself may well fail here (there is no network in CI)
          // and be dressed as a placeholder, which would hide what was sent.
          img.html = window.__zm.getRenderedHtml();
          img.list = await window.__zm.imagesLoaded();
        } catch (e) { img.error = String(e); }
        // Saving the document that was launched under a name with no file is
        // what has to create it.
        try {
          var sv = await window.menuSave("# Created on save\n");
          startup.saved = !!(sv && sv.saved);
          // Read it back now: a later step deliberately rewrites this file.
          startup.written = (await window.selfTestDisk("")).content;
        } catch (e) { startup.error = String(e); }
        // Reloading from disk (F5) and saving onto a file somebody else has
        // changed. Both prompts are answered from the script in Nim: no, then
        // yes for the reload; cancel, then overwrite for the save.
        var disk = {};
        var edEl0 = document.getElementById("editor");
        try {
          await window.selfTestDisk("# Changed on disk by someone else\n");
          edEl0.value = "# My unsaved edit\n";
          edEl0.dispatchEvent(new Event("input", { bubbles: true }));
          await new Promise(function (r) { setTimeout(r, 250); });
          function pressF5() {
            document.dispatchEvent(new KeyboardEvent("keydown",
              { key: "F5", bubbles: true, cancelable: true }));
            return new Promise(function (r) { setTimeout(r, 450); });
          }
          await pressF5();                       // prompt answered "no"
          disk.keptEdit = window.__zm.getEditorValue();
          await pressF5();                       // prompt answered "yes"
          disk.reloaded = window.__zm.getEditorValue();
          // The file changes again, and now we try to save over it.
          await window.selfTestDisk("# Changed yet again, by someone else\n");
          var s1 = await window.menuSave("# Mine\n");
          disk.saveStopped = !(s1 && s1.saved);
          disk.afterCancel = (await window.selfTestDisk("")).content;
          var s2 = await window.menuSave("# Mine\n");
          disk.saveOverwrote = !!(s2 && s2.saved);
          disk.afterOverwrite = (await window.selfTestDisk("")).content;
        } catch (e) { disk.error = String(e); }
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
        // Find and replace, driven through the real bar rather than the procs
        // behind it, so the wiring is covered too.
        var fr = {};
        try {
          var edEl2 = document.getElementById("editor");
          // The emphasis matters: it makes the rendered text shorter than the
          // source, so preview offsets differ from editor offsets and a
          // preview search that wrongly used the source would mark the wrong
          // characters rather than merely the right count of them.
          var fsample = "a **cat** and a Cat and cats here";
          async function seed() {
            await window.__zm.setEditor(fsample);
            edEl2.setSelectionRange(0, 0); // start from the top, deterministically
          }
          await seed();
          window.__zm.setView("split");
          await window.__zm.findOpen(false);
          var st = await window.__zm.findQuery("cat", false, false);
          fr.count = st.count;
          fr.selected = st.selected;
          fr.editorMarks = st.editorMarks;
          fr.next = window.__zm.findNext().count;
          window.__zm.findNext();
          fr.wrap = window.__zm.findNext().count;   // past the last one, back to 1
          fr.caseTotal = (await window.__zm.findQuery("Cat", true, false)).total;
          fr.wordTotal = (await window.__zm.findQuery("cat", false, true)).total;
          // Regression guard: typing with the bar open must leave the caret
          // alone. It used to be dragged onto the current match (and the match
          // left selected), so the next keystroke overwrote it.
          await window.__zm.findQuery("cat", false, false);
          edEl2.value = fsample + "X";
          edEl2.setSelectionRange(edEl2.value.length, edEl2.value.length);
          edEl2.dispatchEvent(new Event("input", { bubbles: true }));
          await new Promise(function (r) { setTimeout(r, 400); }); // past the 90ms debounce
          fr.caretKept = edEl2.selectionStart === edEl2.value.length &&
                         edEl2.selectionEnd === edEl2.value.length;
          await seed();
          await window.__zm.findQuery("cat", false, false);
          fr.replaced = (await window.__zm.findReplaceOne("dog")).text;
          fr.replacedAll = (await window.__zm.findReplaceAll("dog")).text;
          var un = await window.historyUndo();
          fr.undone = (un && un.ok) ? un.text : "";
          await seed();
          window.__zm.setView("preview");
          st = await window.__zm.findQuery("cat", false, false);
          fr.previewCount = st.count;
          fr.previewMarks = st.previewMarks;
          fr.previewMarkText = st.previewMarkText;
          var closed = window.__zm.findClose();
          fr.closed = closed.editorMarks === 0 && closed.previewMarks === 0;
          window.__zm.setView("split");
        } catch (e) { fr.error = String(e); }
        await window.selfTestReport({ html: html, view: view, editBold: ed.text, undoText: undoText, dropText: dropText, dropUri: dropUri, dropFile: dropFile, staleOk: staleOk, find: fr, img: img, startup: startup, disk: disk });
      } catch (err) {
        try { window.logMsg('driver error: ' + err); } catch (x) {}
        await window.selfTestReport({ html: '', view: '', editBold: '', undoText: '', dropText: '', dropUri: '', dropFile: '', staleOk: false, find: { error: 'driver aborted' }, img: { error: 'driver aborted' }, startup: { error: 'driver aborted' }, disk: { error: 'driver aborted' } });
      }
    });
  })();
  """
  let dropInit = "window.__zmDropPath = " & $(%dropPath) & ";" &
                 "window.__zmImgRel = " & $(%imgName) & ";"
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

  for leftover in [imgPath, newPath]:
    try: removeFile(leftover)
    except CatchableError: discard

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
A path that does not exist yet is fine: the editor starts empty under that name
and the file is written the first time you save.

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
