## UI state that survives across runs: window size, view mode, and the split
## divider ratio. Serialized as JSON. The pure pieces (defaults, clamping,
## config-path resolution, JSON round-trip) are unit-tested without any GUI.
##
## The previously opened file is deliberately NOT part of this state: every
## launch starts with a fresh empty document.

import std/[json, os, options, math]

import recent
import viewmode
import indent
export viewmode
export indent

type
  UiState* = object
    ## Everything persisted between runs.
    width*: int           ## window width in pixels (the non-maximized size)
    height*: int          ## window height in pixels (the non-maximized size)
    maximized*: bool      ## whether the window was maximized at exit
    view*: ViewMode       ## the view mode last chosen by hand. Files reopen in
                          ## the view each was last read in (kept per file in
                          ## `recentFiles`); this is the fallback for everything
                          ## that has no view of its own - a document with no
                          ## file behind it yet, and every file at all while the
                          ## remembering is switched off.
    splitRatio*: float    ## divider position in split mode, 0.0 .. 1.0
    fontChoice*: string   ## settings: font key ("" = the built-in per-pane fonts)
    bgColor*: string      ## settings: background color hex ("" = theme default)
    textColor*: string    ## settings: text color hex ("" = theme default)
    renderMode*: string   ## cached graphics probe verdict: "" (not probed yet),
                          ## "gpu" (3D acceleration works), or "cpu" (render in
                          ## software; e.g. a VM without 3D). Kept fresh by a
                          ## background re-probe on every launch.
    indentPref*: IndentPref ## settings: what Tab puts in - a tab, spaces, or
                          ## whichever the open document already uses
    tabWidth*: int        ## settings: how many spaces one level of indentation
                          ## is, and how wide a tab is drawn
    recentEnabled*: bool  ## settings: whether opened files are remembered at all
    recentFiles*: seq[RecentFile] ## recently opened files, newest first: an
                          ## absolute path each, with the view it was last read in

const
  # Sane minimums so a tiny saved size cannot make the window unusable.
  MinWidth* = 480
  MinHeight* = 360
  DefaultWidth* = 1000
  DefaultHeight* = 720
  DefaultSplitRatio* = 0.5
  # Absolute ceiling used only when the current screen size is unknown.
  MaxWidth* = 32767
  MaxHeight* = 32767

func defaultState*(): UiState =
  ## The state used on first run or whenever a saved state is missing or bad.
  UiState(
    width: DefaultWidth,
    height: DefaultHeight,
    maximized: false,
    view: vmSplit,
    splitRatio: DefaultSplitRatio,
    fontChoice: "",
    bgColor: "",
    textColor: "",
    renderMode: "",
    indentPref: DefaultIndentPref,
    tabWidth: DefaultTabWidth,
    recentEnabled: true,
    recentFiles: @[],
  )

func clampRatio*(r: float): float =
  ## Keep the divider ratio in [0, 1]. Fully collapsed panes (0 or 1) are allowed
  ## by design.
  if r.classify in {fcNan}: DefaultSplitRatio
  elif r < 0.0: 0.0
  elif r > 1.0: 1.0
  else: r

func clampSize*(width, height, screenW, screenH: int): tuple[w, h: int] =
  ## Clamp a saved size so it is never smaller than the sane minimum and never
  ## larger than the current screen. A size saved on a bigger display cannot end
  ## up exceeding a smaller current screen. Pass a non-positive screen dimension
  ## when the screen size is unknown, in which case only the minimum and the
  ## absolute ceiling apply.
  let
    maxW = if screenW > 0: screenW else: MaxWidth
    maxH = if screenH > 0: screenH else: MaxHeight
    # Guard against a minimum that exceeds a very small screen: the screen wins.
    loW = min(MinWidth, maxW)
    loH = min(MinHeight, maxH)
  var w = width
  var h = height
  if w < loW: w = loW
  if w > maxW: w = maxW
  if h < loH: h = loH
  if h > maxH: h = maxH
  (w, h)

func normalized*(s: UiState): UiState =
  ## Return a copy with all fields forced into sane ranges. Used after loading
  ## untrusted JSON.
  result = s
  result.splitRatio = clampRatio(s.splitRatio)
  # Size is clamped against the screen separately at restore time via clampSize;
  # here we only enforce the lower bound so a corrupt tiny value is repaired.
  if result.width < MinWidth: result.width = MinWidth
  if result.height < MinHeight: result.height = MinHeight
  result.tabWidth = clampTabWidth(s.tabWidth)
  result.recentFiles = sanitizeRecent(s.recentFiles)

proc configDir*(): string =
  ## Resolve the per-user config directory for ZMarkdown.
  ## Linux: `$XDG_CONFIG_HOME/zmarkdown` (default `~/.config/zmarkdown`).
  ## Windows: `%APPDATA%\ZMarkdown`.
  when defined(windows):
    let appData = getEnv("APPDATA")
    if appData.len > 0:
      appData / "ZMarkdown"
    else:
      getHomeDir() / "ZMarkdown"
  else:
    let xdg = getEnv("XDG_CONFIG_HOME")
    if xdg.len > 0:
      xdg / "zmarkdown"
    else:
      getHomeDir() / ".config" / "zmarkdown"

proc statePath*(): string =
  ## Full path to the state file.
  configDir() / "state.json"

func toJson*(s: UiState): JsonNode =
  ## Serialize state to JSON.
  var recent = newJArray()
  for f in s.recentFiles:
    # The view is written only when there is one to write, so an entry that
    # nothing is known about stays visibly different from one that was read in
    # Split - and reads back that way in a later run.
    var entry = %*{"path": f.path}
    if f.view.isSome: entry["view"] = %($f.view.get)
    recent.add(entry)
  %*{
    "width": s.width,
    "height": s.height,
    "maximized": s.maximized,
    "view": $s.view,
    "splitRatio": s.splitRatio,
    "fontChoice": s.fontChoice,
    "bgColor": s.bgColor,
    "textColor": s.textColor,
    "renderMode": s.renderMode,
    "indentPref": $s.indentPref,
    "tabWidth": s.tabWidth,
    "recentEnabled": s.recentEnabled,
    "recentFiles": recent,
  }

func parseState*(node: JsonNode): UiState =
  ## Parse a JSON node into state, filling anything missing or wrong-typed from
  ## the defaults. Never raises on bad input; unknown fields are ignored.
  result = defaultState()
  if node == nil or node.kind != JObject:
    return
  if node.hasKey("width") and node["width"].kind == JInt:
    result.width = node["width"].getInt()
  if node.hasKey("height") and node["height"].kind == JInt:
    result.height = node["height"].getInt()
  if node.hasKey("maximized") and node["maximized"].kind == JBool:
    result.maximized = node["maximized"].getBool()
  if node.hasKey("fontChoice") and node["fontChoice"].kind == JString:
    result.fontChoice = node["fontChoice"].getStr()
  if node.hasKey("bgColor") and node["bgColor"].kind == JString:
    result.bgColor = node["bgColor"].getStr()
  if node.hasKey("textColor") and node["textColor"].kind == JString:
    result.textColor = node["textColor"].getStr()
  if node.hasKey("renderMode") and node["renderMode"].kind == JString:
    # Only the known verdicts; anything else means "probe again".
    if node["renderMode"].getStr() in ["gpu", "cpu"]:
      result.renderMode = node["renderMode"].getStr()
  if node.hasKey("indentPref") and node["indentPref"].kind == JString:
    let p = parseIndentPref(node["indentPref"].getStr())
    if p.isSome: result.indentPref = p.get # anything else keeps the default
  if node.hasKey("tabWidth") and node["tabWidth"].kind == JInt:
    result.tabWidth = node["tabWidth"].getInt()
  if node.hasKey("recentEnabled") and node["recentEnabled"].kind == JBool:
    result.recentEnabled = node["recentEnabled"].getBool()
  if node.hasKey("recentFiles") and node["recentFiles"].kind == JArray:
    # Anything in there that is not a path, or an object with one, is dropped
    # rather than allowed to poison the list.
    var files: seq[RecentFile]
    for item in node["recentFiles"]:
      case item.kind
      of JString:
        # Written before views were remembered per file: a bare path, and no
        # claim about the view it was read in.
        files.add recentFile(item.getStr())
      of JObject:
        if item.hasKey("path") and item["path"].kind == JString:
          var view = none(ViewMode)
          if item.hasKey("view") and item["view"].kind == JString:
            view = parseViewMode(item["view"].getStr())
          files.add recentFile(item["path"].getStr(), view)
      else: discard
    result.recentFiles = files
  if node.hasKey("view") and node["view"].kind == JString:
    let v = parseViewMode(node["view"].getStr())
    if v.isSome: result.view = v.get # anything else keeps the default
  if node.hasKey("splitRatio") and node["splitRatio"].kind in {JFloat, JInt}:
    result.splitRatio = node["splitRatio"].getFloat()
  result = result.normalized()

proc loadStateFromString*(s: string): Option[UiState] =
  ## Parse a JSON string into state. Returns none on invalid JSON so the caller
  ## can fall back to defaults. Never raises.
  if s.len == 0:
    return none(UiState)
  try:
    let node = parseJson(s)
    some(parseState(node))
  except CatchableError:
    none(UiState)

proc loadState*(path = ""): UiState =
  ## Load state from disk, falling back to defaults if the file is missing,
  ## unreadable, or corrupt. Never raises.
  let p = if path.len > 0: path else: statePath()
  try:
    if not fileExists(p):
      return defaultState()
    let raw = readFile(p)
    let parsed = loadStateFromString(raw)
    if parsed.isSome:
      parsed.get()
    else:
      defaultState()
  except CatchableError:
    defaultState()

proc saveState*(s: UiState, path = ""): bool =
  ## Persist state to disk. Creates the config directory if needed. Returns true
  ## on success; on any error it returns false (the caller logs and carries on
  ## rather than failing). Never raises.
  ##
  ## The file is written beside itself and moved into place, so it is replaced
  ## in one step. Preferences are written the moment they change and several
  ## windows share this one file: a reader must never be able to catch it
  ## half-written, which would look exactly like a corrupt file and be repaired
  ## into defaults.
  let p = if path.len > 0: path else: statePath()
  try:
    let dir = p.parentDir()
    if dir.len > 0 and not dirExists(dir):
      createDir(dir)
    # The temporary name carries the process id so two windows writing at the
    # same moment cannot land on each other's half-written file.
    let tmp = p & "." & $getCurrentProcessId() & ".tmp"
    try:
      writeFile(tmp, pretty(s.toJson()))
      moveFile(tmp, p)
    except CatchableError:
      try: removeFile(tmp)
      except CatchableError: discard
      raise
    true
  except CatchableError:
    false
