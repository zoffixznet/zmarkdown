## UI state that survives across runs: window size, view mode, and the split
## divider ratio. Serialized as JSON. The pure pieces (defaults, clamping,
## config-path resolution, JSON round-trip) are unit-tested without any GUI.
##
## The previously opened file is deliberately NOT part of this state: every
## launch starts with a fresh empty document.

import std/[json, os, options, math]

type
  ViewMode* = enum
    ## The three ways to look at a document.
    vmText = "text"       ## raw editor only
    vmSplit = "split"     ## editor left, preview right
    vmPreview = "preview" ## rendered preview only

  UiState* = object
    ## Everything persisted between runs.
    width*: int           ## window width in pixels (the non-maximized size)
    height*: int          ## window height in pixels (the non-maximized size)
    maximized*: bool      ## whether the window was maximized at exit
    view*: ViewMode       ## current view mode
    splitRatio*: float    ## divider position in split mode, 0.0 .. 1.0

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
  %*{
    "width": s.width,
    "height": s.height,
    "maximized": s.maximized,
    "view": $s.view,
    "splitRatio": s.splitRatio,
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
  if node.hasKey("view") and node["view"].kind == JString:
    case node["view"].getStr()
    of "text": result.view = vmText
    of "split": result.view = vmSplit
    of "preview": result.view = vmPreview
    else: discard # keep default
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
  let p = if path.len > 0: path else: statePath()
  try:
    let dir = p.parentDir()
    if dir.len > 0 and not dirExists(dir):
      createDir(dir)
    writeFile(p, pretty(s.toJson()))
    true
  except CatchableError:
    false
