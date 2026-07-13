import std/unittest
import std/os
import "../src/core/files"

suite "read":
  test "reads an existing file":
    let p = getTempDir() / "zmarkdown-read-test.txt"
    writeFile(p, "hello\nworld")
    let r = readTextFile(p)
    check r.ok
    check r.value == "hello\nworld"
    removeFile(p)

  test "missing file returns a failure, does not raise":
    let r = readTextFile(getTempDir() / "zmarkdown-nope-99999.txt")
    check not r.ok
    check r.error.len > 0

suite "write":
  test "writes a file":
    let p = getTempDir() / "zmarkdown-write-test.txt"
    if fileExists(p): removeFile(p)
    let r = writeTextFile(p, "content here")
    check r.ok
    check readFile(p) == "content here"
    removeFile(p)

  test "writing to an unwritable path returns a failure, does not raise":
    # A path whose parent directory does not exist cannot be written.
    let r = writeTextFile("/this/path/does/not/exist/file.txt", "x")
    check not r.ok
    check r.error.len > 0
