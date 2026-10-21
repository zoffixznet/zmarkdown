import std/unittest
import "../src/core/cli"

suite "files on the command line":
  test "no arguments means no files":
    let l = parseLaunch([])
    check l.files.len == 0
    check not l.showHelp and not l.showVersion

  test "one path is one file":
    check parseLaunch(["notes.md"]).files == @["notes.md"]

  test "every path is kept, in the order given":
    # `zmarkdown a b c` opens a window for each, so none may be dropped.
    check parseLaunch(["a.md", "b.md", "c.md"]).files == @["a.md", "b.md", "c.md"]

  test "paths and switches mix in any order":
    let l = parseLaunch(["--no-gpu", "a.md", "--verbose", "b.md"])
    check l.files == @["a.md", "b.md"]
    check l.forceCpu
    check l.verbose

  test "a path that looks like a switch is a file after --":
    let l = parseLaunch(["--", "-dashes.md", "--more.md"])
    check l.files == @["-dashes.md", "--more.md"]
    check l.unknown.len == 0

  test "the same path twice is two windows, not one":
    check parseLaunch(["a.md", "a.md"]).files == @["a.md", "a.md"]

  test "an empty argument is nothing, not a file":
    # `zmarkdown "$FILE"` with the variable unset must open an empty document,
    # not the current directory under the name "".
    check parseLaunch([""]).files.len == 0
    check parseLaunch(["a.md", ""]).files == @["a.md"]
    check parseLaunch(["--", ""]).files.len == 0

suite "switches":
  test "graphics overrides":
    check parseLaunch(["--no-gpu"]).forceCpu
    check parseLaunch(["--gpu"]).forceGpu
    check not parseLaunch([]).forceCpu
    check not parseLaunch([]).forceGpu

  test "verbose, long and short":
    check parseLaunch(["--verbose"]).verbose
    check parseLaunch(["-v"]).verbose

  test "debug output":
    check parseLaunch(["--debug-output"]).debugOutput
    check not parseLaunch([]).debugOutput

  test "modes that exit on their own":
    check parseLaunch(["--self-test"]).selfTest
    check parseLaunch(["--probe-gl"]).probeGl
    check parseLaunch(["--version"]).showVersion
    check parseLaunch(["--help"]).showHelp
    check parseLaunch(["-h"]).showHelp

  test "unknown switches are reported, not treated as files":
    let l = parseLaunch(["--bogus", "a.md", "-x"])
    check l.unknown == @["--bogus", "-x"]
    check l.files == @["a.md"]

suite "what the terminal gets":
  test "a plain launch is silent":
    check not parseLaunch(["a.md"]).keepsTerminalOutput(debugBuild = false)

  test "--debug-output keeps it":
    check parseLaunch(["--debug-output"]).keepsTerminalOutput(debugBuild = false)

  test "--verbose is pointless without a terminal, so it keeps it too":
    check parseLaunch(["--verbose"]).keepsTerminalOutput(debugBuild = false)

  test "the self-test reports on the terminal":
    check parseLaunch(["--self-test"]).keepsTerminalOutput(debugBuild = false)

  test "help and version print, so they keep it":
    check parseLaunch(["--help"]).keepsTerminalOutput(debugBuild = false)
    check parseLaunch(["--version"]).keepsTerminalOutput(debugBuild = false)

  test "a debug build always talks":
    check parseLaunch(["a.md"]).keepsTerminalOutput(debugBuild = true)

suite "what another window inherits":
  test "the switches, never the files":
    let l = parseLaunch(["--no-gpu", "a.md", "--verbose", "--debug-output", "b.md"])
    check l.inheritedFlags() == @["--no-gpu", "--verbose", "--debug-output"]

  test "nothing to inherit from a plain launch":
    check parseLaunch(["a.md"]).inheritedFlags().len == 0

  test "the short verbose form is passed on in its long form":
    check parseLaunch(["-v"]).inheritedFlags() == @["--verbose"]

  test "unknown switches and one-shot modes are not passed on":
    let l = parseLaunch(["--bogus", "--self-test", "--gpu"])
    check l.inheritedFlags() == @["--gpu"]

  test "a sibling window gets the switches and its one file":
    let l = parseLaunch(["--gpu", "a.md", "b.md"])
    check l.siblingArgs("b.md") == @["--gpu", "b.md"]

  test "a sibling file that starts with a dash is kept safe behind --":
    let l = parseLaunch(["--", "-a.md", "-b.md"])
    check l.siblingArgs("-b.md") == @["--", "-b.md"]

suite "file paths as given by desktops":
  test "a plain path is left alone":
    check normalizeFilePath("notes.md") == "notes.md"
    check normalizeFilePath("/abs/dir/notes.md") == "/abs/dir/notes.md"

  test "a file:// URL is turned back into a path":
    check normalizeFilePath("file:///home/me/notes.md") == "/home/me/notes.md"
    check normalizeFilePath("FILE:///home/me/notes.md") == "/home/me/notes.md"

  test "percent-escapes in a file:// URL are decoded, plus is not":
    check normalizeFilePath("file:///home/me/my%20notes.md") == "/home/me/my notes.md"
    check normalizeFilePath("file:///home/me/a+b.md") == "/home/me/a+b.md"
