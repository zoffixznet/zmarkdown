## Images in the rendered preview.
##
## The page is handed to the webview as a bare HTML string, so it has no base
## URL to resolve `![a](pictures/cat.png)` against, and a `file://` subresource
## is refused from that origin anyway. Local images are therefore served by Nim:
## this module rewrites every local `<img src=...>` in the rendered HTML into a
## `data-zm-img="<token>"` reference, and hands the page the bytes on demand
## (`imageDataUri`) as a `data:` URI. Sources the page can fetch by itself
## (`http:`, `https:`, `data:`) are left exactly as they are.
##
## A token is derived from the file's path, size, and modification time, so it
## stays the same for as long as the file does. The front end caches by token,
## which is what keeps a document with a 4 MB photo in it responsive: the bytes
## cross the bridge once, not on every keystroke that re-renders the preview.
##
## Everything here is defensive - a missing, unreadable, or absurdly large image
## turns into a placeholder with an explanation, never an exception.

import std/[base64, hashes, os, strutils, tables, times]

const
  MaxImageBytes* = 16 * 1024 * 1024
    ## Largest image inlined into the preview. The bytes cross the bridge
    ## base64-encoded, and nothing readable needs more than this.
  MaxTrackedImages = 4096
    ## Upper bound on remembered tokens, so a long session spent scrolling
    ## through image-heavy documents cannot grow the table without limit. A
    ## token is a path and a hash, so this costs a few hundred kilobytes at
    ## worst - set far above any document anyone will write, since evicting an
    ## image that is still on screen would blank it.

  MissingImageSvg = """<svg xmlns="http://www.w3.org/2000/svg" width="128" height="96" viewBox="0 0 128 96"><rect width="128" height="96" rx="6" fill="#8a8a8a" fill-opacity=".10"/><path d="M20 72 46 44l14 14 12-10 22 24z" fill="#8a8a8a" fill-opacity=".45"/><circle cx="44" cy="30" r="7" fill="#8a8a8a" fill-opacity=".45"/><path d="M28 22 100 74" stroke="#b3261e" stroke-opacity=".7" stroke-width="5" stroke-linecap="round"/></svg>"""

const missingImageUri* = "data:image/svg+xml;base64," & base64.encode(MissingImageSvg)
  ## Shown in place of an image that could not be loaded. Inline, so it needs
  ## no network and no file of its own.

type
  SrcKind* = enum
    ## What an `<img src>` points at, from this application's point of view.
    skEmpty        ## nothing usable
    skPassthrough  ## the page can load it itself (data:, http:, https:, ...)
    skLocal        ## a local file, which only Nim can read

  ImageRegistry* = object
    ## The local images the preview is currently allowed to ask for, keyed by
    ## the token embedded in the rendered HTML.
    tokens: OrderedTable[string, string]  ## token -> absolute path

func initImageRegistry*(): ImageRegistry =
  ImageRegistry(tokens: initOrderedTable[string, string]())

func len*(reg: ImageRegistry): int =
  ## Number of tracked images; used by the tests.
  reg.tokens.len

# ---- Small string helpers ---------------------------------------------------

const TagSpace = {' ', '\t', '\n', '\r', '\f', '\v'}

func hexVal(c: char): int =
  case c
  of '0' .. '9': ord(c) - ord('0')
  of 'a' .. 'f': ord(c) - ord('a') + 10
  of 'A' .. 'F': ord(c) - ord('A') + 10
  else: -1

func percentDecode*(s: string): string =
  ## Decode `%XX` escapes. The markdown renderer percent-encodes the URL it
  ## emits (a space becomes `%20`), so this is what turns it back into a path.
  ## A `%` that does not start a valid escape is kept verbatim, so a literal
  ## percent in a filename survives.
  if s.find('%') < 0:
    return s
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    if s[i] == '%' and i + 2 < s.len:
      let hi = hexVal(s[i + 1])
      let lo = hexVal(s[i + 2])
      if hi >= 0 and lo >= 0:
        result.add chr(hi * 16 + lo)
        i += 3
        continue
    result.add s[i]
    i += 1

func decodeEntities*(s: string): string =
  ## Decode the handful of HTML entities that can turn up in an attribute value
  ## (raw HTML in the document may carry them; the markdown renderer does not).
  if s.find('&') < 0:
    return s
  s.multiReplace(("&amp;", "&"), ("&#38;", "&"), ("&quot;", "\""), ("&#34;", "\""),
                 ("&apos;", "'"), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">"))

func escapeAttr*(s: string): string =
  ## Escape a string for use inside a double-quoted attribute value.
  result = newStringOfCap(s.len + 8)
  for c in s:
    case c
    of '&': result.add "&amp;"
    of '<': result.add "&lt;"
    of '>': result.add "&gt;"
    of '"': result.add "&quot;"
    else: result.add c

func schemeOf*(s: string): string =
  ## The URL scheme of `s` in lowercase, or "" when it has none. A single
  ## letter followed by a colon is a Windows drive (`C:\pics`), not a scheme.
  var i = 0
  while i < s.len and s[i] in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '+', '-', '.'}:
    i += 1
  if i < 2 or i >= s.len or s[i] != ':':
    return ""
  if s[0] notin {'a' .. 'z', 'A' .. 'Z'}:
    return ""
  s[0 ..< i].toLowerAscii()

func classifySrc*(src: string): SrcKind =
  ## Decide who loads a given `<img src>`.
  let s = src.strip()
  if s.len == 0:
    return skEmpty
  case schemeOf(s)
  of "", "file": skLocal
  else: skPassthrough  # http(s), data:, and any scheme we have no business resolving

func fileUrlToPath*(url: string): string =
  ## `file:///home/me/a.png` -> `/home/me/a.png`, `file:///C:/x.png` -> `C:/x.png`.
  var p = url
  if p.toLowerAscii().startsWith("file://"):
    p = p[7 .. ^1]
  if p.toLowerAscii().startsWith("localhost/"):
    p = p["localhost".len .. ^1]
  # A Windows path arrives as an extra leading slash: /C:/pics/a.png.
  if p.len >= 3 and p[0] == '/' and p[1] in {'a' .. 'z', 'A' .. 'Z'} and p[2] == ':':
    p = p[1 .. ^1]
  p

proc resolvePath*(src, baseDir: string): string =
  ## Turn an `<img src>` that points at the local filesystem into an absolute
  ## path, resolving a relative one against `baseDir` (the directory of the
  ## document being edited). Returns "" when there is nothing to resolve.
  var p = decodeEntities(src.strip())
  if schemeOf(p) == "file":
    p = fileUrlToPath(p)
  p = percentDecode(p)
  if p.len == 0:
    return ""
  if p.startsWith("~"):
    try: p = expandTilde(p)
    except CatchableError: discard
  if not isAbsolute(p):
    p = (if baseDir.len > 0: baseDir else: ".") / p
  try:
    p = normalizedPath(p)
    if not isAbsolute(p):
      p = absolutePath(p)
  except CatchableError:
    discard
  p

# ---- MIME types -------------------------------------------------------------

func mimeForExt*(ext: string): string =
  ## MIME type for a file extension (with or without the leading dot); "" when
  ## the extension says nothing useful.
  case ext.toLowerAscii().strip(chars = {'.'})
  of "png": "image/png"
  of "jpg", "jpeg", "jfif", "pjpeg": "image/jpeg"
  of "gif": "image/gif"
  of "webp": "image/webp"
  of "svg", "svgz": "image/svg+xml"
  of "bmp": "image/bmp"
  of "ico", "cur": "image/x-icon"
  of "avif": "image/avif"
  of "apng": "image/apng"
  of "tif", "tiff": "image/tiff"
  of "heic", "heif": "image/heic"
  of "jxl": "image/jxl"
  else: ""

func sniffMime*(data: string): string =
  ## Identify an image from its leading bytes, for files whose extension does
  ## not (or is missing altogether); "" when nothing matches.
  template starts(s: string): bool = data.len >= s.len and data[0 ..< s.len] == s
  if starts("\x89PNG\r\n\x1A\n"): "image/png"
  elif starts("\xFF\xD8\xFF"): "image/jpeg"
  elif starts("GIF87a") or starts("GIF89a"): "image/gif"
  elif data.len >= 12 and data[0 ..< 4] == "RIFF" and data[8 ..< 12] == "WEBP": "image/webp"
  elif data.len >= 12 and data[4 ..< 8] == "ftyp" and data[8 ..< 12] in ["avif", "avis"]: "image/avif"
  elif starts("BM"): "image/bmp"
  elif starts("\x00\x00\x01\x00"): "image/x-icon"
  else:
    # SVG is text: look past any leading whitespace, but only at the head of
    # the file (this runs on the whole image).
    let head = data[0 ..< min(64, data.len)].strip(trailing = false)
    if head.startsWith("<svg") or head.startsWith("<?xml"): "image/svg+xml"
    else: ""

func mimeFor*(path, data: string): string =
  ## The image's MIME type from its extension, or failing that its leading
  ## bytes. Empty when neither says "image": the preview then declines to serve
  ## the file at all, so pointing an `<img>` at a private file cannot pull its
  ## contents into the page.
  result = mimeForExt(path.splitFile().ext)
  if result.len == 0:
    result = sniffMime(data)

# ---- Tag scanning -----------------------------------------------------------

type
  AttrSpan = object
    ## Where an attribute and its value sit inside a single tag string.
    found: bool
    valStart, valEnd: int    ## the value text, without its quotes
    spanStart, spanEnd: int  ## the whole `name="value"`, for replacement

func findAttr(tag, name: string): AttrSpan =
  ## Locate an attribute inside one tag (`<img ...>`), tolerating single quotes,
  ## unquoted values, and valueless attributes, the way an HTML parser would.
  var i = 1
  while i < tag.len and tag[i] notin TagSpace + {'/', '>'}:
    i += 1  # skip the tag name
  while i < tag.len:
    while i < tag.len and tag[i] in TagSpace: i += 1
    if i >= tag.len or tag[i] == '>': break
    if tag[i] == '/':
      i += 1
      continue
    let ns = i
    while i < tag.len and tag[i] notin TagSpace + {'=', '/', '>'}: i += 1
    let ne = i
    var vs, ve = -1
    var spanEnd = ne
    var j = i
    while j < tag.len and tag[j] in TagSpace: j += 1
    if j < tag.len and tag[j] == '=':
      j += 1
      while j < tag.len and tag[j] in TagSpace: j += 1
      if j < tag.len and tag[j] in {'"', '\''}:
        let q = tag[j]
        vs = j + 1
        var k = vs
        while k < tag.len and tag[k] != q: k += 1
        ve = k
        spanEnd = min(k + 1, tag.len)
      else:
        vs = j
        var k = j
        while k < tag.len and tag[k] notin TagSpace + {'>'}: k += 1
        ve = k
        spanEnd = k
      i = spanEnd
    if i <= ns: i = ns + 1  # never stall, whatever the markup does
    if ne > ns and tag[ns ..< ne].toLowerAscii() == name:
      return AttrSpan(found: true, valStart: vs, valEnd: ve,
                      spanStart: ns, spanEnd: spanEnd)
  AttrSpan(found: false)

func isTagStart(html: string, i: int, name: string): bool =
  ## Does an opening `<name` tag start at `i`?
  if i < 0 or i >= html.len or html[i] != '<': return false
  if i + 1 + name.len > html.len: return false
  for k in 0 ..< name.len:
    if toLowerAscii(html[i + 1 + k]) != name[k]: return false
  let after = i + 1 + name.len
  after >= html.len or html[after] in TagSpace + {'/', '>'}

func tagEnd(html: string, start: int): int =
  ## Index of the `>` closing the tag that starts at `start`, ignoring any `>`
  ## inside a quoted attribute value. -1 when the tag is never closed.
  var i = start + 1
  var quote = '\0'
  while i < html.len:
    let c = html[i]
    if quote != '\0':
      if c == quote: quote = '\0'
    elif c in {'"', '\''}: quote = c
    elif c == '>': return i
    i += 1
  -1

# ---- Rewriting --------------------------------------------------------------

proc register(reg: var ImageRegistry, path: string, size: int64,
              mtime: Time): string =
  ## Remember a local image and return the token the page refers to it by. The
  ## token changes when the file does, which is what invalidates the front
  ## end's cache.
  var h: Hash = 0
  h = h !& hash(path)
  h = h !& hash(size)
  h = h !& hash(mtime.toUnix)
  h = h !& hash(mtime.nanosecond)
  result = toHex(cast[uint64](!$h), 16)
  reg.tokens[result] = path
  if reg.tokens.len > MaxTrackedImages:
    var oldest = ""
    for k in reg.tokens.keys:
      oldest = k
      break
    if oldest.len > 0:
      reg.tokens.del(oldest)

func missingAttrs(reason: string): string =
  ## The `src`/`data-zm-missing` pair that replaces an image we cannot show.
  "src=\"" & missingImageUri & "\" data-zm-missing=\"" & escapeAttr(reason) & "\""

proc statImage(path: string): tuple[info: FileInfo, ok: bool] =
  ## Stat a candidate image. `ok` means an ordinary file with something in it.
  ## A directory is obviously not an image; neither is a device or a FIFO, which
  ## `kind` still calls a file (`isSpecial` is the bit that tells them apart) and
  ## which would read forever if handed to readFile.
  try:
    let info = getFileInfo(path)
    (info, info.kind in {pcFile, pcLinkToFile} and not info.isSpecial and
           info.size > 0)
  except CatchableError:
    var none: FileInfo
    (none, false)

proc rewriteImgTag(tag, baseDir: string, reg: var ImageRegistry): string =
  ## Rewrite one `<img ...>` tag. Anything the page can load itself is returned
  ## untouched.
  let a = findAttr(tag, "src")
  if not a.found or a.valStart < 0 or a.valEnd < a.valStart:
    return tag
  let raw = tag[a.valStart ..< a.valEnd]
  if classifySrc(raw) != skLocal:
    return tag
  var path = resolvePath(raw, baseDir)
  var st = statImage(path)
  if not st.ok:
    # Documents copied from the web carry URL decoration on an image name
    # (GitHub's `logo.png#gh-dark-mode-only`). Drop it and try the plain name -
    # but only after the name exactly as written has had its chance, so a file
    # that really does contain a `#` still wins.
    let cut = raw.find({'#', '?'})
    if cut > 0:
      let bare = resolvePath(raw[0 ..< cut], baseDir)
      let bareSt = statImage(bare)
      if bareSt.ok:
        path = bare
        st = bareSt
  var replacement: string
  if path.len == 0 or not st.ok:
    replacement = missingAttrs("Image not found: " &
      (if path.len > 0: path else: decodeEntities(raw)))
  elif st.info.size > MaxImageBytes:
    replacement = missingAttrs("Image too large to preview (" &
      formatSize(st.info.size) & "): " & path)
  else:
    replacement = "data-zm-img=\"" &
      reg.register(path, st.info.size, st.info.lastWriteTime) & "\""
  tag[0 ..< a.spanStart] & replacement & tag[a.spanEnd .. ^1]

func hasImgTag(html: string): bool =
  ## Whether the fragment contains an `<img` tag at all, without allocating.
  var i = 0
  while i < html.len:
    let lt = html.find('<', i)
    if lt < 0: return false
    if isTagStart(html, lt, "img"): return true
    i = lt + 1
  false

proc rewriteImages*(html, baseDir: string, reg: var ImageRegistry): string =
  ## Rewrite every local image in a rendered HTML fragment so the page can show
  ## it. `baseDir` is the directory relative paths are resolved against - the
  ## open document's own directory.
  if not hasImgTag(html):
    return html  # the overwhelmingly common case: no copy, no scanning
  result = newStringOfCap(html.len + 64)
  var i = 0
  while i < html.len:
    let lt = html.find('<', i)
    if lt < 0:
      result.add html[i .. ^1]
      break
    let close = if isTagStart(html, lt, "img"): tagEnd(html, lt) else: -1
    if close >= 0:
      result.add html[i ..< lt]
      result.add rewriteImgTag(html[lt .. close], baseDir, reg)
      i = close + 1
    else:
      # Not an image, or a tag left open by an unbalanced quote in raw HTML:
      # copy the `<` and keep scanning, so one malformed tag cannot cost the
      # images that come after it.
      result.add html[i .. lt]
      i = lt + 1

# ---- Serving ----------------------------------------------------------------

proc imageDataUri*(reg: ImageRegistry, token: string): tuple[uri, error: string] =
  ## The bytes of a registered image as a `data:` URI. On failure the URI is
  ## empty and `error` says why, in words fit for a tooltip: the token is
  ## unknown, or the file has been deleted, grown, or turned into something
  ## that is not an image since it was registered.
  if token.len == 0:
    return ("", "This image is no longer available")
  let path = reg.tokens.getOrDefault(token, "")
  if path.len == 0:
    return ("", "This image is no longer available")
  # Re-checked rather than trusted: the file may have changed since the render.
  let st = statImage(path)
  if not st.ok:
    return ("", "Image could not be read: " & path)
  if st.info.size > MaxImageBytes:
    return ("", "Image too large to preview (" & formatSize(st.info.size) & ")")
  var data = ""
  try:
    data = readFile(path)
  except CatchableError as e:
    return ("", "Image could not be read: " & e.msg)
  if data.len == 0 or data.len > MaxImageBytes:
    return ("", "Image could not be read: " & path)
  let mime = mimeFor(path, data)
  if mime.len == 0:
    return ("", "Not an image file: " & path)
  ("data:" & mime & ";base64," & base64.encode(data), "")
