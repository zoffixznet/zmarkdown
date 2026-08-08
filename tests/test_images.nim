import std/unittest
import std/[base64, os, strutils, times]
import "../src/core/images"

# A real (tiny) PNG, so the MIME sniffing and the data: URI round trip are
# exercised on actual image bytes rather than a made-up blob.
const OnePixelPngB64 =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk" &
  "+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="

let
  tmpDir = getTempDir() / "zmarkdown-test-images"
  pngPath = tmpDir / "pic.png"
  spacedPath = tmpDir / "a picture.png"
  pngBytes = base64.decode(OnePixelPngB64)

proc setup() =
  removeDir(tmpDir)
  createDir(tmpDir)
  writeFile(pngPath, pngBytes)
  writeFile(spacedPath, pngBytes)

setup()

suite "url decoding":
  test "percent escapes become the characters they stand for":
    check percentDecode("my%20pic.png") == "my pic.png"
    check percentDecode("%C3%BCn%C3%AF.png") == "ünï.png"
    check percentDecode("100%25.png") == "100%.png"

  test "a percent that is not an escape survives":
    check percentDecode("100%.png") == "100%.png"
    check percentDecode("%zz") == "%zz"
    check percentDecode("%") == "%"
    check percentDecode("a%2") == "a%2"

  test "entities in an attribute value are decoded":
    check decodeEntities("a&amp;b.png") == "a&b.png"
    check decodeEntities("q&quot;q") == "q\"q"
    check decodeEntities("plain.png") == "plain.png"
    # Only one pass: an escaped entity stays escaped.
    check decodeEntities("&amp;lt;") == "&lt;"

suite "source classification":
  test "schemes are recognized":
    check schemeOf("https://example.com/a.png") == "https"
    check schemeOf("HTTP://example.com/a.png") == "http"
    check schemeOf("data:image/png;base64,AAAA") == "data"
    check schemeOf("file:///home/me/a.png") == "file"

  test "a bare path has no scheme, and a drive letter is not one":
    check schemeOf("pic.png") == ""
    check schemeOf("./sub/pic.png") == ""
    check schemeOf("/abs/pic.png") == ""
    check schemeOf("C:/pics/a.png") == ""

  test "who loads what":
    check classifySrc("") == skEmpty
    check classifySrc("   ") == skEmpty
    check classifySrc("pic.png") == skLocal
    check classifySrc("/abs/pic.png") == skLocal
    check classifySrc("file:///abs/pic.png") == skLocal
    check classifySrc("https://example.com/a.png") == skPassthrough
    check classifySrc("http://example.com/a.png") == skPassthrough
    check classifySrc("data:image/png;base64,AAAA") == skPassthrough

suite "path resolution":
  test "a relative path resolves against the document directory":
    check resolvePath("pic.png", "/docs/notes") == "/docs/notes/pic.png".unixToNativePath
    check resolvePath("img/pic.png", "/docs") == "/docs/img/pic.png".unixToNativePath
    check resolvePath("../pic.png", "/docs/notes") == "/docs/pic.png".unixToNativePath

  test "an absolute path is kept":
    check resolvePath("/docs/pic.png", "/elsewhere") == "/docs/pic.png".unixToNativePath

  test "percent escapes are undone before the path is used":
    check resolvePath("a%20b.png", "/docs") == "/docs/a b.png".unixToNativePath

  test "a leading ~ is expanded":
    check resolvePath("~/pic.png", "/docs") == getHomeDir() / "pic.png"

  test "a file URL becomes a plain path":
    check resolvePath("file:///docs/pic.png", "/elsewhere") ==
      "/docs/pic.png".unixToNativePath

  test "nothing to resolve":
    check resolvePath("", "/docs") == ""

suite "mime types":
  test "by extension":
    check mimeForExt(".png") == "image/png"
    check mimeForExt("JPG") == "image/jpeg"
    check mimeForExt(".svg") == "image/svg+xml"
    check mimeForExt(".txt") == ""

  test "by content when the extension says nothing":
    check sniffMime(pngBytes) == "image/png"
    check sniffMime("GIF89a....") == "image/gif"
    check sniffMime("  <svg xmlns=\"http://www.w3.org/2000/svg\"></svg>") == "image/svg+xml"
    check sniffMime("not an image at all") == ""

  test "extension wins, content is the fallback":
    check mimeFor("a.png", pngBytes) == "image/png"
    check mimeFor("noext", pngBytes) == "image/png"
    check mimeFor("mystery.dat", "just text") == ""

suite "rewriting a rendered fragment":
  setup:
    var reg = initImageRegistry()

  test "a local image becomes a token the page can ask for":
    let html = rewriteImages("<p><img src=\"pic.png\" alt=\"a\" /></p>", tmpDir, reg)
    check html.contains("data-zm-img=\"")
    check not html.contains("src=")
    check html.contains("alt=\"a\"")
    check html.startsWith("<p><img ")
    check reg.len == 1

  test "the token is stable while the file is, and changes when it is not":
    let first = rewriteImages("<img src=\"pic.png\">", tmpDir, reg)
    check rewriteImages("<img src=\"pic.png\">", tmpDir, reg) == first
    # Same bytes, later timestamp: still a different version of the file.
    setLastModificationTime(pngPath, getTime() + 5.seconds)
    check rewriteImages("<img src=\"pic.png\">", tmpDir, reg) != first

  test "a percent-encoded name resolves to the real file":
    let html = rewriteImages("<img src=\"a%20picture.png\" alt=\"\">", tmpDir, reg)
    check html.contains("data-zm-img=\"")

  test "an absolute path works too":
    let html = rewriteImages("<img src=\"" & pngPath & "\">", "", reg)
    check html.contains("data-zm-img=\"")

  test "a missing file becomes a placeholder that explains itself":
    let html = rewriteImages("<img src=\"nope.png\" alt=\"x\">", tmpDir, reg)
    check html.contains("data-zm-missing=\"Image not found:")
    check html.contains("src=\"data:image/svg+xml;base64,")
    check html.contains("alt=\"x\"")
    check reg.len == 0

  test "a directory is not an image":
    let html = rewriteImages("<img src=\".\">", tmpDir, reg)
    check html.contains("data-zm-missing=")

  test "an empty file is not an image":
    # Also the guard that keeps a device or a FIFO (which report no size and
    # would read forever) away from readFile.
    let empty = tmpDir / "empty.png"
    writeFile(empty, "")
    check rewriteImages("<img src=\"empty.png\">", tmpDir, reg)
      .contains("data-zm-missing=")
    removeFile(empty)

  test "a device is not an image, whatever the document calls it":
    # Nim reports a FIFO or device as a "file"; handing one to readFile would
    # never return. Only ordinary files get through.
    when defined(posix):
      if fileExists("/dev/zero"):
        check rewriteImages("<img src=\"/dev/zero\">", tmpDir, reg)
          .contains("data-zm-missing=")

  test "a URL fragment on the name is dropped when the plain name is the file":
    # GitHub's light/dark trick: ![logo](pic.png#gh-dark-mode-only).
    let html = rewriteImages("<img src=\"pic.png#gh-dark-mode-only\">", tmpDir, reg)
    check html.contains("data-zm-img=\"")

  test "a name that really contains the fragment character still wins":
    let odd = tmpDir / "hash#name.png"
    writeFile(odd, pngBytes)
    let html = rewriteImages("<img src=\"hash%23name.png\">", tmpDir, reg)
    check html.contains("data-zm-img=\"")
    removeFile(odd)

  test "an image too large to inline says so":
    let big = tmpDir / "huge.png"
    # Sparse: the size is what matters, not the bytes.
    var f = open(big, fmWrite)
    f.setFilePos(MaxImageBytes + 1)
    f.write("x")
    f.close()
    let html = rewriteImages("<img src=\"huge.png\">", tmpDir, reg)
    check html.contains("data-zm-missing=\"Image too large to preview")
    removeFile(big)

  test "remote and inline sources are left alone":
    for src in ["https://example.com/a.png", "http://example.com/a.png",
                "data:image/png;base64,AAAA"]:
      let tag = "<p><img src=\"" & src & "\" alt=\"a\" /></p>"
      check rewriteImages(tag, tmpDir, reg) == tag

  test "raw HTML with single quotes and extra attributes is handled":
    let html = rewriteImages(
      "<img class='hero' src='pic.png' width=200 alt='a'>", tmpDir, reg)
    check html.contains("data-zm-img=\"")
    check html.contains("class='hero'")
    check html.contains("width=200")
    check not html.contains("src=")

  test "surrounding markup and text are preserved":
    let html = rewriteImages(
      "before <b>x</b> <img src=\"pic.png\"> after <em>y</em>", tmpDir, reg)
    check html.startsWith("before <b>x</b> <img ")
    check html.endsWith("> after <em>y</em>")

  test "a gallery keeps every one of its images reachable":
    # The registry describes the newest render, so no picture is forgotten
    # while it is still on the page, however many the document holds.
    var frag = ""
    var names: seq[string]
    for i in 0 ..< 600:
      let name = "gallery" & $i & ".png"
      names.add(name)
      writeFile(tmpDir / name, pngBytes)
      frag.add "<img src=\"" & name & "\">"
    let html = rewriteImages(frag, tmpDir, reg)
    check reg.len == 600
    check html.count("data-zm-img=") == 600
    # Both ends of the document resolve, not just the tail.
    let key = "data-zm-img=\""
    let firstTok = html[html.find(key) + key.len ..< html.find('"', html.find(key) + key.len)]
    let lastStart = html.rfind(key) + key.len
    let lastTok = html[lastStart ..< html.find('"', lastStart)]
    check imageDataUri(reg, firstTok).uri.len > 0
    check imageDataUri(reg, lastTok).uri.len > 0
    # A render without them forgets them again.
    discard rewriteImages("<p>no pictures here</p>", tmpDir, reg)
    check reg.len == 0
    for name in names: removeFile(tmpDir / name)

  test "several images in one document":
    let html = rewriteImages(
      "<img src=\"pic.png\"><img src=\"nope.png\"><img src=\"https://x/y.png\">",
      tmpDir, reg)
    check html.count("data-zm-img=") == 1
    check html.count("data-zm-missing=") == 1
    check html.count("https://x/y.png") == 1

  test "tags that only look like images are untouched":
    for html in ["<p>an image</p>", "<i>x</i>", "<imgur>x</imgur>",
                 "text with a &lt;img src=\"pic.png\"&gt; mention"]:
      check rewriteImages(html, tmpDir, reg) == html

  test "an img with no src is left as it is":
    check rewriteImages("<img alt=\"a\">", tmpDir, reg) == "<img alt=\"a\">"

  test "malformed markup never loses text":
    # An unterminated tag: everything from it is passed through verbatim.
    check rewriteImages("ok <img src=\"pic.png\"", tmpDir, reg) ==
      "ok <img src=\"pic.png\""

  test "one unclosed tag does not cost the images after it":
    # An unbalanced quote swallows its own tag's terminator; scanning has to
    # carry on rather than abandon the rest of the document.
    let html = rewriteImages(
      "<img src=\"a.png middle <img src=\"pic.png\"> end", tmpDir, reg)
    check html.contains("data-zm-img=\"")
    check html.endsWith("> end")

suite "serving the bytes":
  setup:
    var reg = initImageRegistry()

  proc tokenOf(html: string): string =
    ## Pull the token out of a rewritten tag.
    let key = "data-zm-img=\""
    let i = html.find(key)
    if i < 0: return ""
    let start = i + key.len
    let stop = html.find('"', start)
    if stop < 0: "" else: html[start ..< stop]

  test "a registered image comes back as a data URI with the real bytes":
    let token = tokenOf(rewriteImages("<img src=\"pic.png\">", tmpDir, reg))
    check token.len > 0
    let r = imageDataUri(reg, token)
    check r.error == ""
    check r.uri.startsWith("data:image/png;base64,")
    check base64.decode(r.uri[r.uri.find(',') + 1 .. ^1]) == pngBytes

  test "an unknown token gets nothing":
    check imageDataUri(reg, "").uri == ""
    check imageDataUri(reg, "0123456789ABCDEF").uri == ""
    check imageDataUri(reg, "0123456789ABCDEF").error.len > 0

  test "a file that disappeared after it was registered gets nothing":
    let gone = tmpDir / "temporary.png"
    writeFile(gone, pngBytes)
    let token = tokenOf(rewriteImages("<img src=\"temporary.png\">", tmpDir, reg))
    check token.len > 0
    removeFile(gone)
    let r = imageDataUri(reg, token)
    check r.uri == ""
    check r.error.contains("could not be read")

  test "a file that is not an image is refused, not handed to the page":
    # Pointing an <img> at a private file must not pull its contents into the
    # preview: nothing is served unless the name or the bytes say "image".
    let secret = tmpDir / "secret.key"
    writeFile(secret, "TOP SECRET KEY MATERIAL")
    let token = tokenOf(rewriteImages("<img src=\"secret.key\">", tmpDir, reg))
    check token.len > 0  # it is a readable file, so the render registers it
    let r = imageDataUri(reg, token)
    check r.uri == ""
    check r.error.startsWith("Not an image file")
    removeFile(secret)

removeDir(tmpDir)
