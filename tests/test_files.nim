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

  test "missing parent directories are created":
    # Launching with a path into a directory that is not there yet has to work:
    # the document opens under that name and the first save makes room for it.
    let root = getTempDir() / "zmarkdown-write-test-tree"
    removeDir(root)
    let p = root / "notes" / "today" / "plan.md"
    let r = writeTextFile(p, "# plan")
    check r.ok
    check fileExists(p)
    check readFile(p) == "# plan"
    removeDir(root)

  test "writing to an unwritable path returns a failure, does not raise":
    # A regular file where a directory would have to be: nothing can be created
    # underneath it, so neither the directory nor the write can succeed.
    let blocker = getTempDir() / "zmarkdown-write-blocker.txt"
    writeFile(blocker, "x")
    let r = writeTextFile(blocker / "sub" / "file.txt", "x")
    check not r.ok
    check r.error.len > 0
    removeFile(blocker)
