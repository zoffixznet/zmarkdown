import std/unittest
import std/[json, os, options]
import "../src/core/state"

suite "defaults":
  test "default state is sane":
    let s = defaultState()
    check s.width == DefaultWidth
    check s.height == DefaultHeight
    check s.view == vmSplit
    check s.splitRatio == DefaultSplitRatio

suite "json round trip":
  test "state survives a serialize/parse cycle":
    let s = UiState(width: 1234, height: 890, view: vmPreview, splitRatio: 0.37)
    let back = parseState(s.toJson())
    check back.width == 1234
    check back.height == 890
    check back.view == vmPreview
    check abs(back.splitRatio - 0.37) < 1e-9

  test "all three view modes round trip":
    for v in [vmText, vmSplit, vmPreview]:
      let s = UiState(width: 800, height: 600, view: v, splitRatio: 0.5)
      check parseState(s.toJson()).view == v

  test "render mode verdicts round trip, junk resets to unknown":
    for m in ["", "gpu", "cpu"]:
      var s = defaultState()
      s.renderMode = m
      check parseState(s.toJson()).renderMode == m
    check parseState(parseJson("""{"renderMode": "quantum"}""")).renderMode == ""
    check parseState(parseJson("""{"renderMode": 7}""")).renderMode == ""

suite "corrupt or missing input falls back to defaults":
  test "invalid json string yields none":
    check loadStateFromString("this is not json {{{").isNone
    check loadStateFromString("").isNone

  test "loadState on a missing file returns defaults":
    let missing = getTempDir() / "zmarkdown-does-not-exist-12345.json"
    if fileExists(missing): removeFile(missing)
    let s = loadState(missing)
    check s == defaultState()

  test "empty json object yields defaults":
    let s = parseState(parseJson("{}"))
    check s == defaultState()

  test "wrong-typed fields are ignored, defaults kept":
    let s = parseState(parseJson("""{"width": "big", "view": 42, "splitRatio": "x"}"""))
    check s.width == DefaultWidth
    check s.view == vmSplit
    check s.splitRatio == DefaultSplitRatio

  test "partial json fills the rest from defaults":
    let s = parseState(parseJson("""{"view": "text"}"""))
    check s.view == vmText
    check s.width == DefaultWidth

  test "corrupt state file on disk falls back to defaults":
    let p = getTempDir() / "zmarkdown-corrupt-test.json"
    writeFile(p, "{ broken json ")
    check loadState(p) == defaultState()
    removeFile(p)

suite "size clamp and minimum":
  test "size within screen is unchanged":
    let (w, h) = clampSize(1000, 700, 1920, 1080)
    check w == 1000
    check h == 700

  test "size larger than the screen is clamped to the screen":
    let (w, h) = clampSize(4000, 3000, 1920, 1080)
    check w == 1920
    check h == 1080

  test "size below the minimum is raised to the minimum":
    let (w, h) = clampSize(100, 50, 1920, 1080)
    check w == MinWidth
    check h == MinHeight

  test "unknown screen (non-positive) only enforces minimum":
    let (w, h) = clampSize(200, 200, 0, 0)
    check w == MinWidth
    check h == MinHeight
    let (w2, h2) = clampSize(1500, 900, -1, -1)
    check w2 == 1500
    check h2 == 900

  test "a screen smaller than the minimum still fits on that screen":
    let (w, h) = clampSize(1000, 800, 300, 200)
    check w == 300
    check h == 200

suite "ratio clamp":
  test "ratio is held in 0..1, edges allowed":
    check clampRatio(-0.5) == 0.0
    check clampRatio(1.5) == 1.0
    check clampRatio(0.0) == 0.0
    check clampRatio(1.0) == 1.0
    check abs(clampRatio(0.42) - 0.42) < 1e-9

suite "config path resolution":
  test "linux uses XDG_CONFIG_HOME when set":
    when not defined(windows):
      let old = getEnv("XDG_CONFIG_HOME")
      putEnv("XDG_CONFIG_HOME", "/tmp/xdg-test")
      check configDir() == "/tmp/xdg-test/zmarkdown"
      check statePath() == "/tmp/xdg-test/zmarkdown/state.json"
      if old.len > 0: putEnv("XDG_CONFIG_HOME", old) else: delEnv("XDG_CONFIG_HOME")

  test "linux falls back to ~/.config when XDG unset":
    when not defined(windows):
      let old = getEnv("XDG_CONFIG_HOME")
      delEnv("XDG_CONFIG_HOME")
      check configDir() == getHomeDir() / ".config" / "zmarkdown"
      if old.len > 0: putEnv("XDG_CONFIG_HOME", old)

suite "save and load on disk":
  test "saving then loading returns the same state":
    let p = getTempDir() / "zmarkdown-save-test.json"
    if fileExists(p): removeFile(p)
    let s = UiState(width: 900, height: 650, view: vmText, splitRatio: 0.3)
    check saveState(s, p)
    let back = loadState(p)
    check back.width == 900
    check back.height == 650
    check back.view == vmText
    check abs(back.splitRatio - 0.3) < 1e-9
    removeFile(p)
