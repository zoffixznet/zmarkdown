## ZMarkdown: a small desktop markdown editor and viewer.
##
## The window contents (toolbar, editor, preview, divider) are HTML/CSS/JS
## embedded into this binary at compile time. All application logic (text
## transforms, markdown rendering, file IO, dialogs, state) is Nim, reached from
## the page through bound procs. The webview is only the display.

import std/[json, os, times, strutils, base64, options, browsers, uri, sequtils]
import std/atomics
import std/osproc
import std/streams
import std/strtabs

const AppVersion = "1.6.0"

import webview

import core/editing
import core/markdown as md
import core/state
import core/files
import core/dialogs
import core/history as histmod
import core/search as srch
import core/images as imgs
import core/nav
import core/recent

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

/* The second half of WM_CLASS, which is what a desktop entry's StartupWMClass is
   matched against. GTK derives it from the program name, giving "Zmarkdown",
   which does not match the "ZMarkdown" the desktop entry declares - so the
   launch is never matched to the window that appears. Set before the window is
   created, so it is the class the window is realized with. */
extern "C" void zmSetProgramClass(const char* cls) {
  gtk_init_check(NULL, NULL);
  gdk_set_program_class(cls);
}

/* Ask the window manager to put this window in front of the person who started
   it - on the desktop they are looking at, not wherever the window happened to
   be placed. */
extern "C" void zmPresentWindow(void* win) {
  if (!win) return;
  gtk_window_present(GTK_WINDOW(win));
}
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
  proc zmSetProgramClass(cls: cstring) {.importc, nodecl.}
  proc zmPresentWindow(win: pointer) {.importc, nodecl.}
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
    currentView: ViewMode  ## the view on screen right now. Not the same thing as
                           ## `ui.view`, which is the last view chosen by hand:
                           ## opening a file switches to the view that file was
                           ## last read in, and that must not become the
                           ## fallback a document with no view of its own gets.
    startupFile: string    ## file to open on launch (from the command line), "" if none
    startupRead: bool      ## whether that file has been read yet
    startupText: string    ## what it held, once read
    startupError: string   ## why it could not be read, if it could not
    nav: NavHistory        ## the documents opened this run, for back and forward
    statePath: string      ## where persisted state lives; "" means the real
                           ## per-user config file. Only the self-test overrides
                           ## it, so a headless run cannot touch a real config.
    exiting: bool

var app: App

proc appStatePath(): string =
  ## The state file this run reads and writes.
  if app.statePath.len > 0: app.statePath else: statePath()

# ---- Processes this window starts -------------------------------------------

var launchFlags: seq[string]
  ## The command-line switches this run was started with that a second window
  ## should inherit (the graphics override, the log level). The file argument is
  ## deliberately not among them: a new window starts empty.

var spawnedChildren: seq[Process]
  ## Handles for the processes this window started - other windows, and the
  ## desktop's own openers - kept only so one that has since finished can be let
  ## go of rather than left unreaped.

proc reapSpawnedChildren() =
  for p in spawnedChildren.mitems:
    var finished = true
    try: finished = not p.running
    except CatchableError: discard
    if finished:
      try: p.close() except CatchableError: discard
      p = nil
  spawnedChildren.keepItIf(it != nil)

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
  ## Just the file's own name. What a prompt about the open document says, where
  ## the full path is either in the body of the message already or beside the
  ## point.
  if app.currentPath.len > 0: extractFilename(app.currentPath) else: "Untitled"

proc displayPath(path: string): string =
  ## A path the way a person would write it: under the home directory it is
  ## shortened to `~/...`, which is both shorter and how they think of it.
  ## Not on Windows, where a tilde means nothing to anyone.
  when defined(windows):
    path
  else:
    shortenHome(path, getHomeDir())

proc docLabel(): string =
  ## What the window title and the toolbar say the open document is: its whole
  ## path, not just its name. A name on its own is no help at all when two
  ## projects both have a README and you need to know which one is in front of
  ## you - or when you simply cannot remember where you left the file.
  if app.currentPath.len > 0: displayPath(app.currentPath) else: "Untitled"

proc absolutized(path: string): string =
  ## An absolute, tidied form of a path, for the lists that have to recognize
  ## the same file however it was named. Falls back to the path as given when
  ## the filesystem will not answer.
  if path.len == 0: return ""
  try: absolutePath(normalizedPath(path))
  except CatchableError: path

proc viewForFile(path, text: string): ViewMode =
  ## Which view a document opens in: see `openingView`, which is the rule
  ## itself. This is where the two things it needs are fetched - what is
  ## remembered about this file, and whether the file has anything in it.
  ##
  ## The list is re-read from disk first, because it is shared: the view you
  ## left a file in in the other window is the view it should come back in here.
  ## So is the hand-picked fallback, for the same reason - the newest choice is
  ## the one on disk, whichever window made it.
  let disk = loadState(appStatePath())
  app.ui.recentFiles = disk.recentFiles
  app.ui.recentEnabled = disk.recentEnabled
  app.ui.view = disk.view
  let known =
    if disk.recentEnabled: recentView(disk.recentFiles, absolutized(path))
    else: none(ViewMode)
  openingView(known, blank = text.isEmptyOrWhitespace(),
              remembering = disk.recentEnabled, lastChosen = app.ui.view)

proc rememberRecent(path: string; view: Option[ViewMode]) =
  ## Add a just-opened file to the recent list, with the view it is being opened
  ## in, and write it out at once, merged onto whatever is on disk: with two
  ## windows open, neither should lose the other's files. Does nothing when the
  ## user has switched the tracking off.
  if not app.ui.recentEnabled or path.len == 0: return
  let abs = absolutized(path)
  if app.ui.recentFiles.len > 0 and app.ui.recentFiles[0] == recentFile(abs, view):
    return  # already the most recent, in the same view; nothing would change
  var disk = loadState(appStatePath())
  disk.recentFiles = addRecent(disk.recentFiles, abs, view)
  app.ui.recentFiles = disk.recentFiles
  if not saveState(disk, appStatePath()):
    vlog("could not save the recent files list: " & appStatePath())

proc setCurrentFile(path: string; remember = true) =
  ## Point the app at a file (or, with "", at nothing) and record how that file
  ## looks right now. Every later comparison against disk is against this stamp,
  ## so it has to be taken everywhere the open document changes.
  ##
  ## `remember` is false where the document is being revisited rather than
  ## opened - stepping back and forward through the session's own chain, which
  ## should not keep reshuffling the list of what was recently opened.
  app.currentPath = path
  app.diskStamp = fileStamp(path)
  # A path with no file behind it yet (`zmarkdown new-notes.md`) is not a file
  # anyone has opened, so it is remembered only once the first save creates it.
  if remember and app.diskStamp.exists: rememberRecent(path, some(app.currentView))

proc setWindowTitle(name: string) =
  ## Put the open document in the window title, after the application's own name,
  ## so a taskbar full of ZMarkdown windows says which file each one holds - and
  ## says where each file is, since the title carries the whole path.
  ## (It is also what stops a desktop from labelling them "ZMarkdown <2>",
  ## "ZMarkdown <3>": those numbers only appear because the titles were
  ## identical.)
  if app.w == nil: return
  let shown = if name.len > 0: name else: docLabel()
  try:
    app.w.title = "ZMarkdown - " & shown
  except CatchableError as e:
    vlog("could not set the window title: " & e.msg)

proc diskMovedOn(): bool =
  ## Has the open file been changed by something other than us since we last
  ## read or wrote it?
  app.currentPath.len > 0 and changed(app.diskStamp, fileStamp(app.currentPath))

# ---- Navigation history ----------------------------------------------------
#
# The chain of documents opened this run, so back and forward can walk it. Only
# opening a document extends the chain; walking it with the buttons moves along
# what is already there. The same file opened twice is two links in the chain,
# which is what makes "back" mean "where I just was" rather than "somewhere else
# that happens to have the same name".

proc navRecord(path: string) =
  ## Extend the chain with a newly opened document.
  if path.len == 0: return
  app.nav.push(absolutized(path))
  vlog("history: " & $(app.nav.position + 1) & " of " & $app.nav.len)

proc navJson(): JsonNode =
  %*{"canBack": app.nav.canBack, "canForward": app.nav.canForward}

proc jsNavState(id: string; req: JsonNode): string =
  ## navState() -> {canBack, canForward}
  $ navJson()

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
  ## applyEdit(kind, text, selStart, selEnd, indentKind, tabWidth)
  ##   -> {text, selStart, selEnd}
  ##
  ## `indentKind` and `tabWidth` matter only to Tab and Shift+Tab, and are what
  ## the toolbar toggle and the settings have settled on for the open document.
  ## The unit itself is built here rather than sent over, so the only things
  ## that can ever be inserted are a tab and a run of spaces.
  # Indexing a short argument list raises IndexDefect, which `except
  # CatchableError` does not catch, so arity is checked before anything else.
  if req.len < 4:
    return $ %*{"text": (if req.len > 1: req[1].getStr() else: ""),
                "selStart": 0, "selEnd": 0}
  try:
    let
      kind = req[0].getStr()
      text = req[1].getStr()
      a = req[2].getInt()
      b = req[3].getInt()
      # Missing or unrecognized means "whatever the settings say", so an older
      # or confused caller still indents the way the user asked for.
      indentKind =
        if req.len > 4 and req[4].kind == JString:
          let k = parseIndentKind(req[4].getStr())
          if k.isSome: k.get else: resolveIndent(app.ui.indentPref, text)
        else: resolveIndent(app.ui.indentPref, text)
      width =
        if req.len > 5 and req[5].kind == JInt: clampTabWidth(req[5].getInt())
        else: clampTabWidth(app.ui.tabWidth)
    let r =
      case kind
      of "bold": applyBold(text, a, b)
      of "italic": applyItalic(text, a, b)
      of "underline": applyUnderline(text, a, b)
      of "link": applyLink(text, a, b)
      of "image": applyImage(text, a, b)
      of "indent": applyIndent(text, a, b, indentUnit(indentKind, width))
      of "outdent": applyOutdent(text, a, b, width)
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

type
  Pref = enum
    ## A single persisted preference, so a write can carry exactly the one the
    ## user changed. `pfFileView` is the odd one out: it belongs to the open
    ## document rather than to the application, and rides along on the same
    ## write as `pfView` because one view switch settles both.
    pfView, pfFileView, pfRatio, pfFont, pfColors, pfIndent, pfRecent

var
  prefsPending: set[Pref]  ## changes deferred by the write throttle
  lastPrefsWrite = 0.0     ## epochTime of the last preference write

const PrefsWriteInterval = 0.5
  ## Shortest gap between preference writes made by a control the user can hold
  ## down or drag. Dragging a color picker emits a change per mouse move; without
  ## this, each one would be a read-modify-write of the state file.

proc persistPrefs(fields: set[Pref]) =
  ## Write the preferences the user has just changed, merged onto what is on
  ## disk now rather than over it. Doing it at the moment of the change (instead
  ## of only at exit) is what makes "the view mode I last picked" mean that even
  ## with several windows open: the newest change is the one on disk, whichever
  ## window later happens to close last.
  ##
  ## Only the named fields are written. A window that never touched the font, or
  ## the switch for the recent files list, must not put its own stale copy of
  ## them back over what another window changed a moment ago.
  if fields == {}: return
  prefsPending = prefsPending - fields
  lastPrefsWrite = epochTime()
  var disk = loadState(appStatePath())
  if pfView in fields: disk.view = app.ui.view
  if pfFileView in fields and app.ui.recentEnabled and app.currentPath.len > 0:
    # The view the open document has just been switched to becomes its own, so
    # it comes back this way. The order of the list is left alone: changing view
    # half way through reading something is not a reopening of it. A document
    # that was never saved has nowhere to keep this, and one the user told the
    # app to forget must not creep back in because a view button was clicked -
    # noteRecentView adds nothing, it only updates what is already there.
    disk.recentFiles = noteRecentView(disk.recentFiles,
                                      absolutized(app.currentPath), app.currentView)
    app.ui.recentFiles = disk.recentFiles
  if pfRatio in fields: disk.splitRatio = app.ui.splitRatio
  if pfFont in fields: disk.fontChoice = app.ui.fontChoice
  if pfColors in fields:
    disk.bgColor = app.ui.bgColor
    disk.textColor = app.ui.textColor
  if pfIndent in fields:
    disk.indentPref = app.ui.indentPref
    disk.tabWidth = app.ui.tabWidth
  if pfRecent in fields: disk.recentEnabled = app.ui.recentEnabled
  if saveState(disk, appStatePath()):
    vlog("preferences saved: " & appStatePath())
  else:
    logLine("could not save preferences (skipping persistence): " & appStatePath())

proc persistPrefsSoon(fields: set[Pref]) =
  ## Write a preference change that arrived from a control the user may be
  ## dragging. The first change goes out at once; a burst behind it is collapsed
  ## into one write, and whatever is still pending is flushed at exit.
  if epochTime() - lastPrefsWrite >= PrefsWriteInterval: persistPrefs(fields)
  else: prefsPending = prefsPending + fields

proc persistNow() =
  ## Write current UI state to disk, logging but never failing on error. The
  ## window geometry is this window's to report; everything else is merged onto
  ## what is on disk, since another window may have changed it more recently.
  let s = captureWindowState()
  app.ui.width = s.w
  app.ui.height = s.h
  app.ui.maximized = s.maximized != 0
  when defined(linux):
    foldProbeVerdict()
  # A color still in flight when the window closes.
  if prefsPending != {}: persistPrefs(prefsPending)
  var disk = loadState(appStatePath())
  disk.width = app.ui.width
  disk.height = app.ui.height
  disk.maximized = app.ui.maximized
  disk.renderMode = app.ui.renderMode
  if saveState(disk, appStatePath()):
    vlog("state saved: " & appStatePath())
  else:
    logLine("could not save state (skipping persistence): " & appStatePath())

proc readStartupFile(path: string) =
  ## Read the file named on the command line, once. The view the window comes up
  ## in and the text that lands in the editor both come out of this one read, so
  ## they cannot disagree about a file that changed in between - and the file is
  ## not read twice just to ask whether it is empty. The path is passed in
  ## rather than read off `app`, which the caller clears as it goes.
  if app.startupRead or path.len == 0: return
  app.startupRead = true
  let r = readTextFile(path)
  if r.ok: app.startupText = r.value
  else: app.startupError = r.error

proc jsLoadInitialState(id: string; req: JsonNode): string =
  ## loadInitialState() -> the restored UI state (view and split ratio matter to JS).
  ##
  ## `view` is the view the window should actually come up in. Settling it here,
  ## before the first paint, is what keeps the window from opening in one view
  ## and switching to another a moment later.
  ##
  ## With no file to open - or a name with no file behind it, or one that will
  ## not read - what comes up is an empty document, and an empty document is for
  ## writing in, so it comes up in Text.
  app.currentView = vmText
  if app.startupFile.len > 0 and fileExists(app.startupFile):
    readStartupFile(app.startupFile)
    if app.startupError.len == 0:
      app.currentView = viewForFile(app.startupFile, app.startupText)
  var st = app.ui
  st.view = app.currentView
  result = $ st.toJson()

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
    # A name with no file behind it yet is a document being started, not one
    # being opened: nothing is remembered about it and there is nothing to
    # preview, so it comes up in Text, ready to be written in.
    setCurrentFile(path)
    navRecord(path)
    logLine("new file " & path & " (written on the first save)")
    return $ %*{"path": path, "text": "", "title": docLabel(),
                "created": true, "view": $app.currentView}
  readStartupFile(path)
  if app.startupError.len > 0:
    logLine("open failed (" & path & "): " & app.startupError)
    errorDialog("Open failed", app.startupError)
    # No view to report: the read this failed on already happened inside
    # loadInitialState, which is why the window came up in Text. What is left
    # open is a blank document, which is where Text is right anyway.
    return $ %*{"path": ""}
  # The view was settled by loadInitialState(), before the window was painted.
  setCurrentFile(path)
  navRecord(path)
  logLine("opened " & path)
  $ %*{"path": path, "text": app.startupText, "title": docLabel(),
       "created": false, "view": $app.currentView}

proc jsPersistState(id: string; req: JsonNode): string =
  ## persistState(view, ratio). Called when the user switches view by hand or
  ## moves the divider, and written out at once: it has to survive a window being
  ## killed rather than closed. Fire and forget.
  ##
  ## Two different things are recorded from one call. The view becomes the open
  ## document's own, which is what makes that document come back this way; and it
  ## becomes the last view chosen by hand, which is what everything with no view
  ## of its own falls back to.
  ##
  ## Only a call that actually changes the view on screen counts as a choice.
  ## This is called for the divider as well, which reports the view it is already
  ## in on every release and every arrow key; reading those as choices would
  ## quietly promote whatever view a file happened to be remembered in into the
  ## fallback every blank document gets. For the same reason, applying a
  ## remembered view when a file opens does not come through here at all: that is
  ## the file's choice being honored, not a new one being made.
  var viewChanged = false
  var ratioChanged = false
  try:
    if req.len >= 2:
      let before = app.ui
      let v = parseViewMode(req[0].getStr())
      if v.isSome and v.get != app.currentView:
        app.currentView = v.get
        app.ui.view = v.get
        viewChanged = true
      app.ui.splitRatio = clampRatio(req[1].getFloat())
      ratioChanged = before.splitRatio != app.ui.splitRatio
  except CatchableError:
    discard
  # Both are single deliberate acts - a click on a view button, a divider
  # released - so both go out immediately and are on disk even if the window is
  # killed rather than closed. The file's own view rides along on the same write.
  var fields: set[Pref]
  if viewChanged: fields = fields + {pfView, pfFileView}
  if ratioChanged: fields.incl pfRatio
  persistPrefs(fields)
  result = "true"

proc jsSaveSettings(id: string; req: JsonNode): string =
  ## saveSettings(fontChoice, bgColor, textColor, indentPref, tabWidth). Written
  ## out as it changes, for the same reason the view mode is - collapsed, since a
  ## color picker being dragged reports every shade it passes through, and so
  ## does a width box being stepped with the arrow keys.
  var fields: set[Pref]
  try:
    let before = app.ui
    if req.len >= 1 and req[0].kind == JString: app.ui.fontChoice = req[0].getStr()
    if req.len >= 2 and req[1].kind == JString: app.ui.bgColor = req[1].getStr()
    if req.len >= 3 and req[2].kind == JString: app.ui.textColor = req[2].getStr()
    if req.len >= 4 and req[3].kind == JString:
      let p = parseIndentPref(req[3].getStr())
      if p.isSome: app.ui.indentPref = p.get
    if req.len >= 5 and req[4].kind == JInt:
      app.ui.tabWidth = clampTabWidth(req[4].getInt())
    if before.fontChoice != app.ui.fontChoice: fields.incl pfFont
    if before.bgColor != app.ui.bgColor or before.textColor != app.ui.textColor:
      fields.incl pfColors
    if before.indentPref != app.ui.indentPref or before.tabWidth != app.ui.tabWidth:
      fields.incl pfIndent
  except CatchableError:
    discard
  persistPrefsSoon(fields)
  result = "true"

proc jsIndentState(id: string; req: JsonNode): string =
  ## indentState(text, pref, width) -> {pref, kind, width}. What Tab should put
  ## into this particular document: the preference in force, the style that
  ## works out to once the document has been looked at, and how wide a level is.
  ##
  ## The document is scanned here rather than in the page so there is one
  ## implementation of "what does this file indent with" - the one the unit
  ## tests drive directly.
  ##
  ## The page passes its own copy of the preference rather than relying on the
  ## one saved here, because a settings change writes and asks in the same
  ## breath and the answer must not depend on which of the two lands first.
  ## Anything missing or unrecognized falls back to what was saved.
  let text = if req.len > 0 and req[0].kind == JString: req[0].getStr() else: ""
  var pref = app.ui.indentPref
  if req.len > 1 and req[1].kind == JString:
    let p = parseIndentPref(req[1].getStr())
    if p.isSome: pref = p.get
  var width = clampTabWidth(app.ui.tabWidth)
  if req.len > 2 and req[2].kind == JInt: width = clampTabWidth(req[2].getInt())
  $ %*{"pref": $pref, "kind": $resolveIndent(pref, text), "width": width}

# ---- Recent files ----------------------------------------------------------

proc recentJson(): JsonNode =
  ## The recent list as the menu wants it: newest first, each with the name to
  ## show and the full path to put in its tooltip. Empty while the user has the
  ## tracking switched off, so nothing that was remembered before then shows up.
  var files = newJArray()
  if app.ui.recentEnabled:
    for f in app.ui.recentFiles:
      files.add(%*{"path": f.path, "name": recentName(f.path)})
  # storedCount counts what is remembered whether or not it is on show, so the
  # Clear button can tell "nothing to clear" from "hidden by the switch".
  %*{"enabled": app.ui.recentEnabled, "files": files,
     "storedCount": app.ui.recentFiles.len, "menuCount": MenuRecent}

proc jsRecentState(id: string; req: JsonNode): string =
  ## recentState() -> {enabled, files, storedCount, menuCount}
  ##
  ## Re-read first: the list is shared with every other window, and a menu that
  ## showed only what this one had opened would miss the file you just read next
  ## door and still offer files you told that window to forget.
  ##
  ## Opening the File menu is also a convenient regular moment to let go of any
  ## window or viewer this one started that has since been closed.
  reapSpawnedChildren()
  let disk = loadState(appStatePath())
  app.ui.recentFiles = disk.recentFiles
  app.ui.recentEnabled = disk.recentEnabled
  $ recentJson()

proc jsRecentRemove(id: string; req: JsonNode): string =
  ## recentRemove(path) -> recentState(). Forget one file, as if it had never
  ## been opened.
  let path = if req.len > 0 and req[0].kind == JString: req[0].getStr() else: ""
  if path.len > 0:
    var disk = loadState(appStatePath())
    disk.recentFiles = removeRecent(disk.recentFiles, path)
    app.ui.recentFiles = disk.recentFiles
    if not saveState(disk, appStatePath()):
      vlog("could not save the recent files list: " & appStatePath())
    else:
      vlog("forgot recent file " & path)
  $ recentJson()

proc jsRecentClear(id: string; req: JsonNode): string =
  ## recentClear() -> recentState(). Empty the list and start over.
  var disk = loadState(appStatePath())
  disk.recentFiles = @[]
  app.ui.recentFiles = @[]
  if saveState(disk, appStatePath()):
    logLine("recent files list cleared")
  else:
    vlog("could not save the recent files list: " & appStatePath())
  $ recentJson()

proc jsRecentSetEnabled(id: string; req: JsonNode): string =
  ## recentSetEnabled(on) -> recentState(). Turning the tracking off stops new
  ## files being recorded and hides the list; it does not erase what is already
  ## remembered, which the Clear button is there for.
  if req.len > 0 and req[0].kind == JBool:
    app.ui.recentEnabled = req[0].getBool()
    persistPrefs({pfRecent})
    logLine("recent files tracking " & (if app.ui.recentEnabled: "on" else: "off"))
  $ recentJson()

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
  app.currentView = viewForFile(path, r.value)
  setCurrentFile(path)
  navRecord(path)
  logLine("opened " & path)
  (true, r.value, docLabel())

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
  if path.len == 0: return (false, docLabel())
  (doSaveTo(path, text), docLabel())

proc doSave(text: string): tuple[saved: bool, title: string] =
  ## Save to the current path, or fall through to Save As if there is none.
  if app.currentPath.len == 0:
    let path = saveFileDialog("Save As", "untitled.md")
    if path.len == 0: return (false, docLabel())
    return (doSaveTo(path, text), docLabel())
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
      return (false, docLabel())
  (doSaveTo(app.currentPath, text), docLabel())

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
  ## menuOpen(dirty, text) -> {opened, text, title, canBack, canForward}
  let dirty = req.len > 0 and req[0].kind == JBool and req[0].getBool()
  let text = if req.len > 1: req[1].getStr() else: ""
  if not guardUnsaved(dirty, text):
    return $ %*{"opened": false}
  let r = doOpen(text)
  var res = %*{"opened": r.opened, "text": r.content, "title": r.title,
               "view": $app.currentView}
  for k, v in navJson(): res[k] = v
  $ res

proc jsMenuNew(id: string; req: JsonNode): string =
  ## menuNew(dirty, text) -> {ok, title, view}. Guards unsaved changes, then
  ## starts a fresh empty document and forgets the current file path. The
  ## navigation chain is left as it is: a blank document is not a place you can
  ## return to, so back still means "the last file I was reading".
  ##
  ## A blank document has nothing to preview and nothing remembered about it, and
  ## somebody who has just asked for a new document is about to type into it, so
  ## it opens in Text. Without this it would inherit whatever view the file
  ## before it was remembered in.
  let dirty = req.len > 0 and req[0].kind == JBool and req[0].getBool()
  let text = if req.len > 1: req[1].getStr() else: ""
  if not guardUnsaved(dirty, text):
    return $ %*{"ok": false}
  setCurrentFile("")
  # Nothing to preview and nothing remembered, and somebody who asks for a new
  # document is about to type into it.
  app.currentView = vmText
  logLine("new document")
  $ %*{"ok": true, "title": docLabel(), "view": $app.currentView}

proc spawnNewWindow(): tuple[ok: bool, error: string] =
  ## Start a second copy of the application, so something else can be read
  ## without putting the current document away. The child is detached and gets
  ## this window's own streams, so closing this window leaves it running and its
  ## log lines still go where the first one's went.
  var exe = ""
  try:
    exe = getAppFilename()
  except CatchableError as e:
    return (false, "could not find the application's own program file: " & e.msg)
  reapSpawnedChildren()
  try:
    let p = startProcess(exe, args = launchFlags,
                         options = {poDaemon, poParentStreams})
    spawnedChildren.add(p)
    (true, "")
  except CatchableError as e:
    (false, e.msg)

proc jsNewWindow(id: string; req: JsonNode): string =
  ## newWindow() -> {ok}. Ctrl+Shift+N: another instance of the app, with its own
  ## empty document.
  let r = spawnNewWindow()
  if r.ok:
    logLine("opened a new window")
  else:
    logLine("could not open a new window: " & r.error)
    errorDialog("New window failed",
      "A second ZMarkdown window could not be started:\n" & r.error)
  $ %*{"ok": r.ok}

proc openFileInto(path: string): tuple[opened: bool, text, title: string] =
  ## Read a file and make it the open document, recording it in the navigation
  ## chain and the recent list. The unsaved-changes guard is the caller's, since
  ## only the caller knows what is in the editor.
  let r = readTextFile(path)
  if not r.ok:
    logLine("open failed (" & path & "): " & r.error)
    errorDialog("Open failed", r.error)
    return (false, "", "")
  app.currentView = viewForFile(path, r.value)
  setCurrentFile(path)
  navRecord(path)
  logLine("opened " & path)
  (true, r.value, docLabel())

proc openedJson(r: tuple[opened: bool, text, title: string]): JsonNode =
  result = %*{"opened": r.opened, "text": r.text, "title": r.title,
              "view": $app.currentView}
  for k, v in navJson(): result[k] = v

proc jsOpenPath(id: string; req: JsonNode): string =
  ## openPath(dirty, currentText, path) -> {opened, text, title, canBack,
  ## canForward}. Opens a specific file (a drag-and-drop, a row of the recent
  ## files list) through the same guard and read path as Open.
  let dirty = req.len > 0 and req[0].kind == JBool and req[0].getBool()
  let curText = if req.len > 1: req[1].getStr() else: ""
  let path = if req.len > 2 and req[2].kind == JString: req[2].getStr() else: ""
  if path.len == 0:
    return $ %*{"opened": false}
  if not guardUnsaved(dirty, curText):
    return $ %*{"opened": false}
  $ openedJson(openFileInto(path))

# ---- Following a link in the preview ---------------------------------------

const LinkTextMaxBytes = 16 * 1024 * 1024
  ## Beyond this a linked file is handed to the desktop rather than loaded into
  ## the editor. Nothing anyone edits by hand is this big, and a stray link to a
  ## disk image should not try to become a document.

const ViewableExts = [
  "png", "jpg", "jpeg", "gif", "webp", "bmp", "ico", "avif", "apng", "tif",
  "tiff", "heic", "heif", "jxl", "svg", "svgz",
  "pdf", "doc", "docx", "odt", "rtf", "xls", "xlsx", "ods", "ppt", "pptx", "odp",
  "epub", "mobi", "djvu",
  "mp3", "wav", "flac", "ogg", "oga", "opus", "m4a", "aac",
  "mp4", "m4v", "mkv", "webm", "avi", "mov", "wmv",
  "zip", "gz", "bz2", "xz", "zst", "7z", "rar", "tar", "tgz",
  "woff", "woff2", "ttf", "otf",
]
  ## Extensions that mean "this is for another program to show you". Everything
  ## else is treated as text worth opening here, so a link to `LICENSE`,
  ## `Makefile`, or `notes` lands in the editor rather than bouncing off to the
  ## desktop.

const ProgramExts = [
  "exe", "com", "scr", "msi", "msix", "bat", "cmd", "ps1", "vbs", "js", "jse",
  "wsf", "lnk", "appimage", "run", "app", "dll", "so", "dylib", "jar", "class",
  "pyc", "wasm", "bin", "elf", "deb", "rpm", "pkg", "dmg", "iso", "img",
  "desktop", "reg",
]
  ## Extensions that could get something *run* rather than shown. A click on a
  ## link in somebody else's document must never be able to start a program, so
  ## these are refused outright instead of being handed to the desktop - which
  ## for several of them (a `.jar`, a `.desktop`, an `.exe`) means executing it.

proc looksBinary(path: string): bool =
  ## Whether a file has a NUL byte near its start, the oldest and still the most
  ## reliable "this is not text" test. An unreadable file is not called binary:
  ## letting it through gets the real error reported by the read that follows.
  try:
    let f = open(path, fmRead)
    defer: f.close()
    var buf = newString(8192)
    let n = f.readBuffer(addr buf[0], buf.len)
    for i in 0 ..< n:
      if buf[i] == '\0': return true
  except CatchableError:
    discard
  false

proc openWithDesktop(target: string): bool =
  ## Hand a file, folder, or web address to whatever the desktop opens it with.
  ## Returns false only when the attempt itself could not be made.
  ##
  ## On Linux this spawns the opener rather than calling
  ## `browsers.openDefaultBrowser`, which waits for it: `xdg-open` runs the
  ## handler in the foreground when it cannot identify the desktop, and waiting
  ## on that would freeze the editor for as long as the viewer stayed open.
  when defined(linux):
    try:
      let p = startProcess("xdg-open", args = [target],
                           options = {poUsePath, poDaemon, poParentStreams})
      spawnedChildren.add(p)
      logLine("handed " & target & " to the desktop")
      return true
    except CatchableError as e:
      vlog("xdg-open could not be started (" & e.msg & "); falling back")
  try:
    openDefaultBrowser(target)
    logLine("handed " & target & " to the desktop")
    true
  except CatchableError as e:
    logLine("could not open " & target & " externally: " & e.msg)
    false

func linkPathOf(href: string): string =
  ## The filesystem part of a link target: everything before a `#fragment` or a
  ## `?query`, which belong to the URL and not to the file's name.
  result = href
  let hash = result.find('#')
  if hash >= 0: result = result[0 ..< hash]
  let q = result.find('?')
  if q >= 0: result = result[0 ..< q]

proc jsOpenLink(id: string; req: JsonNode): string =
  ## openLink(dirty, currentText, href) -> {kind, opened, text, title, canBack,
  ## canForward}. A link clicked in the rendered preview.
  ##
  ## `kind` is "external" when it went to the desktop, "opened" when the linked
  ## document is now the open one, and "none" when nothing happened. A relative
  ## link resolves against the folder the current document lives in, which is
  ## what makes a repository's README reach the files it points at.
  let dirty = req.len > 0 and req[0].kind == JBool and req[0].getBool()
  let curText = if req.len > 1: req[1].getStr() else: ""
  let href = if req.len > 2 and req[2].kind == JString: req[2].getStr().strip() else: ""
  if href.len == 0:
    return $ %*{"kind": "none"}

  let scheme = schemeOf(href)
  if scheme notin ["", "file"]:
    # Anything with a scheme of its own belongs to another program - but only
    # the ones a document legitimately links to, so a rendered `javascript:` or
    # some unknown handler cannot be talked into running.
    if scheme in ["http", "https", "mailto", "ftp", "ftps"]:
      discard openWithDesktop(href)
      return $ %*{"kind": "external"}
    logLine("ignoring a link with an unsupported scheme: " & scheme & ":")
    return $ %*{"kind": "none"}

  let target = resolvePath(linkPathOf(href), docBaseDir())
  if target.len == 0:
    return $ %*{"kind": "none"}

  if dirExists(target):
    discard openWithDesktop(target)
    return $ %*{"kind": "external"}
  if not fileExists(target):
    logLine("link target does not exist: " & target)
    # A very common mistake is `[Site](example.com)`, which markdown reads as a
    # file beside the document. Say so rather than only naming a path the reader
    # never wrote.
    let looksLikeHost = '/' notin href and '\\' notin href and
                        '.' in linkPathOf(href) and ' ' notin href
    errorDialog("Cannot follow that link",
      "This link points at a file that is not there:\n" & target &
      (if looksLikeHost:
         "\n\nIf a web address was meant, the link needs its https:// prefix."
       else: ""))
    return $ %*{"kind": "none"}

  let ext = target.splitFile().ext.strip(chars = {'.'}).toLowerAscii()

  # A program, an installer, a disk image. Handing one to the desktop is how a
  # link in a document someone else wrote would get it *run*, so refuse: this is
  # a markdown reader, and no click in it should start anything.
  if ext in ProgramExts:
    logLine("refused to open a program from a link: " & target)
    errorDialog("Cannot follow that link",
      "This link points at a program or installer, and ZMarkdown will not " &
      "start one:\n" & target &
      "\n\nOpen it from your file manager if that is really what you want.")
    return $ %*{"kind": "none"}

  # A picture, an archive, a PDF: the desktop knows what to do with it, and the
  # editor does not.
  var forDesktop = ext in ViewableExts
  if not forDesktop:
    # Not a name anything recognizes. If it is not text either, there is nothing
    # useful to do with it and nothing safe to guess, so say so and stop.
    let stamp = fileStamp(target)
    if stamp.size > LinkTextMaxBytes or looksBinary(target):
      logLine("link target is not a text document: " & target)
      errorDialog("Cannot follow that link",
        "This link points at a file that is not text, and nothing here says " &
        "what would display it:\n" & target)
      return $ %*{"kind": "none"}
  if forDesktop:
    discard openWithDesktop(target)
    return $ %*{"kind": "external"}

  if not guardUnsaved(dirty, curText):
    return $ %*{"kind": "none"}
  let r = openFileInto(target)
  if not r.opened:
    return $ %*{"kind": "none"}
  var res = openedJson(r)
  res["kind"] = %"opened"
  $ res

# ---- Walking the navigation chain ------------------------------------------

proc navStep(dirty: bool; curText: string; forward: bool): string =
  ## Back or forward one document. The chain only moves once the file has
  ## actually been read: a document that has since been deleted reports the
  ## failure and leaves you where you are, with the chain intact.
  let target = if forward: app.nav.forwardTarget() else: app.nav.backTarget()
  if target.len == 0:
    return $ %*{"opened": false}
  if not guardUnsaved(dirty, curText):
    return $ %*{"opened": false}
  let r = readTextFile(target)
  if not r.ok:
    logLine("history: could not open " & target & ": " & r.error)
    errorDialog("Cannot go " & (if forward: "forward" else: "back"), r.error)
    return $ %*{"opened": false}
  if forward: app.nav.goForward() else: app.nav.goBack()
  app.currentView = viewForFile(target, r.value)
  setCurrentFile(target, remember = false)
  logLine((if forward: "forward to " else: "back to ") & target)
  var res = %*{"opened": true, "text": r.value, "title": docLabel(),
               "view": $app.currentView}
  for k, v in navJson(): res[k] = v
  $ res

proc jsNavBack(id: string; req: JsonNode): string =
  ## navBack(dirty, currentText) -> {opened, text, title, canBack, canForward}
  let dirty = req.len > 0 and req[0].kind == JBool and req[0].getBool()
  let curText = if req.len > 1: req[1].getStr() else: ""
  navStep(dirty, curText, forward = false)

proc jsNavForward(id: string; req: JsonNode): string =
  ## navForward(dirty, currentText) -> {opened, text, title, canBack, canForward}
  let dirty = req.len > 0 and req[0].kind == JBool and req[0].getBool()
  let curText = if req.len > 1: req[1].getStr() else: ""
  navStep(dirty, curText, forward = true)

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
  # Content with no file behind it is a document being started, not one being
  # opened, and nothing is remembered about it. It has text in it, though, so
  # unlike File > New there is something to read: it gets the view last chosen by
  # hand rather than being forced into Text.
  app.currentView = app.ui.view
  logLine("loaded dropped content" & (if name.len > 0: " (" & name & ")" else: ""))
  $ %*{"ok": true, "title": (if name.len > 0: name else: "Untitled"),
       "view": $app.currentView}

proc jsReloadFile(id: string; req: JsonNode): string =
  ## reloadFile(dirty, text) -> {ok, text, title}. F5: read the open file from
  ## disk again, so a document edited elsewhere can be picked up without
  ## reopening it.
  ##
  ## Unsaved changes are never thrown away silently. When there are any, the
  ## prompt offers all three honest answers: keep them (they are written out
  ## first, so the refresh finds them there), discard them for what is on disk,
  ## or call the whole thing off.
  let dirty = req.len > 0 and req[0].kind == JBool and req[0].getBool()
  let text = if req.len > 1 and req[1].kind == JString: req[1].getStr() else: ""
  if app.currentPath.len == 0:
    infoDialog("Nothing to refresh",
      "This document has never been saved, so there is no file on disk to " &
      "refresh it from.")
    return $ %*{"ok": false}
  if not fileExists(app.currentPath):
    let hadFile = app.diskStamp.exists
    logLine("refresh: " & app.currentPath & " is not on disk")
    infoDialog("Nothing to refresh",
      (if hadFile: "This file is no longer on disk:\n"
       else: "This document has not been written to disk yet:\n") &
      app.currentPath)
    return $ %*{"ok": false}
  let startedAt = app.currentPath
  if dirty:
    case refreshPrompt(docName())
    of rcKeep:
      # Saving is what "keep my version" means; the changed-on-disk prompt is
      # part of that, since the file has probably moved on underneath.
      if not doSave(text).saved:
        logLine("refresh cancelled (the save that would have kept the changes did not happen)")
        return $ %*{"ok": false}
    of rcDiscard:
      logLine("refresh: discarding unsaved changes at the user's request")
    of rcCancel:
      logLine("refresh cancelled (unsaved changes kept)")
      return $ %*{"ok": false}
  # Save As during the prompt above can have moved the document elsewhere; the
  # refresh follows it to wherever it now lives, and so does the back/forward
  # chain, which would otherwise still point at the name it used to have.
  if app.currentPath != startedAt:
    navRecord(app.currentPath)
  if not fileExists(app.currentPath):
    logLine("refresh: " & app.currentPath & " is not on disk")
    return $ %*{"ok": false}
  let r = readTextFile(app.currentPath)
  if not r.ok:
    logLine("refresh failed (" & app.currentPath & "): " & r.error)
    errorDialog("Refresh failed", r.error)
    return $ %*{"ok": false}
  app.diskStamp = fileStamp(app.currentPath)
  logLine("refreshed " & app.currentPath)
  $ %*{"ok": true, "text": r.value, "title": docLabel()}

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

proc jsSetWindowTitle(id: string; req: JsonNode): string =
  ## setWindowTitle(name). Keeps the native window title in step with the
  ## document on show, which is the only place a desktop can read it from.
  let name = if req.len > 0 and req[0].kind == JString: req[0].getStr() else: ""
  setWindowTitle(name)
  "true"

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
  if req.len < 1:
    return $ historyStatus()
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
  discard w.bind("indentState", jsIndentState)
  discard w.bind("menuOpen", jsMenuOpen)
  discard w.bind("menuNew", jsMenuNew)
  discard w.bind("newWindow", jsNewWindow)
  discard w.bind("openPath", jsOpenPath)
  discard w.bind("loadDropped", jsLoadDropped)
  discard w.bind("openLink", jsOpenLink)
  discard w.bind("navState", jsNavState)
  discard w.bind("navBack", jsNavBack)
  discard w.bind("navForward", jsNavForward)
  discard w.bind("recentState", jsRecentState)
  discard w.bind("recentRemove", jsRecentRemove)
  discard w.bind("recentClear", jsRecentClear)
  discard w.bind("recentSetEnabled", jsRecentSetEnabled)
  discard w.bind("reloadFile", jsReloadFile)
  discard w.bind("menuSave", jsMenuSave)
  discard w.bind("menuSaveAs", jsMenuSaveAs)
  discard w.bind("setWindowTitle", jsSetWindowTitle)
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
  when defined(linux):
    # Before the window exists, so it is realized with this class. The desktop
    # entry declares StartupWMClass=ZMarkdown; without this GTK would name the
    # class after the program file instead ("Zmarkdown"), the two would not
    # match, and the desktop could not tie the window that appears back to the
    # launch that asked for it - which is what tells it where to put the window.
    zmSetProgramClass("ZMarkdown")
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

  when defined(linux):
    # Now that the window is the size and shape it should be, ask for it to be
    # put in front of whoever started it. Without this a window manager is free
    # to leave it on whatever desktop it feels like, unraised - which is how a
    # window ends up open on a desktop you are not looking at, and you never
    # notice it started at all.
    if win != nil: zmPresentWindow(win)

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
    of "refresh": 4.cint
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
  app.currentView = app.ui.view
  # Persistence is exercised for real here (the recent files list is written the
  # moment a file is opened), so point it at a file of its own: a test run must
  # never touch the config of whoever is running it.
  # Named after this process, so two self-tests running at once cannot share
  # (and then delete) each other's file.
  app.statePath = getTempDir() /
    ("zmarkdown-selftest-state-" & $getCurrentProcessId() & ".json")
  try: removeFile(app.statePath)
  except CatchableError: discard

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

  # A document nothing has ever opened, so the view it comes up in is the one an
  # unfamiliar file gets rather than one it was remembered with.
  let viewPath = getTempDir() / "zmarkdown-selftest-view.md"
  try: writeFile(viewPath, "# View memory\n\nbody\n")
  except CatchableError: discard

  # A file on disk with nothing in it: the case that has to come up ready to
  # type into rather than showing a preview of nothing.
  let emptyPath = getTempDir() / "zmarkdown-selftest-empty.md"
  try: writeFile(emptyPath, "")
  except CatchableError: discard

  # A pair of documents that link to each other, for following a link in the
  # preview and then walking back along the chain of what was opened.
  let linkA = getTempDir() / "zmarkdown-selftest-a.md"
  let linkB = getTempDir() / "zmarkdown-selftest-b.md"
  try:
    writeFile(linkA, "# Doc A\n\nGo to [B](zmarkdown-selftest-b.md).\n")
    writeFile(linkB, "# Doc B\n\nBack to [A](zmarkdown-selftest-a.md).\n")
  except CatchableError: discard

  # Answers for the prompts the driver is about to provoke, in the order it
  # provokes them: call off the first refresh over unsaved changes, discard on
  # the second, cancel the first save onto a file that changed underneath, and
  # overwrite on the second.
  scriptedReplies[0] = 0  # refresh: cancel, keep my unsaved changes
  scriptedReplies[1] = 2  # refresh: discard them and take what is on disk
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
        if st{"view"}.getStr() != "text":
          failures.add("launching with a file that does not exist yet did not come up " &
            "in Text (got '" & st{"view"}.getStr() & "')")
        if st{"title"}.getStr() != displayPath(newPath):
          failures.add("startup title: expected '" & displayPath(newPath) &
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
      elif scriptedAsked[0] != 4 or scriptedAsked[1] != 4 or
           scriptedAsked[2] != 3 or scriptedAsked[3] != 3:
        failures.add("the prompts asked were not refresh, refresh, conflict, conflict")
      # Following links in the preview, and the chain of documents that leaves.
      let nav = r{"nav"}
      if nav == nil or nav.kind != JObject or nav{"error"}.getStr().len > 0:
        failures.add("link/history self-test did not report" &
          (if nav != nil and nav{"error"}.getStr().len > 0:
             ": " & nav{"error"}.getStr() else: ""))
      else:
        if nav{"startTitle"}.getStr() != displayPath(linkA):
          failures.add("the linked-from document was not opened (title '" &
            nav{"startTitle"}.getStr() & "')")
        if nav{"startForward"}.getBool():
          failures.add("Forward was offered right after opening a document")
        if not nav{"linkedText"}.getStr().contains("Doc B"):
          failures.add("clicking a relative link did not open the linked file (editor holds '" &
            nav{"linkedText"}.getStr() & "')")
        if not nav{"linkedBack"}.getBool():
          failures.add("Back was not offered after following a link")
        if nav{"linkedForward"}.getBool():
          failures.add("Forward was offered before anything had been gone back from")
        if not nav{"backText"}.getStr().contains("Doc A"):
          failures.add("Back did not return to the previous document (editor holds '" &
            nav{"backText"}.getStr() & "')")
        if not nav{"backForward"}.getBool():
          failures.add("Forward was not offered after going back")
        if not nav{"fwdText"}.getStr().contains("Doc B"):
          failures.add("Forward did not return to the later document (editor holds '" &
            nav{"fwdText"}.getStr() & "')")
        # Opening something new after going back rewrites the tail of the chain.
        if not nav{"branchBack"}.getBool():
          failures.add("Back was lost after opening a document from part-way back")
        if nav{"branchForward"}.getBool():
          failures.add("the abandoned forward entries survived opening another document")
        # A heading anchor, which only resolves because headings carry ids.
        if not nav{"anchorOk"}.getBool():
          failures.add("a link to a heading in the same document found nothing")
      # The empty-document watermark, and the recent files list.
      let hint = r{"hint"}
      if hint == nil or hint.kind != JObject:
        failures.add("empty-document self-test did not report")
      else:
        if hint{"emptyPreview"}.getBool() != true:
          failures.add("the empty-file watermark was not shown in Preview")
        if hint{"emptySplit"}.getBool() != false:
          failures.add("the empty-file watermark was shown in Split, where the editor is visible")
        if hint{"filledPreview"}.getBool() != false:
          failures.add("the empty-file watermark was shown over a document with text in it")
      let rec = r{"recent"}
      if rec == nil or rec.kind != JObject or rec{"error"}.getStr().len > 0:
        failures.add("recent files self-test did not report" &
          (if rec != nil and rec{"error"}.getStr().len > 0:
             ": " & rec{"error"}.getStr() else: ""))
      else:
        let listed = rec{"paths"}
        if listed == nil or listed.kind != JArray or listed.len == 0:
          failures.add("no recently opened files were listed in the menu")
        else:
          if listed[0].getStr() != linkA:
            failures.add("the most recently opened file was not first in the list (got '" &
              listed[0].getStr() & "')")
          if rec{"names"}[0].getStr() != extractFilename(linkA):
            failures.add("a recent file row did not show the file's own name")
          if not rec{"titles"}[0].getStr().contains(linkA):
            failures.add("a recent file row did not carry its full path for the tooltip")
        if rec{"afterForget"}.getBool():
          failures.add("a forgotten file was still in the recent files list")
        if rec{"afterClear"}.getInt() != 0:
          failures.add("clearing left " & $rec{"afterClear"}.getInt() & " recent files behind")
        if not rec{"hiddenWhenOff"}.getBool():
          failures.add("the recent files list was still shown after tracking was switched off")
      # The view each document opens in, and where that view is kept.
      let vw = r{"views"}
      if vw == nil or vw.kind != JObject or vw{"error"}.getStr().len > 0:
        failures.add("view memory self-test did not report" &
          (if vw != nil and vw{"error"}.getStr().len > 0:
             ": " & vw{"error"}.getStr() else: ""))
      else:
        proc wantView(key, expect, what: string) =
          let got = vw{key}.getStr()
          if got != expect:
            failures.add(what & ": expected " & expect & ", got '" & got & "'")
        wantView("emptyFile", "text",
          "a file with nothing in it did not come up in Text")
        wantView("emptyPicked", "split", "clicking the Split view button")
        wantView("emptyRemembered", "split",
          "an empty file did not reopen in the view it was left in")
        wantView("emptyTrackingOff", "text",
          "with the remembering switched off, an empty file did not come up in Text")
        wantView("unknown", "preview",
          "a file nothing was remembered about did not open in Preview")
        wantView("pickedText", "text", "clicking the Text view button")
        wantView("otherFile", "preview", "one file's view followed another file")
        wantView("reopened", "text",
          "a file did not reopen in the view it was left in")
        wantView("navBack", "preview",
          "walking back to a document did not reopen it in its own view")
        wantView("handPick", "split", "clicking the Split view button")
        wantView("trackingOff", "split",
          "with the remembering switched off, a file did not get the hand-picked view")
        wantView("trackingOn", "text",
          "switching the remembering back on did not restore a file's own view")
        wantView("newDoc", "text",
          "File > New did not come up in Text, ready to be written in")
        wantView("findView", "text",
          "opening a file with the find bar open ignored the file's own view")
        if vw{"findCaret"}.getStr() != "0:0":
          failures.add("opening a file with the find bar open left the caret on a " &
            "match instead of the top of the document (at " &
            vw{"findCaret"}.getStr() & ")")
        # And it is on disk, against the file it belongs to, not global.
        let saved = loadState(app.statePath)
        if recentView(saved.recentFiles, viewPath) != some(vmText):
          failures.add("the view a file was switched to was not written against it")
        if recentView(saved.recentFiles, linkA) != some(vmPreview):
          failures.add("a file opened in Preview was not remembered as Preview")
        if recentView(saved.recentFiles, linkB) != some(vmSplit):
          failures.add("the view picked by hand was not written against the open file")
        if recentView(saved.recentFiles, emptyPath) != some(vmSplit):
          failures.add("an empty file did not keep the view it was switched to")
        # The hand-picked fallback is the last view actually chosen - never one a
        # file was merely reopened in, and never one the divider reported back.
        if saved.view != vmSplit:
          failures.add("opening files in their own views moved the hand-picked view to " &
            $saved.view)
      # Tab types a tab rather than leaving the editor.
      let tb = r{"tab"}
      if tb == nil or tb.kind != JObject or tb{"error"}.getStr().len > 0:
        failures.add("tab self-test did not report" &
          (if tb != nil and tb{"error"}.getStr().len > 0:
             ": " & tb{"error"}.getStr() else: ""))
      else:
        if not tb{"swallowed"}.getBool():
          failures.add("Tab in the editor was left to move focus instead of typing")
        if tb{"typed"}.getStr() != "a\tbc":
          failures.add("Tab did not type a tab (got '" & tb{"typed"}.getStr() & "')")
        if tb{"caret"}.getInt() != 2:
          failures.add("the caret was not left after the typed tab (got " &
            $tb{"caret"}.getInt() & ")")
        if tb{"outdented"}.getStr() != "abc":
          failures.add("Shift+Tab did not take the indentation off (got '" &
            tb{"outdented"}.getStr() & "')")
        if tb{"block"}.getStr() != "\ta\n\tb\n":
          failures.add("Tab over a selected block did not indent every line (got '" &
            tb{"block"}.getStr() & "')")
        if not tb{"escapes"}.getBool():
          failures.add("Escape then Tab did not give the editor's focus up")
        if tb{"afterEscape"}.getStr() != "abc":
          failures.add("Escape then Tab typed a tab instead of moving focus")
      # Tabs or spaces: the setting, the auto-detection, and the toolbar toggle.
      let ind = r{"indent"}
      if ind == nil or ind.kind != JObject or ind{"error"}.getStr().len > 0:
        failures.add("indentation self-test did not report" &
          (if ind != nil and ind{"error"}.getStr().len > 0:
             ": " & ind{"error"}.getStr() else: ""))
      else:
        proc wantInd(key, expect, what: string) =
          let got = ind{key}.getStr()
          if got != expect:
            failures.add(what & ": expected '" & expect & "', got '" & got & "'")
        wantInd("detectedSpace", "space",
          "a spaces-indented document was not detected as spaces")
        wantInd("spaceTyped", "    a\n    b\n",
          "Tab did not put spaces into a spaces-indented document")
        wantInd("detectedTab", "tab",
          "a tab-indented document was not detected as tabs")
        wantInd("label", "Tabs", "the toolbar button did not say what Tab puts in")
        wantInd("flippedKind", "space", "the toolbar button did not switch to spaces")
        wantInd("flippedLabel", "Spaces", "the toolbar button label after switching")
        wantInd("prefAfterFlip", "auto",
          "flipping the toolbar button changed the saved preference")
        wantInd("flippedTyped", "    a\n\tb\n",
          "Tab ignored the toolbar button and put in a tab anyway")
        wantInd("afterReload", "tab",
          "the toolbar flip outlived the document it was made for")
        wantInd("forcedKind", "space",
          "a document's own tabs overrode an explicit Spaces preference")
        wantInd("tabSize", "2", "the editor did not draw a tab at the set width")
        wantInd("widthTyped", "  a\n\tb\n",
          "Tab did not put in as many spaces as the width asks for")
        wantInd("widthOutdented", "a\n\tb\n",
          "Shift+Tab did not take one level of spaces back off")
        # And the settings themselves are on disk, at the values the run ended
        # on rather than the defaults it would fall back to if nothing was
        # written at all.
        wantInd("savedPref", "space", "the preference the run ended on")
        if ind{"savedWidth"}.getInt() != 3:
          failures.add("the width the run ended on: expected 3, got " &
            $ind{"savedWidth"}.getInt())
        let savedInd = loadState(app.statePath)
        if savedInd.indentPref != ipSpace:
          failures.add("the indentation preference was not written to disk (got " &
            $savedInd.indentPref & ")")
        if savedInd.tabWidth != 3:
          failures.add("the tab width was not written to disk (got " &
            $savedInd.tabWidth & ")")
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
        var startup = { text: window.__zm.getEditorValue(), title: window.__zm.getTitle(),
                        view: window.__zm.getView() };
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
        // Following a link in the preview, and walking the chain of documents
        // that opening things leaves behind. Driven through the real rendered
        // anchor and the real toolbar arrows.
        var nav = {};
        try {
          window.__zm.setView("preview");
          var oa = await window.openPath(false, "", window.__zmLinkA);
          if (oa && oa.opened) await window.__zm.loadOpened(oa);
          nav.startTitle = window.__zm.getTitle();
          nav.startForward = window.__zm.navState().canForward;
          var clicked = await window.__zm.clickLink(0);   // the [B] link in A
          nav.linkedText = clicked.text;
          nav.linkedBack = clicked.canBack;
          nav.linkedForward = clicked.canForward;
          var b1 = await window.__zm.navGo(false);
          nav.backText = b1.text;
          nav.backForward = b1.canForward;
          var f1 = await window.__zm.navGo(true);
          nav.fwdText = f1.text;
          // Step back, then open something else: the abandoned forward entries
          // must not survive it.
          await window.__zm.navGo(false);
          var ob = await window.openPath(false, "", window.__zmLinkB);
          if (ob && ob.opened) await window.__zm.loadOpened(ob);
          nav.branchBack = window.__zm.navState().canBack;
          nav.branchForward = window.__zm.navState().canForward;
          // A link to a heading in this same document scrolls rather than
          // opening anything, which needs the heading to have an id.
          await window.__zm.setEditor("# A Heading Here\n\n[jump](#a-heading-here)\n");
          nav.anchorOk = window.__zm.getRenderedHtml().indexOf('id="a-heading-here"') !== -1 &&
                         window.__zm.gotoAnchor("a-heading-here") === true &&
                         window.__zm.gotoAnchor("no-such-heading") === false;
        } catch (e) { nav.error = String(e); }
        // The watermark over an empty document in Preview.
        var hint = {};
        try {
          await window.__zm.setEditor("   \n\n  \n");
          window.__zm.setView("preview");
          hint.emptyPreview = window.__zm.emptyHintShown();
          window.__zm.setView("split");
          hint.emptySplit = window.__zm.emptyHintShown();
          window.__zm.setView("preview");
          await window.__zm.setEditor("# Not empty\n");
          hint.filledPreview = window.__zm.emptyHintShown();
        } catch (e) { hint.error = String(e); }
        // The recent files list: what the menu shows, forgetting one row,
        // clearing the lot, and hiding it when the tracking is switched off.
        var recent = {};
        try {
          var oa2 = await window.openPath(false, "", window.__zmLinkA);
          if (oa2 && oa2.opened) await window.__zm.loadOpened(oa2);
          var menu = await window.__zm.recentMenu();
          recent.paths = menu.paths;
          recent.names = menu.names;
          recent.titles = menu.titles;
          var afterForget = await window.__zm.recentForget(window.__zmLinkB);
          recent.afterForget =
            (afterForget.files || []).some(function (f) { return f.path === window.__zmLinkB; });
          var off = await window.recentSetEnabled(false);
          recent.hiddenWhenOff = (off.files || []).length === 0 && off.storedCount > 0;
          await window.recentSetEnabled(true);
          var cleared = await window.recentClear();
          recent.afterClear = (cleared.files || []).length;
        } catch (e) { recent.error = String(e); }
        // The view a document opens in: Preview for one nothing is remembered
        // about, and its own view for one that has been read before. Runs after
        // the recent list was cleared above, so both files start unfamiliar.
        var views = {};
        try {
          // A file with nothing in it has nothing to preview, and is nearly
          // always one just made to be written in, so it comes up in Text.
          var oe = await window.openPath(false, "", window.__zmEmptyPath);
          if (oe && oe.opened) await window.__zm.loadOpened(oe);
          views.emptyFile = window.__zm.getView();
          // Unless we remember being in something else in it: what is
          // remembered about a file beats what is in it.
          views.emptyPicked = await window.__zm.pickView("split");
          // Move the hand-picked view somewhere else first, on a different file,
          // so reopening the empty one can only land on Split by remembering it:
          // neither the hand pick nor the empty-document rule would say Split.
          var ob0 = await window.openPath(false, "", window.__zmLinkB);
          if (ob0 && ob0.opened) await window.__zm.loadOpened(ob0);
          await window.__zm.pickView("text");
          var oe2 = await window.openPath(false, "", window.__zmEmptyPath);
          if (oe2 && oe2.opened) await window.__zm.loadOpened(oe2);
          views.emptyRemembered = window.__zm.getView();
          // A file nothing is remembered about opens in Preview.
          var ov = await window.openPath(false, "", window.__zmViewPath);
          if (ov && ov.opened) await window.__zm.loadOpened(ov);
          views.unknown = window.__zm.getView();
          // Picking a view by hand is what records one against the open file.
          views.pickedText = await window.__zm.pickView("text");
          // Another file has its own view, not this one's.
          var oa3 = await window.openPath(false, "", window.__zmLinkA);
          if (oa3 && oa3.opened) await window.__zm.loadOpened(oa3);
          views.otherFile = window.__zm.getView();
          // And the first one comes back the way it was left.
          var ov2 = await window.openPath(false, "", window.__zmViewPath);
          if (ov2 && ov2.opened) await window.__zm.loadOpened(ov2);
          views.reopened = window.__zm.getView();
          // Walking back to a document reopens it in its own view too.
          await window.__zm.navGo(false);
          views.navBack = window.__zm.getView();
          // A hand-picked view, made on a third file so the two above keep the
          // views they were given.
          var ob2 = await window.openPath(false, "", window.__zmLinkB);
          if (ob2 && ob2.opened) await window.__zm.loadOpened(ob2);
          views.handPick = await window.__zm.pickView("split");
          // Opening a document with the find bar open must leave the caret at the
          // top of it. The switch into that document's own view repaints the find
          // bar, and that repaint must not drag the caret onto a match.
          await window.__zm.findOpen(false);
          await window.__zm.findQuery("o", false, false);
          var ovf = await window.openPath(false, "", window.__zmViewPath);
          if (ovf && ovf.opened) await window.__zm.loadOpened(ovf);
          await new Promise(function (r) { setTimeout(r, 400); });
          var edFind = document.getElementById("editor");
          views.findCaret = edFind.selectionStart + ":" + edFind.selectionEnd;
          views.findView = window.__zm.getView();
          window.__zm.findClose();
          // With the remembering switched off, a file gets that hand-picked view
          // rather than the one it is still remembered with.
          await window.recentSetEnabled(false);
          var ov3 = await window.openPath(false, "", window.__zmViewPath);
          if (ov3 && ov3.opened) await window.__zm.loadOpened(ov3);
          views.trackingOff = window.__zm.getView();
          // An empty document is empty whether or not anything is remembered, so
          // it still comes up in Text rather than taking the hand-picked view.
          var oe3 = await window.openPath(false, "", window.__zmEmptyPath);
          if (oe3 && oe3.opened) await window.__zm.loadOpened(oe3);
          views.emptyTrackingOff = window.__zm.getView();
          await window.recentSetEnabled(true);
          // Switched back on, the file is remembered again - and reopening it in
          // its own view, then moving the divider, must not turn that view into
          // the hand-picked one. Nim checks the file on disk still says "split".
          var ov4 = await window.openPath(false, "", window.__zmViewPath);
          if (ov4 && ov4.opened) await window.__zm.loadOpened(ov4);
          views.trackingOn = window.__zm.getView();
          await window.persistState(window.__zm.getView(), 0.42); // a divider release
          // File > New has no view of its own either, so it takes the hand pick.
          var nw = await window.menuNew(false, "");
          views.newDoc = nw && nw.view;
        } catch (e) { views.error = String(e); }
        // Tab types a tab in the editor instead of jumping out of it, and
        // Shift+Tab takes a level of indentation back off. Driven as real key
        // presses on the textarea, so the handler and the round trip are covered.
        var tab = {};
        try {
          var edTab = document.getElementById("editor");
          window.__zm.setView("text");
          function pressTab(shift) {
            return !edTab.dispatchEvent(new KeyboardEvent("keydown",
              { key: "Tab", shiftKey: !!shift, bubbles: true, cancelable: true }));
          }
          await window.__zm.setEditor("abc");
          edTab.setSelectionRange(1, 1);
          tab.swallowed = pressTab(false);
          await new Promise(function (r) { setTimeout(r, 400); });
          tab.typed = edTab.value;
          tab.caret = edTab.selectionStart;
          await window.__zm.setEditor("\tabc");
          edTab.setSelectionRange(2, 2);
          pressTab(true);
          await new Promise(function (r) { setTimeout(r, 400); });
          tab.outdented = edTab.value;
          await window.__zm.setEditor("a\nb\n");
          edTab.setSelectionRange(0, 3);
          pressTab(false);
          await new Promise(function (r) { setTimeout(r, 400); });
          tab.block = edTab.value;
          // Escape first is the way out for keyboard-only use: the very next
          // Tab moves focus rather than typing.
          await window.__zm.setEditor("abc");
          edTab.setSelectionRange(1, 1);
          edTab.dispatchEvent(new KeyboardEvent("keydown",
            { key: "Escape", bubbles: true, cancelable: true }));
          tab.escapes = !pressTab(false);
          await new Promise(function (r) { setTimeout(r, 300); });
          tab.afterEscape = edTab.value;
        } catch (e) { tab.error = String(e); }
        // What Tab puts in: the setting, what the document itself says, and the
        // toolbar button that flips it for the document in front of you.
        var ind = {};
        try {
          var edI = document.getElementById("editor");
          window.__zm.setView("text");
          function pressTabI(shift) {
            return !edI.dispatchEvent(new KeyboardEvent("keydown",
              { key: "Tab", shiftKey: !!shift, bubbles: true, cancelable: true }));
          }
          // Auto-detect: a document indented with spaces gets spaces.
          await window.__zm.setIndentPref("auto", 4);
          await window.__zm.setEditor("a\n    b\n");
          ind.detectedSpace = window.__zm.indentState().kind;
          edI.setSelectionRange(0, 0);
          pressTabI(false);
          await new Promise(function (r) { setTimeout(r, 400); });
          ind.spaceTyped = edI.value;
          // ...and one indented with tabs gets tabs.
          await window.__zm.setEditor("a\n\tb\n");
          ind.detectedTab = window.__zm.indentState().kind;
          ind.label = window.__zm.indentState().label;
          // The toolbar button flips this document without touching the setting.
          var flipped = window.__zm.indentToggle();
          ind.flippedKind = flipped.kind;
          ind.flippedLabel = flipped.label;
          ind.prefAfterFlip = window.__zm.indentState().pref;
          edI.setSelectionRange(0, 0);
          pressTabI(false);
          await new Promise(function (r) { setTimeout(r, 400); });
          ind.flippedTyped = edI.value;
          // A flip lasts for this document only: the next one works it out again.
          await window.__zm.setEditor("a\n\tb\n");
          ind.afterReload = window.__zm.indentState().kind;
          // An explicit preference ignores what the document uses, and the width
          // is both what goes in and how wide a tab is drawn.
          await window.__zm.setIndentPref("space", 2);
          await window.__zm.setEditor("a\n\tb\n");
          ind.forcedKind = window.__zm.indentState().kind;
          ind.tabSize = String(window.__zm.indentState().tabSize);
          edI.setSelectionRange(0, 0);
          pressTabI(false);
          await new Promise(function (r) { setTimeout(r, 400); });
          ind.widthTyped = edI.value;
          // Shift+Tab takes that same level straight back off.
          edI.setSelectionRange(2, 2);
          pressTabI(true);
          await new Promise(function (r) { setTimeout(r, 400); });
          ind.widthOutdented = edI.value;
          // Settings go to disk the moment they change, but a control being
          // dragged is collapsed into one write; leave a gap so this one cannot
          // be deferred past the check that reads the file back.
          await new Promise(function (r) { setTimeout(r, 600); });
          var kept = await window.__zm.setIndentPref("space", 3);
          ind.savedPref = kept.pref;
          ind.savedWidth = kept.width;
        } catch (e) { ind.error = String(e); }
        await window.selfTestReport({ html: html, view: view, editBold: ed.text, undoText: undoText, dropText: dropText, dropUri: dropUri, dropFile: dropFile, staleOk: staleOk, find: fr, img: img, startup: startup, disk: disk, nav: nav, hint: hint, recent: recent, views: views, tab: tab, indent: ind });
      } catch (err) {
        try { window.logMsg('driver error: ' + err); } catch (x) {}
        await window.selfTestReport({ html: '', view: '', editBold: '', undoText: '', dropText: '', dropUri: '', dropFile: '', staleOk: false, find: { error: 'driver aborted' }, img: { error: 'driver aborted' }, startup: { error: 'driver aborted' }, disk: { error: 'driver aborted' }, nav: { error: 'driver aborted' }, hint: { error: 'driver aborted' }, recent: { error: 'driver aborted' }, views: { error: 'driver aborted' }, tab: { error: 'driver aborted' }, indent: { error: 'driver aborted' } });
      }
    });
  })();
  """
  let dropInit = "window.__zmDropPath = " & $(%dropPath) & ";" &
                 "window.__zmImgRel = " & $(%imgName) & ";" &
                 "window.__zmLinkA = " & $(%linkA) & ";" &
                 "window.__zmLinkB = " & $(%linkB) & ";" &
                 "window.__zmViewPath = " & $(%viewPath) & ";" &
                 "window.__zmEmptyPath = " & $(%emptyPath) & ";"
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

  for leftover in [imgPath, newPath, dropPath, linkA, linkB, app.statePath]:
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
    of "--no-gpu": forceCpu = true; launchFlags.add(arg)
    of "--gpu": forceGpu = true; launchFlags.add(arg)
    of "--verbose", "-v": verbose = true; launchFlags.add("--verbose")
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
  app.currentView = app.ui.view
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
          discard saveState(app.ui, appStatePath())
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
        var disk = loadState(appStatePath())
        disk.renderMode = app.ui.renderMode
        discard saveState(disk, appStatePath())
  if not app.exiting:
    # Window closed via the window manager rather than the Exit menu; still
    # persist state so the size/view are remembered.
    persistNow()
  discard w.destroy()
  logLine("stopped")

when isMainModule:
  main()
