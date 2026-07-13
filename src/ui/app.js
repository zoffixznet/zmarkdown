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

  async function doRender() {
    try {
      const html = await window.render(editor.value);
      reading.innerHTML = html;
      lastRenderedHtml = html;
    } catch (e) {
      reading.innerHTML =
        '<div class="render-error">Preview failed: ' + escapeHtml(String(e)) + "</div>";
    }
  }

  function scheduleRender() {
    if (renderTimer) clearTimeout(renderTimer);
    renderTimer = setTimeout(doRender, 120);
  }

  function escapeHtml(s) {
    return s.replace(/[&<>"]/g, (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  }

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
    await commitHistory(); // flush any pending typing so it is its own undo step
    const text = editor.value;
    const s = editor.selectionStart;
    const e = editor.selectionEnd;
    try {
      const res = await window.applyEdit(kind, text, s, e);
      editor.value = res.text;
      editor.selectionStart = res.selStart;
      editor.selectionEnd = res.selEnd;
      editor.focus();
      markDirty();
      scheduleRender();
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

  /* ---- View modes ------------------------------------------------------ */

  function setView(view, persist) {
    currentView = view;
    app.setAttribute("data-view", view);
    for (const b of document.querySelectorAll(".viewmodes button")) {
      b.classList.toggle("active", b.getAttribute("data-view") === view);
    }
    if (view === "split") applyRatio();
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
      if (action === "open") {
        const res = await window.menuOpen(dirty, editor.value);
        if (res && res.opened) {
          editor.value = res.text;
          setTitle(res.title, false);
          await doRender();
          await resetHistory(editor.value);
          editor.focus();
        }
      } else if (action === "save") {
        const res = await window.menuSave(editor.value);
        if (res && res.saved) setTitle(res.title, false);
      } else if (action === "save-as") {
        const res = await window.menuSaveAs(editor.value);
        if (res && res.saved) setTitle(res.title, false);
      } else if (action === "settings") {
        openSettings();
      } else if (action === "exit") {
        await window.requestExit(dirty, editor.value);
      }
    } catch (e) {
      log("file action " + action + " failed: " + e);
    }
  }

  /* ---- Toolbar buttons ------------------------------------------------- */

  $("btn-bold").addEventListener("click", () => runEdit("bold"));
  $("btn-italic").addEventListener("click", () => runEdit("italic"));
  $("btn-underline").addEventListener("click", () => runEdit("underline"));
  $("btn-link").addEventListener("click", () => runEdit("link"));
  $("btn-image").addEventListener("click", () => runEdit("image"));
  btnUndo.addEventListener("click", doUndo);
  btnRedo.addEventListener("click", doRedo);

  for (const b of document.querySelectorAll(".viewmodes button")) {
    b.addEventListener("click", () => setView(b.getAttribute("data-view")));
  }

  /* ---- Editor events --------------------------------------------------- */

  editor.addEventListener("input", () => { markDirty(); scheduleRender(); scheduleCommit(); });

  editor.addEventListener("keydown", (ev) => {
    const mod = ev.ctrlKey || ev.metaKey;
    if (!mod) return;
    const k = ev.key.toLowerCase();
    if (k === "b") { ev.preventDefault(); runEdit("bold"); }
    else if (k === "i") { ev.preventDefault(); runEdit("italic"); }
    else if (k === "u") { ev.preventDefault(); runEdit("underline"); }
    else if (k === "z" && ev.shiftKey) { ev.preventDefault(); doRedo(); }
    else if (k === "z") { ev.preventDefault(); doUndo(); }
    else if (k === "y") { ev.preventDefault(); doRedo(); }
    else if (k === "s" && ev.shiftKey) { ev.preventDefault(); doFileAction("save-as"); }
    else if (k === "s") { ev.preventDefault(); doFileAction("save"); }
    else if (k === "o") { ev.preventDefault(); doFileAction("open"); }
  });

  // Also catch accelerators when focus is not in the editor.
  document.addEventListener("keydown", (ev) => {
    if (ev.target === editor) return;
    const mod = ev.ctrlKey || ev.metaKey;
    if (!mod) return;
    const k = ev.key.toLowerCase();
    if (k === "z" && ev.shiftKey) { ev.preventDefault(); doRedo(); }
    else if (k === "z") { ev.preventDefault(); doUndo(); }
    else if (k === "y") { ev.preventDefault(); doRedo(); }
    else if (k === "s" && ev.shiftKey) { ev.preventDefault(); doFileAction("save-as"); }
    else if (k === "s") { ev.preventDefault(); doFileAction("save"); }
    else if (k === "o") { ev.preventDefault(); doFileAction("open"); }
  });

  /* ---- Settings (font + background, for both panes) -------------------- */

  const settingsOverlay = $("settings-overlay");
  const setFont = $("set-font");
  const setBg = $("set-bg");
  let fontChoice = "";
  let bgColor = "";

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
  function applySettings() { applyFont(fontChoice); applyBg(bgColor); }
  function persistSettings() {
    try { if (window.saveSettings) window.saveSettings(fontChoice, bgColor); } catch (e) {}
  }
  function currentPaperHex() {
    return (getComputedStyle(document.documentElement).getPropertyValue("--paper").trim()) || "#EDEBE4";
  }

  function openSettings() {
    if (setFont) setFont.value = (fontChoice in FONT_FAMILIES) ? fontChoice : "";
    if (setBg) setBg.value = bgColor || currentPaperHex();
    settingsOverlay.hidden = false;
  }
  function closeSettings() { settingsOverlay.hidden = true; }

  if (setFont) setFont.addEventListener("change", () => {
    fontChoice = setFont.value; applyFont(fontChoice); persistSettings();
  });
  if (setBg) setBg.addEventListener("input", () => {
    bgColor = setBg.value; applyBg(bgColor); persistSettings();
  });
  $("set-reset").addEventListener("click", () => {
    fontChoice = ""; bgColor = ""; applySettings(); persistSettings();
    if (setFont) setFont.value = "";
    if (setBg) setBg.value = currentPaperHex();
  });
  $("set-close").addEventListener("click", closeSettings);
  settingsOverlay.addEventListener("mousedown", (ev) => { if (ev.target === settingsOverlay) closeSettings(); });
  window.addEventListener("keydown", (ev) => { if (ev.key === "Escape" && !settingsOverlay.hidden) closeSettings(); });

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
    window.addEventListener("mousemove", (ev) => { if (active) { curX = ev.clientX; curY = ev.clientY; } });
    window.addEventListener("keydown", stop, true);
    window.addEventListener("wheel", stop, { passive: true });
    window.addEventListener("blur", stop);
  })();

  /* ---- Startup --------------------------------------------------------- */

  async function boot() {
    try {
      const st = await window.loadInitialState();
      if (st) {
        if (typeof st.splitRatio === "number") splitRatio = st.splitRatio;
        if (st.view) currentView = st.view;
        if (typeof st.fontChoice === "string") fontChoice = st.fontChoice;
        if (typeof st.bgColor === "string") bgColor = st.bgColor;
      }
    } catch (e) { log("loadInitialState failed: " + e); }
    applySettings();
    setView(currentView, false);
    applyRatio();
    await doRender();
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
    getEditorValue: function () { return editor.value; },
    setView: function (v) { setView(v, false); return app.getAttribute("data-view"); },
    getView: function () { return app.getAttribute("data-view"); },
    runEdit: async function (kind, text, s, e) {
      editor.value = text;
      editor.selectionStart = s; editor.selectionEnd = e;
      await runEdit(kind);
      return { text: editor.value, selStart: editor.selectionStart, selEnd: editor.selectionEnd };
    },
    setRatio: function (r) { splitRatio = r; applyRatio(); return splitRatio; },
    ready: false,
  };

  // Signal readiness after boot so the self-test can wait on it.
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", () => boot().then(() => { window.__zm.ready = true; }));
  } else {
    boot().then(() => { window.__zm.ready = true; });
  }
})();
