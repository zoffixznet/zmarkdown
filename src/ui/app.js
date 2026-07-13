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

  let splitRatio = 0.5;
  let currentView = "split";
  let dirty = false;
  let renderTimer = null;
  let lastRenderedHtml = "";

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
    } catch (err) {
      log("edit " + kind + " failed: " + err);
    }
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
          editor.focus();
        }
      } else if (action === "save") {
        const res = await window.menuSave(editor.value);
        if (res && res.saved) setTitle(res.title, false);
      } else if (action === "save-as") {
        const res = await window.menuSaveAs(editor.value);
        if (res && res.saved) setTitle(res.title, false);
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

  for (const b of document.querySelectorAll(".viewmodes button")) {
    b.addEventListener("click", () => setView(b.getAttribute("data-view")));
  }

  /* ---- Editor events --------------------------------------------------- */

  editor.addEventListener("input", () => { markDirty(); scheduleRender(); });

  editor.addEventListener("keydown", (ev) => {
    const mod = ev.ctrlKey || ev.metaKey;
    if (!mod) return;
    const k = ev.key.toLowerCase();
    if (k === "b") { ev.preventDefault(); runEdit("bold"); }
    else if (k === "i") { ev.preventDefault(); runEdit("italic"); }
    else if (k === "u") { ev.preventDefault(); runEdit("underline"); }
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
    if (k === "s" && ev.shiftKey) { ev.preventDefault(); doFileAction("save-as"); }
    else if (k === "s") { ev.preventDefault(); doFileAction("save"); }
    else if (k === "o") { ev.preventDefault(); doFileAction("open"); }
  });

  /* ---- Startup --------------------------------------------------------- */

  async function boot() {
    try {
      const st = await window.loadInitialState();
      if (st) {
        if (typeof st.splitRatio === "number") splitRatio = st.splitRatio;
        if (st.view) currentView = st.view;
      }
    } catch (e) { log("loadInitialState failed: " + e); }
    setView(currentView, false);
    applyRatio();
    await doRender();
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
