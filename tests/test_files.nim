import std/unittest
import std/[os, times]
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

suite "noticing a file that changed underneath us":
  let p = getTempDir() / "zmarkdown-stamp-test.md"

  test "a file that has not moved stamps the same":
    writeFile(p, "one")
    let before = fileStamp(p)
    check before.exists
    check not changed(before, fileStamp(p))
    removeFile(p)

  test "different contents are a change":
    writeFile(p, "one")
    let before = fileStamp(p)
    writeFile(p, "something else entirely")
    check changed(before, fileStamp(p))
    removeFile(p)

  test "the same length written later is still a change":
    # Size alone would miss an edit that happens to be the same length; the
    # modification time is what catches it.
    writeFile(p, "one")
    let before = fileStamp(p)
    setLastModificationTime(p, getTime() + 5.seconds)
    check changed(before, fileStamp(p))
    removeFile(p)

  test "a file that disappeared is a change":
    writeFile(p, "one")
    let before = fileStamp(p)
    removeFile(p)
    check changed(before, fileStamp(p))

  test "a file that appeared where there was none is a change":
    if fileExists(p): removeFile(p)
    let before = fileStamp(p)
    check not before.exists
    writeFile(p, "someone else made this")
    check changed(before, fileStamp(p))
    removeFile(p)

  test "a document that was never written is never reported as changed":
    let never = getTempDir() / "zmarkdown-stamp-never.md"
    if fileExists(never): removeFile(never)
    check not changed(fileStamp(never), fileStamp(never))
    check not changed(fileStamp(""), fileStamp(""))

  test "a directory does not count as the file":
    check not fileStamp(getTempDir()).exists

suite "a path as a person would write it":
  test "a path under the home directory is written with a tilde":
    check shortenHome("/home/zed/notes.md", "/home/zed") == "~/notes.md"
    check shortenHome("/home/zed/a/b.md", "/home/zed/") == "~/a/b.md"

  test "a path outside the home directory is left alone":
    check shortenHome("/etc/hosts", "/home/zed") == "/etc/hosts"
    check shortenHome("/tmp/notes.md", "/home/zed/") == "/tmp/notes.md"

  test "a sibling that merely starts the same way is not shortened":
    # "/home/zed" must not swallow "/home/zeddy".
    check shortenHome("/home/zeddy/notes.md", "/home/zed") ==
      "/home/zeddy/notes.md"

  test "the home directory itself is left as it is":
    check shortenHome("/home/zed", "/home/zed") == "/home/zed"

  test "nothing to shorten against changes nothing":
    check shortenHome("/home/zed/x.md", "") == "/home/zed/x.md"
    check shortenHome("", "/home/zed") == ""
