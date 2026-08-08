/* ZMarkdown front-end adapter.
 *
 * All real logic (text transforms, markdown rendering, file IO, state) lives in
 * Nim and is reachable through bound functions on `window`. This script only
 * reads the textarea and selection, calls those functions, and applies what
 * comes back. Every bound call returns a Promise (webview resolves them), so we
 * await them.
 *
 * Bound by Nim (see src/zmarkdown.nim):
 *   render(src)            -> HTML fragment string
 *   imageData(token)       -> {uri, error} for one local image in the preview
 *   applyEdit(kind, text, selStart, selEnd) -> {text, selStart, selEnd}
 *   loadInitialState()     -> {width,height,view,splitRatio}  (view/ratio used here)
 *   persistState(view, ratio)   (fire and forget)
 *   menuOpen(dirty, text)  -> {action, ...} for open flow
 *   menuSave(text) / menuSaveAs(text) -> {saved, title}
 *   requestExit(dirty, text) -> {exit: bool}
 *   markModified()
 *   logMsg(s)
 */

(function () {
  "use strict";

  const $ = (id) => document.getElementById(id);
  const app = $("app");
  const editor = $("editor");
  const reading = $("reading");
  const preview = $("preview");
  const divider = $("divider");
  const panes = $("panes");
  const editorPane = $("editor-pane");
  const previewPane = $("preview-pane");
  const fileMenu = $("file-menu");
  const btnFile = $("btn-file");
  const docTitle = $("doc-title");
  const btnUndo = $("btn-undo");
  const btnRedo = $("btn-redo");
  const findBar = $("findbar");
  const findInput = $("find-input");
  const replaceInput = $("replace-input");
  const findCount = $("find-count");
  const findField = findInput.closest(".find-field");
  const findNote = $("find-note");
  const findReplaceRow = $("find-replace-row");
  const btnFindExpand = $("find-expand");
  const btnFindPrev = $("find-prev");
  const btnFindNext = $("find-next");
  const btnFindCase = $("find-case");
  const btnFindWord = $("find-word");
  const btnFindClose = $("find-close");
  const btnReplaceOne = $("replace-one");
  const btnReplaceAll = $("replace-all");
  const hlInner = document.querySelector("#editor-highlights .hl-inner");

  let splitRatio = 0.5;
  let currentView = "split";
  let dirty = false;
  let renderTimer = null;
  let lastRenderedHtml = "";
  let historyTimer = null;
  let lastCommitted = "";

  function log(msg) {
    try { if (window.logMsg) window.logMsg(String(msg)); } catch (e) {}
  }

  /* ---- Render (debounced) ---------------------------------------------- */

  // Set when the document changed while the preview pane was hidden; the
  // skipped render happens when the pane next becomes visible.
  let previewStale = false;

  async function doRender() {
    // Snapshot the source: edits made while the render round-trip is in
    // flight must keep their staleness rather than be marked rendered.
    const source = editor.value;
    try {
      const html = await window.render(source);
      // Skip the DOM rebuild when the output is unchanged (e.g. edits inside
      // a construct that renders the same).
      if (html !== lastRenderedHtml) {
        reading.innerHTML = html;
        lastRenderedHtml = html;
        hydration = hydrateImages();
        // The rebuild threw away any search marks; put them back.
        if (find.open && find.target === "preview") refreshFind({ keepIndex: true });
      }
      if (editor.value === source) previewStale = false;
    } catch (e) {
      reading.innerHTML =
        '<div class="render-error">Preview failed: ' + escapeHtml(String(e)) + "</div>";
      lastRenderedHtml = null; // never matches, so the next render repaints
    }
  }

  function scheduleRender() {
    if (renderTimer) clearTimeout(renderTimer);
    // Nobody is looking at the preview in Text view: skip the whole render
    // pipeline (markdown -> bridge -> DOM) and catch up on the view switch.
    if (currentView === "text") { previewStale = true; return; }
    renderTimer = setTimeout(doRender, 120);
  }

  function escapeHtml(s) {
    return s.replace(/[&<>"]/g, (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  }

  /* ---- Images in the preview ------------------------------------------- */
  // The page is handed to the webview as a string, so it has no base URL to
  // resolve `pictures/cat.png` against and could not read the file anyway.
  // Nim replaces every local image source with a token; this redeems the token
  // for the bytes. A token encodes the file's size and timestamp, so it only
  // changes when the picture does: a document that re-renders on every
  // keystroke fetches each image once, not once per keystroke.

  const imageCache = new Map(); // token -> {promise, bytes}
  const IMAGE_CACHE_MAX_BYTES = 64 * 1024 * 1024;
  let imageCacheBytes = 0;

  // Drop the least recently wanted pictures until the cache fits its budget.
  // Bounding by bytes rather than by count is what keeps a document of many
  // small images entirely cached (so typing in it re-fetches nothing) while a
  // handful of huge ones still cannot fill the heap.
  function evictImages() {
    while (imageCacheBytes > IMAGE_CACHE_MAX_BYTES && imageCache.size > 1) {
      const oldest = imageCache.keys().next().value;
      const entry = imageCache.get(oldest);
      imageCache.delete(oldest);
      imageCacheBytes -= entry.bytes;
    }
  }

  // Caching the promise rather than its result also collapses duplicates: the
  // same picture used twice in a document is fetched once.
  function imageFor(token) {
    const hit = imageCache.get(token);
    if (hit) {
      // Touch it, so eviction takes what nobody has looked at for longest.
      imageCache.delete(token);
      imageCache.set(token, hit);
      return hit.promise;
    }
    const entry = { promise: null, bytes: 0 };
    entry.promise = (async () => {
      let res;
      try {
        const r = await window.imageData(token);
        res = { uri: (r && r.uri) || "", error: (r && r.error) || "" };
      } catch (e) {
        log("imageData failed: " + e);
        res = { uri: "", error: "Image could not be read" };
      }
      // Never remember a failure: whatever went wrong may not be wrong next
      // time, and the token would otherwise pin the placeholder for the rest
      // of the session even after the file comes back.
      if (res.error) {
        if (imageCache.get(token) === entry) imageCache.delete(token);
        return res;
      }
      if (imageCache.get(token) === entry) {
        entry.bytes = res.uri.length;
        imageCacheBytes += entry.bytes;
        evictImages();
      }
      return res;
    })();
    imageCache.set(token, entry);
    return entry.promise;
  }

  // The placeholder drawing lives in Nim (it is what a missing image already
  // gets at render time); an empty token asks for it on its own.
  let placeholderUri = "";
  async function placeholder() {
    if (!placeholderUri) placeholderUri = (await imageFor("")).uri;
    return placeholderUri;
  }

  // An image the page fetched itself can still fail: no network, a dead URL, a
  // corrupt file. Give it the same placeholder a missing local file gets rather
  // than the engine's own broken-image glyph. `error` does not bubble, so this
  // listens in the capture phase.
  reading.addEventListener("error", (ev) => {
    const el = ev.target;
    if (!el || el.tagName !== "IMG" || el.hasAttribute("data-zm-missing")) return;
    const src = el.getAttribute("src") || "";
    // An inlined image carries its whole self in the src; naming it in the
    // tooltip would be a screenful of base64, so only a real URL is quoted.
    const shown = src.startsWith("data:") ? ""
      : (src.length > 80 ? src.slice(0, 77) + "..." : src);
    el.setAttribute("data-zm-missing",
      shown ? "Image could not be loaded: " + shown : "Image could not be displayed");
    if (!el.title) el.title = el.getAttribute("data-zm-missing");
    placeholder().then((uri) => { if (uri && el.isConnected) el.src = uri; });
  }, true);

  function applyImage(el, res) {
    if (res.error) {
      el.setAttribute("data-zm-missing", res.error);
      el.removeAttribute("data-zm-img");
    }
    if (res.uri) el.src = res.uri;
    else if (res.error) {
      // Nothing came back at all (the bridge call itself failed): still show
      // the placeholder rather than an empty frame.
      placeholder().then((uri) => {
        if (uri && el.isConnected && !el.getAttribute("src")) el.src = uri;
      });
    }
    // Hovering a placeholder should say why it is one, unless the document
    // gave the image a title of its own.
    if (!el.title && el.hasAttribute("data-zm-missing")) {
      el.title = el.getAttribute("data-zm-missing");
    }
  }

  // The hydration of the latest render. A render does not wait on it - the text
  // must appear (and the caret land) without waiting on a 9 MB photo - but the
  // self-test does, so it can assert on finished images.
  let hydration = Promise.resolve();

  // Give every image in the freshly rendered preview its source. Resolves once
  // they all have one (or an explanation instead).
  function hydrateImages() {
    const pending = [];
    for (const el of reading.querySelectorAll("img[data-zm-img], img[data-zm-missing]")) {
      const token = el.getAttribute("data-zm-img");
      if (!token) {
        applyImage(el, { uri: "", error: el.getAttribute("data-zm-missing") || "" });
        continue;
      }
      pending.push(imageFor(token).then((res) => {
        // The preview may have been rebuilt while the bytes were in flight.
        if (el.isConnected) applyImage(el, res);
      }));
    }
    return pending.length ? Promise.all(pending) : Promise.resolve();
  }

  // Open links in the rendered preview in the system browser rather than letting
  // them navigate the app's own webview away. #reading persists across renders,
  // so one delegated handler covers every rendered link.
  reading.addEventListener("click", (ev) => {
    const a = ev.target.closest("a[href]");
    if (!a) return;
    const href = a.getAttribute("href") || "";
    if (/^https?:/i.test(href)) {
      ev.preventDefault();
      try { if (window.openExternal) window.openExternal(href); } catch (e) {}
    }
  });

  /* ---- Dirty / title --------------------------------------------------- */

  let baseTitle = "Untitled";

  function setTitle(name, isDirty) {
    baseTitle = name || "Untitled";
    dirty = !!isDirty;
    docTitle.innerHTML =
      (dirty ? '<span class="dirty">&#9679;</span> ' : "") + escapeHtml(baseTitle);
  }

  function markDirty() {
    if (!dirty) {
      dirty = true;
      docTitle.innerHTML = '<span class="dirty">&#9679;</span> ' + escapeHtml(baseTitle);
    }
  }

  /* ---- Editing shortcuts ----------------------------------------------- */

  async function runEdit(kind) {
    // Capture the text and selection synchronously, before any await, so nothing
    // can shift them in the async gap.
    const text = editor.value;
    const s = editor.selectionStart;
    const e = editor.selectionEnd;
    await commitHistory(); // flush any pending typing so it is its own undo step
    try {
      const res = await window.applyEdit(kind, text, s, e);
      editor.value = res.text;
      editor.selectionStart = res.selStart;
      editor.selectionEnd = res.selEnd;
      editor.focus();
      markDirty();
      scheduleRender();
      findTextReplaced(); // the markup shifted every offset after it
      await commitHistory(); // record the inserted markup as one undo step
    } catch (err) {
      log("edit " + kind + " failed: " + err);
    }
  }

  /* ---- Undo / redo ----------------------------------------------------- */
  // History lives in Nim (bounded by memory, not step count). JS captures
  // snapshots of the editor text and applies what undo/redo hand back.

  function updateHistoryButtons(state) {
    if (!state) return;
    if (btnUndo) btnUndo.disabled = !state.canUndo;
    if (btnRedo) btnRedo.disabled = !state.canRedo;
  }

  async function commitHistory() {
    if (historyTimer) { clearTimeout(historyTimer); historyTimer = null; }
    const text = editor.value;
    if (text === lastCommitted) return; // nothing new since the last commit
    lastCommitted = text;
    try {
      updateHistoryButtons(
        await window.historyRecord(text, editor.selectionStart, editor.selectionEnd));
    } catch (e) { log("historyRecord failed: " + e); }
  }

  function scheduleCommit() {
    if (historyTimer) clearTimeout(historyTimer);
    historyTimer = setTimeout(commitHistory, 400);
  }

  async function resetHistory(text) {
    lastCommitted = text;
    try {
      updateHistoryButtons(await window.historyReset(text));
    } catch (e) { log("historyReset failed: " + e); }
  }

  function applySnapshot(snap) {
    editor.value = snap.text;
    const n = snap.text.length;
    editor.selectionStart = Math.max(0, Math.min(n, snap.selStart | 0));
    editor.selectionEnd = Math.max(0, Math.min(n, snap.selEnd | 0));
    lastCommitted = snap.text; // this is now the current state; no pending commit
    markDirty();
    scheduleRender();
    editor.focus();
    updateHistoryButtons(snap);
    findTextReplaced();
  }

  async function doUndo() {
    await commitHistory(); // flush pending typing so it can be undone too
    try {
      const r = await window.historyUndo();
      if (r && r.ok) applySnapshot(r); else updateHistoryButtons(r);
    } catch (e) { log("undo failed: " + e); }
  }

  async function doRedo() {
    try {
      const r = await window.historyRedo();
      if (r && r.ok) applySnapshot(r); else updateHistoryButtons(r);
    } catch (e) { log("redo failed: " + e); }
  }

  /* ---- Find and replace ------------------------------------------------ */
  // The matching itself is Nim's (core/search): it returns UTF-16 code unit
  // offsets, which is exactly what the textarea's selection API speaks, so the
  // results can be used verbatim. This side decides WHAT to search — the
  // markdown source normally, the rendered text when Preview is all you can
  // see — then paints the matches and moves the selection.

  const find = {
    open: false,
    replaceShown: false,
    matchCase: false,
    wholeWord: false,
    target: "editor",   // "editor" (markdown source) | "preview" (rendered text)
    matches: [],        // [[start, stop], ...], UTF-16 offsets into the target
    total: 0,           // true match count, which can exceed matches.length
    capped: false,      // more matches exist than were returned
    index: -1,          // the current match, -1 when there is none
    token: 0,           // discards results of superseded searches
    timer: null,
    pending: null,      // opts of the debounced refresh, so it can be flushed
  };

  function findTargetForView(view) {
    // Preview-only hides the editor, so search what the reader can actually
    // see. Text and Split both show the source, which is what replace needs.
    return view === "preview" ? "preview" : "editor";
  }

  /* -- The editor's highlight layer -- */

  // The mirror only has to agree with the textarea on where characters land,
  // which means matching its wrap width exactly (clientWidth excludes the
  // scrollbar) and following its scroll offset.
  function syncHighlightMetrics() {
    if (!hlInner) return;
    hlInner.style.width = editor.clientWidth + "px";
    hlInner.style.transform =
      "translate(" + -editor.scrollLeft + "px, " + -editor.scrollTop + "px)";
  }

  function clearEditorHighlights() {
    if (hlInner) hlInner.textContent = "";
  }

  function renderEditorHighlights() {
    if (!hlInner) return;
    if (!find.matches.length) { clearEditorHighlights(); return; }
    const text = editor.value;
    let html = "";
    let pos = 0;
    for (let i = 0; i < find.matches.length; i++) {
      const s = find.matches[i][0], e = find.matches[i][1];
      if (s < pos || e > text.length) continue; // stale offsets: skip, never slice wrongly
      html += escapeHtml(text.slice(pos, s)) +
        (i === find.index ? '<mark class="current">' : "<mark>") +
        escapeHtml(text.slice(s, e)) + "</mark>";
      pos = e;
    }
    // The trailing zero-width space keeps a final empty line from collapsing,
    // so the mirror stays exactly as tall as the textarea's content.
    hlInner.innerHTML = html + escapeHtml(text.slice(pos)) + "​";
    syncHighlightMetrics();
  }

  function scrollEditorToCurrent() {
    const mark = hlInner && hlInner.querySelector("mark.current");
    if (!mark) return;
    // offsetTop ignores the layer's transform, so it is the match's position in
    // the unscrolled text — exactly the scrollTop that puts it at the top.
    const top = mark.offsetTop;
    const height = mark.offsetHeight;
    const view = editor.clientHeight;
    if (top < editor.scrollTop || top + height > editor.scrollTop + view) {
      editor.scrollTop = Math.max(0, top - (view - height) / 2);
    }
    syncHighlightMetrics();
  }

  /* -- The preview's highlight marks -- */

  // Every text node under #reading, with where each one starts in the
  // concatenated text. JS string offsets are UTF-16, so they line up with what
  // Nim returns without conversion.
  function previewTextMap() {
    // Markdown may carry raw HTML through, so skip the text inside elements
    // that render nothing: matching there would count invisible hits.
    const walker = document.createTreeWalker(reading, NodeFilter.SHOW_TEXT, {
      acceptNode: (n) => {
        const tag = n.parentNode && n.parentNode.nodeName;
        return (tag === "SCRIPT" || tag === "STYLE")
          ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT;
      },
    });
    const nodes = [];
    let text = "";
    let node;
    while ((node = walker.nextNode())) {
      nodes.push({ node: node, start: text.length });
      text += node.nodeValue;
    }
    return { text: text, nodes: nodes };
  }

  function clearPreviewHighlights() {
    const marks = reading.querySelectorAll("mark.zm-hit");
    if (!marks.length) return;
    for (const m of marks) {
      const parent = m.parentNode;
      while (m.firstChild) parent.insertBefore(m.firstChild, m);
      parent.removeChild(m);
    }
    reading.normalize(); // stitch the split text nodes back together
  }

  function applyPreviewHighlights() {
    clearPreviewHighlights();
    if (!find.matches.length) return;
    const map = previewTextMap();
    // Walk nodes and matches together (both are in document order) and collect
    // the piece of each match that falls inside each node. A match spanning an
    // element boundary simply becomes one mark per node it crosses.
    const perNode = new Map();
    let mi = 0;
    for (const entry of map.nodes) {
      const nStart = entry.start;
      const nEnd = nStart + entry.node.nodeValue.length;
      while (mi < find.matches.length && find.matches[mi][1] <= nStart) mi++;
      for (let k = mi; k < find.matches.length && find.matches[k][0] < nEnd; k++) {
        const s = Math.max(find.matches[k][0], nStart) - nStart;
        const e = Math.min(find.matches[k][1], nEnd) - nStart;
        if (e <= s) continue;
        if (!perNode.has(entry.node)) perNode.set(entry.node, []);
        perNode.get(entry.node).push({ s: s, e: e, cur: k === find.index });
      }
    }
    for (const [node, segs] of perNode) {
      const value = node.nodeValue;
      const frag = document.createDocumentFragment();
      let pos = 0;
      for (const seg of segs) {
        if (seg.s > pos) frag.appendChild(document.createTextNode(value.slice(pos, seg.s)));
        const mark = document.createElement("mark");
        mark.className = seg.cur ? "zm-hit current" : "zm-hit";
        mark.textContent = value.slice(seg.s, seg.e);
        frag.appendChild(mark);
        pos = seg.e;
      }
      if (pos < value.length) frag.appendChild(document.createTextNode(value.slice(pos)));
      if (node.parentNode) node.parentNode.replaceChild(frag, node);
    }
    const current = reading.querySelector("mark.zm-hit.current");
    if (current) current.scrollIntoView({ block: "center", inline: "nearest" });
  }

  /* -- Painting, selection, and the bar's own state -- */

  function paintMatches() {
    if (find.target === "editor") {
      clearPreviewHighlights();
      renderEditorHighlights();
    } else {
      clearEditorHighlights();
      applyPreviewHighlights();
    }
  }

  function selectCurrentMatch() {
    if (find.index < 0 || find.index >= find.matches.length) return;
    if (find.target !== "editor") return; // the preview scrolls its mark instead
    const m = find.matches[find.index];
    try { editor.setSelectionRange(m[0], m[1]); } catch (e) {}
    scrollEditorToCurrent();
  }

  function updateFindUi() {
    const query = findInput.value;
    const n = find.matches.length;
    findField.classList.toggle("none", query.length > 0 && find.total === 0);
    if (!query.length) findCount.textContent = "";
    else if (find.total === 0) findCount.textContent = "No results";
    else findCount.textContent = (find.index + 1) + " / " + find.total;
    findCount.title = find.capped
      ? "Only the first " + n + " of " + find.total + " matches are highlighted."
      : "";
    btnFindPrev.disabled = n === 0;
    btnFindNext.disabled = n === 0;
    const canReplace = find.target === "editor";
    replaceInput.disabled = !canReplace;
    btnReplaceOne.disabled = !canReplace || n === 0;
    btnReplaceAll.disabled = !canReplace || n === 0;
    findNote.textContent = canReplace
      ? (find.capped ? "First " + n + " matches shown" : "")
      : "Searching the rendered text";
  }

  async function refreshFind(opts) {
    opts = opts || {};
    const query = findInput.value;
    const token = ++find.token;
    if (!find.open || !query.length) {
      find.matches = []; find.total = 0; find.capped = false; find.index = -1;
      clearEditorHighlights();
      clearPreviewHighlights();
      updateFindUi();
      return;
    }
    const haystack = find.target === "preview" ? previewTextMap().text : editor.value;
    let res = null;
    try {
      res = await window.searchFind(haystack, query, find.matchCase, find.wholeWord);
    } catch (e) {
      log("searchFind failed: " + e);
    }
    // A later search (or a close) overtook this one: drop the stale answer.
    if (token !== find.token || !find.open) return;
    const flat = (res && res.offsets) || [];
    const matches = [];
    for (let i = 0; i + 1 < flat.length; i += 2) matches.push([flat[i], flat[i + 1]]);
    find.matches = matches;
    find.total = (res && res.total) || 0;
    find.capped = !!(res && res.capped);
    if (!matches.length) {
      find.index = -1;
    } else if (opts.keepIndex && find.index >= 0) {
      find.index = Math.min(find.index, matches.length - 1);
    } else {
      // Start from where the user is: the first match at or after the caret,
      // wrapping to the top when there is none below it.
      const anchor = typeof opts.anchor === "number" ? opts.anchor
        : (find.target === "editor"
            ? Math.min(editor.selectionStart, editor.selectionEnd) : 0);
      let i = -1;
      for (let k = 0; k < matches.length; k++) {
        if (matches[k][0] >= anchor) { i = k; break; }
      }
      find.index = i < 0 ? 0 : i;
    }
    paintMatches();
    if (opts.select !== false) selectCurrentMatch();
    updateFindUi();
  }

  function findState() {
    return {
      open: find.open,
      target: find.target,
      total: find.total,
      shown: find.matches.length,
      index: find.index,
      capped: find.capped,
      count: findCount.textContent,
      editorMarks: hlInner ? hlInner.querySelectorAll("mark").length : 0,
      previewMarks: reading.querySelectorAll("mark.zm-hit").length,
      // What the preview actually marked: proves the rendered text was searched
      // with rendered offsets, not the source's.
      previewMarkText: (function () {
        const m = reading.querySelector("mark.zm-hit.current");
        return m ? m.textContent : "";
      })(),
      selStart: editor.selectionStart,
      selEnd: editor.selectionEnd,
      selected: editor.value.slice(editor.selectionStart, editor.selectionEnd),
      text: editor.value,
    };
  }

  function scheduleFindRefresh(opts) {
    if (find.timer) clearTimeout(find.timer);
    find.pending = opts;
    find.timer = setTimeout(() => { find.timer = null; refreshFind(find.pending); }, 90);
  }

  // Run a debounced refresh right now. Pressing Enter straight after typing
  // must step through the matches of what was just typed, not the previous
  // query's list.
  function flushFindRefresh() {
    if (!find.timer) return Promise.resolve();
    clearTimeout(find.timer);
    find.timer = null;
    return refreshFind(find.pending);
  }

  function gotoMatch(delta) {
    const n = find.matches.length;
    if (!n) return;
    find.index = ((find.index + delta) % n + n) % n;
    paintMatches();
    selectCurrentMatch();
    updateFindUi();
  }

  function showReplaceRow(on) {
    find.replaceShown = on;
    findReplaceRow.hidden = !on;
    btnFindExpand.setAttribute("aria-expanded", on ? "true" : "false");
    syncHighlightMetrics();
  }

  function openFind(withReplace) {
    // Replace edits the source, which Preview-only does not show: move to Split
    // so there is something to replace in.
    if (withReplace && currentView === "preview") setView("split");
    const wasOpen = find.open;
    find.open = true;
    findBar.hidden = false;
    find.target = findTargetForView(currentView);
    if (withReplace) showReplaceRow(true);
    // Bring the controls in line with the target NOW, not after the search
    // round trip: a disabled input cannot take focus, so the replace box would
    // otherwise stay unfocusable and the replacement text would land in the
    // find box instead.
    updateFindUi();
    // Seed from the editor selection, the way every editor does — but only on
    // a fresh open. Re-opening would otherwise overwrite the query being typed
    // with the match this controller itself selected.
    if (!wasOpen && find.target === "editor") {
      const sel = editor.value.slice(editor.selectionStart, editor.selectionEnd);
      if (sel.length > 0 && sel.length <= 200 && sel.indexOf("\n") < 0) {
        findInput.value = sel;
      }
    }
    // Ctrl+H with something already in the find box means "I know what I am
    // looking for, let me type what it becomes": focus the replacement instead.
    const focusEl = withReplace && findInput.value.length > 0 ? replaceInput : findInput;
    focusEl.focus();
    focusEl.select();
    syncHighlightMetrics();
    return refreshFind();
  }

  function closeFind() {
    if (!find.open) return;
    find.open = false;
    find.token++; // any search still in flight must not repaint after this
    findBar.hidden = true;
    find.matches = []; find.total = 0; find.capped = false; find.index = -1;
    clearEditorHighlights();
    clearPreviewHighlights();
    if (currentView !== "preview") editor.focus();
  }

  // The document was replaced wholesale (undo, redo, a file opened, New) rather
  // than typed into, so no input event fired: the matches must be recomputed or
  // the highlight layer would keep painting the old text's offsets.
  // Repaint only: the caller (undo, a freshly opened file, a formatting
  // shortcut) has just placed the caret deliberately, so the selection is left
  // exactly where it put it.
  function findTextReplaced() {
    if (find.open && find.target === "editor") {
      refreshFind({ keepIndex: true, select: false });
    }
  }

  function onFindViewChanged() {
    if (!find.open) return;
    const target = findTargetForView(currentView);
    if (target !== find.target) {
      // Leave no marks behind in the pane we are no longer searching.
      if (target === "editor") clearPreviewHighlights(); else clearEditorHighlights();
      find.target = target;
      updateFindUi(); // enable/disable the replace controls for the new target
    }
    syncHighlightMetrics();
    refreshFind({ keepIndex: true });
  }

  async function doReplaceOne() {
    if (find.target !== "editor" || !findInput.value.length) return;
    // Capture before any await, as runEdit does, so nothing shifts underneath.
    const text = editor.value;
    const s = editor.selectionStart;
    const e = editor.selectionEnd;
    await commitHistory(); // pending typing becomes its own undo step
    let res = null;
    try {
      res = await window.searchReplace(text, findInput.value, replaceInput.value,
                                       find.matchCase, find.wholeWord, s, e);
    } catch (err) {
      log("searchReplace failed: " + err);
      return;
    }
    if (res && res.replaced) {
      editor.value = res.text;
      editor.selectionStart = res.selStart;
      editor.selectionEnd = res.selEnd;
      markDirty();
      scheduleRender();
      await commitHistory(); // the replacement is one undo step
      await refreshFind({ anchor: res.selStart });
    } else {
      // The selection was not on a match: move to one, so pressing Replace
      // again does the obvious thing.
      await refreshFind({ keepIndex: true });
    }
  }

  async function doReplaceAll() {
    if (find.target !== "editor" || !findInput.value.length) return;
    const text = editor.value;
    await commitHistory();
    let res = null;
    try {
      res = await window.searchReplaceAll(text, findInput.value, replaceInput.value,
                                          find.matchCase, find.wholeWord);
    } catch (err) {
      log("searchReplaceAll failed: " + err);
      return;
    }
    if (!res || !res.replaced) return;
    editor.value = res.text;
    editor.selectionStart = res.selStart;
    editor.selectionEnd = res.selEnd;
    markDirty();
    scheduleRender();
    await commitHistory(); // every replacement together is a single undo step
    log("replaced " + res.replaced + " occurrence(s)");
    await refreshFind({ anchor: res.selStart });
  }

  /* -- Wiring -- */

  editor.addEventListener("scroll", syncHighlightMetrics);
  window.addEventListener("resize", syncHighlightMetrics);
  if (window.ResizeObserver) {
    // The editor resizes when the divider moves, the window changes, or this
    // very bar opens; the mirror's wrap width has to follow.
    new ResizeObserver(() => {
      syncHighlightMetrics();
      if (find.open && find.target === "editor") scrollEditorToCurrent();
    }).observe(editor);
  }

  $("btn-find").addEventListener("click", () => openFind(false));
  btnFindClose.addEventListener("click", closeFind);
  btnFindNext.addEventListener("click", () => gotoMatch(1));
  btnFindPrev.addEventListener("click", () => gotoMatch(-1));
  btnFindExpand.addEventListener("click", () => showReplaceRow(!find.replaceShown));
  btnReplaceOne.addEventListener("click", doReplaceOne);
  btnReplaceAll.addEventListener("click", doReplaceAll);

  btnFindCase.addEventListener("click", () => {
    find.matchCase = !find.matchCase;
    btnFindCase.setAttribute("aria-pressed", find.matchCase ? "true" : "false");
    refreshFind();
  });
  btnFindWord.addEventListener("click", () => {
    find.wholeWord = !find.wholeWord;
    btnFindWord.setAttribute("aria-pressed", find.wholeWord ? "true" : "false");
    refreshFind();
  });

  findInput.addEventListener("input", () => scheduleFindRefresh());
  findInput.addEventListener("keydown", async (ev) => {
    if (ev.key !== "Enter") return;
    ev.preventDefault();
    await flushFindRefresh();
    gotoMatch(ev.shiftKey ? -1 : 1);
  });
  replaceInput.addEventListener("keydown", (ev) => {
    if (ev.key !== "Enter") return;
    ev.preventDefault();
    if (ev.ctrlKey || ev.metaKey) doReplaceAll(); else doReplaceOne();
  });

  /* ---- View modes ------------------------------------------------------ */

  function setView(view, persist) {
    currentView = view;
    app.setAttribute("data-view", view);
    for (const b of document.querySelectorAll(".viewmodes button")) {
      b.classList.toggle("active", b.getAttribute("data-view") === view);
    }
    if (view === "split") applyRatio();
    // In Text/Preview the per-view CSS controls the panes, so clear the inline
    // flex that split mode set (otherwise a collapsed editor stays collapsed).
    else { editorPane.style.flex = ""; previewPane.style.flex = ""; }
    // Catch up on renders skipped while the preview was hidden.
    if (view !== "text" && previewStale) doRender();
    // Which pane the find bar searches follows the view.
    onFindViewChanged();
    if (persist !== false) persist_state();
  }

  /* ---- Divider --------------------------------------------------------- */

  function applyRatio() {
    // splitRatio is the fraction of width given to the editor (left) pane.
    const r = Math.max(0, Math.min(1, splitRatio));
    editorPane.style.flex = "0 0 " + (r * 100) + "%";
    previewPane.style.flex = "1 1 0";
  }

  function ratioFromClientX(clientX) {
    const rect = panes.getBoundingClientRect();
    const w = rect.width;
    if (w <= 0) return splitRatio;
    let r = (clientX - rect.left) / w;
    return Math.max(0, Math.min(1, r));
  }

  let dragging = false;

  function startDrag(clientX) {
    dragging = true;
    app.classList.add("resizing");
    divider.classList.add("dragging");
  }
  function moveDrag(clientX) {
    if (!dragging) return;
    splitRatio = ratioFromClientX(clientX);
    applyRatio();
  }
  function endDrag() {
    if (!dragging) return;
    dragging = false;
    app.classList.remove("resizing");
    divider.classList.remove("dragging");
    persist_state();
  }

  divider.addEventListener("pointerdown", (ev) => {
    ev.preventDefault();
    divider.setPointerCapture(ev.pointerId);
    startDrag(ev.clientX);
  });
  divider.addEventListener("pointermove", (ev) => moveDrag(ev.clientX));
  divider.addEventListener("pointerup", (ev) => {
    try { divider.releasePointerCapture(ev.pointerId); } catch (e) {}
    endDrag();
  });
  divider.addEventListener("pointercancel", endDrag);

  // Keyboard resize for accessibility.
  divider.addEventListener("keydown", (ev) => {
    let step = 0;
    if (ev.key === "ArrowLeft") step = -0.02;
    else if (ev.key === "ArrowRight") step = 0.02;
    else if (ev.key === "Home") { splitRatio = 0; }
    else if (ev.key === "End") { splitRatio = 1; }
    else return;
    ev.preventDefault();
    if (step) splitRatio = Math.max(0, Math.min(1, splitRatio + step));
    applyRatio();
    persist_state();
  });

  /* ---- State persistence ----------------------------------------------- */

  function persist_state() {
    try {
      if (window.persistState) window.persistState(currentView, splitRatio);
    } catch (e) {}
  }

  /* ---- File menu ------------------------------------------------------- */

  function openMenu() {
    fileMenu.classList.add("open");
    btnFile.setAttribute("aria-expanded", "true");
  }
  function closeMenu() {
    fileMenu.classList.remove("open");
    btnFile.setAttribute("aria-expanded", "false");
  }
  function toggleMenu() {
    if (fileMenu.classList.contains("open")) closeMenu(); else openMenu();
  }

  btnFile.addEventListener("click", (ev) => { ev.stopPropagation(); toggleMenu(); });
  document.addEventListener("click", (ev) => {
    if (!fileMenu.contains(ev.target) && ev.target !== btnFile) closeMenu();
  });

  fileMenu.addEventListener("click", async (ev) => {
    const b = ev.target.closest("button");
    if (!b) return;
    const action = b.getAttribute("data-action");
    closeMenu();
    await doFileAction(action);
  });

  async function doFileAction(action) {
    try {
      if (action === "new") {
        const res = await window.menuNew(dirty, editor.value);
        if (res && res.ok) {
          editor.value = "";
          setTitle(res.title, false);
          await doRender();
          await resetHistory("");
          editor.focus();
          findTextReplaced();
        }
      } else if (action === "open") {
        const res = await window.menuOpen(dirty, editor.value);
        if (res && res.opened) await loadIntoEditor(res.text, res.title);
      } else if (action === "save") {
        const res = await window.menuSave(editor.value);
        if (res && res.saved) { setTitle(res.title, false); await doRender(); }
      } else if (action === "save-as") {
        const res = await window.menuSaveAs(editor.value);
        // Saving can move the document to another folder, and relative image
        // paths are read from wherever it now lives: render again so they are.
        if (res && res.saved) { setTitle(res.title, false); await doRender(); }
      } else if (action === "settings") {
        openSettings();
      } else if (action === "exit") {
        await window.requestExit(dirty, editor.value);
      }
    } catch (e) {
      log("file action " + action + " failed: " + e);
    }
  }

  /* ---- Drag and drop a file to open it --------------------------------- */

  function fileUrlToPath(uri) {
    if (!uri || !/^file:\/\//i.test(uri)) return "";
    let p = uri.replace(/^file:\/\//i, "");
    try { p = decodeURIComponent(p); } catch (e) {}
    if (/^\/[A-Za-z]:[\/\\]/.test(p)) p = p.slice(1); // Windows: /C:/... -> C:/...
    return p;
  }

  // The first file:// URL in a uri-list / plain-text blob (skipping # comments).
  function firstFileUri(s) {
    const line = (s || "").split(/[\r\n]+/).map((x) => x.trim()).find((x) => x && !x.startsWith("#"));
    return line && /^file:\/\//i.test(line) ? line : "";
  }
  // A file:// URL out of an href/src in an HTML drag payload.
  function fileUriFromHtml(s) {
    const m = (s || "").match(/(?:href|src)\s*=\s*["']?(file:\/\/[^"'\s>]+)/i);
    return m ? m[1] : "";
  }

  async function loadIntoEditor(text, title) {
    editor.value = text;
    editor.selectionStart = editor.selectionEnd = 0; // caret at the start, not the end
    editor.scrollTop = 0;                             // show the top of the file
    setTitle(title, false);
    await doRender();
    await resetHistory(editor.value);
    editor.focus();
    findTextReplaced();
  }

  async function openDroppedPath(path) {
    log("drop: opening path " + path);
    try {
      const res = await window.openPath(dirty, editor.value, path);
      if (res && res.opened) await loadIntoEditor(res.text, res.title);
    } catch (e) { log("drop openPath failed: " + e); }
  }
  async function openDroppedFile(file) {
    try {
      const text = await file.text();
      log("drop: read content of " + (file.name || "?") + " (" + text.length + " chars)");
      const res = await window.loadDropped(dirty, editor.value, file.name || "");
      if (res && res.ok) await loadIntoEditor(text, res.title);
    } catch (e) { log("drop content read failed: " + e); }
  }

  // The native GTK drop handler (Linux) calls this with a real filesystem path,
  // since WebKitGTK does not expose the dropped file to the JS drop event.
  window.__zmDropOpen = openDroppedPath;

  // Always take over drops so the webview cannot navigate to the dropped file or
  // paste its URL. The handler is deliberately NOT async: dataTransfer (getData
  // and items) is only valid synchronously during the event, so read it all here
  // and hand the async work off.
  ["dragenter", "dragover"].forEach((t) =>
    document.addEventListener(t, (ev) => { ev.preventDefault(); }));
  document.addEventListener("drop", (ev) => {
    ev.preventDefault();
    const dt = ev.dataTransfer;
    if (!dt) return;

    const g = {};
    for (const t of ["text/uri-list", "text/plain", "URL", "text/html"]) {
      let v = ""; try { v = dt.getData(t) || ""; } catch (e) {}
      g[t] = v;
      log("drop " + t + "=[" + v.slice(0, 240) + "]");
    }
    const fileCount = dt.files ? dt.files.length : 0;
    log("drop files=" + fileCount + " types=[" + Array.from(dt.types || []).join(",") + "]");

    let uri = firstFileUri(g["text/uri-list"]) || firstFileUri(g["text/plain"]) ||
              firstFileUri(g["URL"]) || fileUriFromHtml(g["text/html"]);
    let path = fileUrlToPath(uri);
    if (!path && fileCount && dt.files[0].path) path = dt.files[0].path;

    // The drag often carries an HTML <a>. Log its href and accept it as a path,
    // whether it is a file:// URL or a bare absolute path.
    const hrefM = (g["text/html"] || "").match(/href\s*=\s*["']([^"']*)["']/i);
    log("drop html href=[" + (hrefM ? hrefM[1] : "NONE") + "] htmlLen=" + (g["text/html"] || "").length);
    if (!path && hrefM && hrefM[1]) {
      const h = hrefM[1].trim();
      if (/^file:\/\//i.test(h)) path = fileUrlToPath(h);
      else if (h[0] === "/") { try { path = decodeURIComponent(h); } catch (e) { path = h; } }
    }

    if (path) { openDroppedPath(path); return; }
    if (fileCount) { openDroppedFile(dt.files[0]); return; }

    // Async fallback: some WebKit builds expose the drag strings only via items.
    if (dt.items && dt.items.length) {
      let tried = false;
      for (const it of dt.items) {
        if (it.kind === "string" && /uri-list|text\/plain|text\/html/i.test(it.type)) {
          tried = true;
          const ty = it.type;
          it.getAsString((s) => {
            log("drop item " + ty + "=[" + (s || "").slice(0, 240) + "]");
            const u = firstFileUri(s) || (/html/i.test(ty) ? fileUriFromHtml(s) : "");
            const p = fileUrlToPath(u);
            if (p) openDroppedPath(p);
            else log("drop: item gave no file path");
          });
        }
      }
      if (tried) return;
    }
    log("drop: nothing usable");
  });

  /* ---- Toolbar buttons ------------------------------------------------- */

  $("btn-bold").addEventListener("click", () => runEdit("bold"));
  $("btn-italic").addEventListener("click", () => runEdit("italic"));
  $("btn-underline").addEventListener("click", () => runEdit("underline"));
  $("btn-link").addEventListener("click", () => runEdit("link"));
  $("btn-image").addEventListener("click", () => runEdit("image"));
  btnUndo.addEventListener("click", doUndo);
  btnRedo.addEventListener("click", doRedo);

  for (const b of document.querySelectorAll(".viewmodes button")) {
    // Recenter the divider on any mode click, so a divider dragged to an edge is
    // always recoverable just by clicking a view button.
    b.addEventListener("click", async () => {
      splitRatio = 0.5;
      const v = b.getAttribute("data-view");
      // Catch up on renders skipped in Text view BEFORE revealing the pane,
      // so it never flashes outdated content. setView's own catch-up stays
      // as the safety net for other callers.
      if (v !== "text" && previewStale) await doRender();
      setView(v);
    });
  }

  /* ---- Editor events --------------------------------------------------- */

  editor.addEventListener("input", () => {
    markDirty();
    scheduleRender();
    scheduleCommit();
    // The text moved under the matches, so recompute them — but never move the
    // selection while someone is typing: that would yank the caret onto the
    // current match and the next keystroke would overwrite it.
    if (find.open && find.target === "editor") {
      scheduleFindRefresh({ keepIndex: true, select: false });
    }
  });

  // One handler for every accelerator, wherever focus happens to be. The
  // formatting shortcuts only make sense in the editor; the rest are global.
  document.addEventListener("keydown", (ev) => {
    const mod = ev.ctrlKey || ev.metaKey;
    if (!mod) return;
    const k = (ev.key || "").toLowerCase();
    const inEditor = ev.target === editor;
    // A text field other than the editor: the find and replace boxes.
    const inTextField = !inEditor && ev.target && ev.target.tagName === "INPUT";

    if (inEditor) {
      if (k === "b") { ev.preventDefault(); runEdit("bold"); return; }
      if (k === "i") { ev.preventDefault(); runEdit("italic"); return; }
      if (k === "u") { ev.preventDefault(); runEdit("underline"); return; }
    }
    if (k === "f") { ev.preventDefault(); openFind(false); return; }
    // Ctrl+H is the editor convention for replace; in a GTK text field it would
    // otherwise delete the previous character, so it must be swallowed here.
    if (k === "h") { ev.preventDefault(); openFind(true); return; }
    // Leave a text field's own undo stack alone; Ctrl+Z there should undo the
    // typing in that box, not roll back the document.
    if (!inTextField) {
      if (k === "z" && ev.shiftKey) { ev.preventDefault(); doRedo(); return; }
      if (k === "z") { ev.preventDefault(); doUndo(); return; }
      if (k === "y") { ev.preventDefault(); doRedo(); return; }
    }
    if (k === "s" && ev.shiftKey) { ev.preventDefault(); doFileAction("save-as"); }
    else if (k === "s") { ev.preventDefault(); doFileAction("save"); }
    else if (k === "o") { ev.preventDefault(); doFileAction("open"); }
    else if (k === "n") { ev.preventDefault(); doFileAction("new"); }
  });

  /* ---- Settings (font + background, for both panes) -------------------- */

  const settingsOverlay = $("settings-overlay");
  const setFont = $("set-font");
  const setBg = $("set-bg");
  const setFg = $("set-fg");
  let fontChoice = "";
  let bgColor = "";
  let textColor = "";

  const FONT_FAMILIES = {
    "": null, // default: keep the built-in serif preview / mono editor
    serif4: '"Source Serif 4", Georgia, "Times New Roman", serif',
    plex: '"IBM Plex Mono", "SFMono-Regular", Menlo, Consolas, monospace',
    sans: 'system-ui, -apple-system, "Segoe UI", Roboto, Arial, sans-serif',
    sysserif: 'Georgia, "Times New Roman", serif',
    mono: '"SFMono-Regular", Menlo, Consolas, "Liberation Mono", monospace',
  };

  function applyFont(choice) {
    const fam = FONT_FAMILIES[choice] || null;
    const root = document.documentElement.style;
    // One chosen font drives both panes (and code); default restores the pair.
    if (fam) { root.setProperty("--serif", fam); root.setProperty("--mono", fam); }
    else { root.removeProperty("--serif"); root.removeProperty("--mono"); }
  }
  function applyBg(hex) {
    const root = document.documentElement.style;
    if (hex) root.setProperty("--paper", hex); else root.removeProperty("--paper");
  }
  function applyFg(hex) {
    // Scoped to the editor and preview only (not the toolbar) via --content-ink.
    const root = document.documentElement.style;
    if (hex) root.setProperty("--content-ink", hex); else root.removeProperty("--content-ink");
  }
  function applySettings() { applyFont(fontChoice); applyBg(bgColor); applyFg(textColor); }
  function persistSettings() {
    try { if (window.saveSettings) window.saveSettings(fontChoice, bgColor, textColor); } catch (e) {}
  }
  function cssVarHex(name, fallback) {
    return (getComputedStyle(document.documentElement).getPropertyValue(name).trim()) || fallback;
  }

  function openSettings() {
    if (setFont) setFont.value = (fontChoice in FONT_FAMILIES) ? fontChoice : "";
    if (setBg) setBg.value = bgColor || cssVarHex("--paper", "#EDEBE4");
    if (setFg) setFg.value = textColor || cssVarHex("--ink", "#1A1D24");
    settingsOverlay.hidden = false;
  }
  function closeSettings() { settingsOverlay.hidden = true; }

  if (setFont) setFont.addEventListener("change", () => {
    fontChoice = setFont.value; applyFont(fontChoice); persistSettings();
  });
  if (setBg) setBg.addEventListener("input", () => {
    bgColor = setBg.value; applyBg(bgColor); persistSettings();
  });
  if (setFg) setFg.addEventListener("input", () => {
    textColor = setFg.value; applyFg(textColor); persistSettings();
  });
  $("set-reset").addEventListener("click", () => {
    fontChoice = ""; bgColor = ""; textColor = ""; applySettings(); persistSettings();
    if (setFont) setFont.value = "";
    if (setBg) setBg.value = cssVarHex("--paper", "#EDEBE4");
    if (setFg) setFg.value = cssVarHex("--ink", "#1A1D24");
  });
  $("set-close").addEventListener("click", closeSettings);
  settingsOverlay.addEventListener("mousedown", (ev) => { if (ev.target === settingsOverlay) closeSettings(); });
  // Escape backs out of whatever is open, innermost first.
  window.addEventListener("keydown", (ev) => {
    if (ev.key !== "Escape") return;
    if (!settingsOverlay.hidden) { closeSettings(); return; }
    if (find.open) closeFind();
  });

  /* ---- Middle-click autoscroll (like a Windows browser) ---------------- */

  (function initAutoscroll() {
    const scroller = preview; // #preview is the scroll container
    const marker = $("autoscroll-marker");
    let active = false, anchorX = 0, anchorY = 0, curX = 0, curY = 0, raf = null;

    function frame() {
      if (!active) return;
      const dead = 12, factor = 0.14;
      const dy = curY - anchorY, dx = curX - anchorX;
      if (Math.abs(dy) > dead) scroller.scrollTop += (dy - Math.sign(dy) * dead) * factor;
      if (Math.abs(dx) > dead) scroller.scrollLeft += (dx - Math.sign(dx) * dead) * factor;
      raf = requestAnimationFrame(frame);
    }
    function start(x, y) {
      active = true; anchorX = curX = x; anchorY = curY = y;
      if (marker) { marker.style.left = x + "px"; marker.style.top = y + "px"; marker.classList.add("active"); }
      document.body.classList.add("autoscrolling");
      raf = requestAnimationFrame(frame);
    }
    function stop() {
      if (!active) return;
      active = false;
      if (raf) { cancelAnimationFrame(raf); raf = null; }
      if (marker) marker.classList.remove("active");
      document.body.classList.remove("autoscrolling");
    }

    // While active, any mouse press exits. Otherwise a middle press inside the
    // preview starts it. Capture phase so we win before default handling.
    document.addEventListener("mousedown", (ev) => {
      if (active) { ev.preventDefault(); stop(); return; }
      if (ev.button === 1 && scroller.contains(ev.target)) { ev.preventDefault(); start(ev.clientX, ev.clientY); }
    }, true);
    // Suppress the browser's own middle-click behavior (native autoscroll/paste).
    scroller.addEventListener("auxclick", (ev) => { if (ev.button === 1) ev.preventDefault(); });
    window.addEventListener("mousemove", (ev) => {
      if (!active) return;
      curX = ev.clientX; curY = ev.clientY;
      // The round marker follows the mouse (the real cursor is hidden while active).
      if (marker) { marker.style.left = curX + "px"; marker.style.top = curY + "px"; }
    });
    window.addEventListener("keydown", stop, true);
    window.addEventListener("wheel", stop, { passive: true });
    window.addEventListener("blur", stop);
  })();

  /* ---- Startup --------------------------------------------------------- */

  async function boot() {
    try {
      const st = await window.loadInitialState();
      if (st) {
        // Clamp the restored divider so neither pane launches fully collapsed
        // (you can still drag it all the way during a session).
        if (typeof st.splitRatio === "number") splitRatio = Math.max(0.1, Math.min(0.9, st.splitRatio));
        if (st.view) currentView = st.view;
        if (typeof st.fontChoice === "string") fontChoice = st.fontChoice;
        if (typeof st.bgColor === "string") bgColor = st.bgColor;
        if (typeof st.textColor === "string") textColor = st.textColor;
      }
    } catch (e) { log("loadInitialState failed: " + e); }
    applySettings();
    // setView applies the divider ratio when the view is split; calling
    // applyRatio here unconditionally would re-set the inline flex that
    // setView just cleared, capping the editor at the split width even in
    // Text view until a view button is clicked.
    setView(currentView, false);
    syncHighlightMetrics();
    await doRender();
    // A file passed on the command line (e.g. opened from the file manager).
    // Nim has already read it; a path that does not exist yet comes back empty
    // and is written on the first save, so the editor just shows it either way.
    try {
      const sf = await window.startupFile();
      if (sf && sf.path) {
        await loadIntoEditor(sf.text || "", sf.title || "");
        if (sf.created) log("new file " + sf.path);
      }
    } catch (e) { log("startup file open failed: " + e); }
    await resetHistory(editor.value);
    editor.focus();
    log("ui ready");
  }

  /* ---- Hooks for automated self-test ----------------------------------- */
  // These let the Nim --self-test drive the UI and read results back through
  // the bridge without a human. They are harmless in normal use.
  window.__zm = {
    setEditor: async function (text) {
      editor.value = text;
      markDirty();
      await doRender();
      return true;
    },
    getPreviewHtml: function () { return reading.innerHTML; },
    // The fragment Nim returned, before the images in it were given their
    // sources: this is what the self-test asserts the rewriting on.
    getRenderedHtml: function () { return lastRenderedHtml; },
    getEditorValue: function () { return editor.value; },
    getTitle: function () { return baseTitle; },
    // Every image in the preview, once each has either loaded or given up, so
    // the self-test can assert on what a reader would actually see.
    imagesLoaded: async function () {
      await hydration; // every image has a source before any of this waits on one
      const els = Array.from(reading.querySelectorAll("img"));
      await Promise.all(els.map((el) => el.complete ? Promise.resolve() : new Promise((done) => {
        el.addEventListener("load", done, { once: true });
        el.addEventListener("error", done, { once: true });
        setTimeout(done, 1500); // a source that never answers must not hang the test
      })));
      return els.map((el) => ({
        ok: el.naturalWidth > 0,
        src: (el.getAttribute("src") || "").slice(0, 40),
        missing: el.getAttribute("data-zm-missing") || "",
        alt: el.getAttribute("alt") || "",
      }));
    },
    setView: function (v) { setView(v, false); return app.getAttribute("data-view"); },
    getView: function () { return app.getAttribute("data-view"); },
    runEdit: async function (kind, text, s, e) {
      editor.value = text;
      editor.selectionStart = s; editor.selectionEnd = e;
      await runEdit(kind);
      return { text: editor.value, selStart: editor.selectionStart, selEnd: editor.selectionEnd };
    },
    setRatio: function (r) { splitRatio = r; applyRatio(); return splitRatio; },
    markClean: function () { setTitle(baseTitle, false); return true; },
    // Find and replace, driven step by step so the self-test can assert on the
    // state after each one rather than racing the debounce.
    findOpen: async function (withReplace) { await openFind(!!withReplace); return findState(); },
    findClose: function () { closeFind(); return findState(); },
    findQuery: async function (q, matchCase, wholeWord) {
      findInput.value = q;
      find.matchCase = !!matchCase;
      find.wholeWord = !!wholeWord;
      await refreshFind();
      return findState();
    },
    findNext: function () { gotoMatch(1); return findState(); },
    findPrev: function () { gotoMatch(-1); return findState(); },
    findReplaceOne: async function (text) {
      replaceInput.value = text;
      await doReplaceOne();
      return findState();
    },
    findReplaceAll: async function (text) {
      replaceInput.value = text;
      await doReplaceAll();
      return findState();
    },
    findState: function () { return findState(); },
    ready: false,
  };

  // Signal readiness after boot so the self-test can wait on it.
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", () => boot().then(() => { window.__zm.ready = true; }));
  } else {
    boot().then(() => { window.__zm.ready = true; });
  }
})();
