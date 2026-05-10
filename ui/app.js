const state = {
  issues: [],
  pulls: []
};

const $ = (id) => document.getElementById(id);

const API_BASE = (location.protocol === "http:" || location.protocol === "https:") ? "" : "http://localhost:8765";

async function api(path, options = {}) {
  const response = await fetch(API_BASE + path, {
    headers: { "Content-Type": "application/json" },
    ...options
  });
  const data = await response.json();
  if (!response.ok) throw new Error(data.error || "Request fehlgeschlagen");
  return data;
}

function toast(message) {
  const node = $("toast");
  node.textContent = message;
  node.classList.add("show");
  setTimeout(() => node.classList.remove("show"), 2800);
}

function setView(name) {
  document.querySelectorAll(".nav").forEach((b) => b.classList.toggle("active", b.dataset.view === name));
  document.querySelectorAll(".view").forEach((v) => v.classList.remove("active"));
  $(`${name}View`).classList.add("active");
  const titles = { graph: "Source Control Graph", issues: "TODOs", pulls: "Pull Requests" };
  $("viewTitle").textContent = titles[name] || name;
}

// ── Status & Graph ──────────────────────────────────────────────────

async function loadStatus() {
  const status = await api("/api/status");
  $("repoName").textContent = status.repo?.remote || "lokales Repository";
  $("branchBadge").textContent = status.branch || "no branch";
  $("syncBadge").textContent = `${status.ahead} ahead / ${status.behind} behind`;
  const ignored = status.ignoredData ? ` · ${status.ignoredData} ignorierte data-Dateien` : "";
  $("statusLine").textContent = status.dirty
    ? `Lokale Aenderungen vorhanden · data: ${status.dataChanges}${ignored}`
    : `Arbeitsbaum sauber${ignored}`;
}

function renderGraphItems(commits, syncEntries) {
  const graph = $("commitGraph");
  graph.innerHTML = "";

  const cutoff = new Date(Date.now() - 48 * 60 * 60 * 1000);
  const items = [
    ...commits.map((c) => ({ type: "commit", ts: new Date(c.date), data: c })),
    ...syncEntries
      .filter((l) => new Date(l.ts) >= cutoff)
      .map((l) => ({ type: "log", ts: new Date(l.ts), data: l }))
  ].sort((a, b) => b.ts - a.ts);

  items.forEach((item, i) => {
    if (item.type === "commit") {
      const row = document.createElement("div");
      row.className = "commit-row";
      if (i === 0) row.classList.add("is-first");
      if (i === items.length - 1) row.classList.add("is-last");
      row.innerHTML = `
        <div class="rail"><span class="dot"></span></div>
        <div>
          <div class="commit-subject">${escapeHtml(item.data.subject)}</div>
          <div class="commit-meta">${escapeHtml(item.data.author)} · ${new Date(item.data.date).toLocaleString()}</div>
        </div>
        <div class="commit-hash">${escapeHtml(item.data.short)}</div>
      `;
      graph.appendChild(row);
    } else {
      const row = document.createElement("div");
      row.className = "sync-row";
      const time = new Date(item.data.ts).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
      row.innerHTML = `
        <div class="rail"><span class="sync-dot ${escapeHtml(item.data.level)}"></span></div>
        <div class="sync-text">
          <span class="sync-time">${time}</span>
          ${escapeHtml(item.data.text)}
        </div>
      `;
      graph.appendChild(row);
    }
  });

  if (items.length === 0) {
    graph.innerHTML = `<div style="padding:18px;color:var(--muted)">Noch keine Aktivitaet.</div>`;
  }
}

async function loadGraph() {
  const [commits, syncLog] = await Promise.all([
    api("/api/log"),
    api("/api/sync-log").catch(() => [])
  ]);
  renderGraphItems(commits, Array.isArray(syncLog) ? syncLog : []);
}

// ── TODOs ───────────────────────────────────────────────────────────

function getTodoStatus(item) {
  if (item.state === "closed") return "closed";
  const labels = item.labels || [];
  if (labels.some((l) => (l.name || l) === "in-progress")) return "in_progress";
  return "open";
}

function renderTodos(items) {
  const target = $("issuesList");
  target.innerHTML = "";

  const showClosed = $("showClosedTodos").checked;
  const filtered = showClosed ? items : items.filter((i) => i.state === "open");

  if (!filtered.length) {
    target.innerHTML = `<div style="padding:18px;color:var(--muted)">${showClosed ? "Keine TODOs gefunden." : "Keine offenen TODOs. Super!"}</div>`;
    return;
  }

  filtered.forEach((item) => {
    const status = getTodoStatus(item);
    const isDone = status === "closed";
    const isInProgress = status === "in_progress";
    const circleClass = isDone ? "checked" : isInProgress ? "in-progress" : "";
    const tagLabel = { open: "Offen", in_progress: "In Bearbeitung", closed: "Erledigt" }[status];
    const toggleTitle = isDone ? "Wieder öffnen" : "Als erledigt markieren";

    const card = document.createElement("article");
    card.className = `todo-card${isDone ? " todo-done" : ""}`;
    const bodyPreview = (item.body || "").trim().slice(0, 200);
    card.innerHTML = `
      <div class="todo-main">
        <div class="todo-check ${circleClass}"
             data-todo-number="${item.number}"
             data-todo-status="${status}"
             title="${toggleTitle}"></div>
        <div class="todo-content">
          <div class="todo-title">#${item.number} ${escapeHtml(item.title)}</div>
          ${bodyPreview ? `<div class="todo-body-preview">${escapeHtml(bodyPreview)}</div>` : ""}
        </div>
        <span class="todo-tag ${status}">${escapeHtml(tagLabel)}</span>
      </div>
      <div class="todo-actions">
        <button data-edit="issue" data-number="${item.number}">Bearbeiten</button>
        <a href="${item.html_url}" target="_blank" rel="noreferrer"><button>GitHub ↗</button></a>
      </div>
    `;
    target.appendChild(card);
  });
}

async function loadIssues() {
  state.issues = await api("/api/issues");
  renderTodos(state.issues);
}

function openNewTodoDialog() {
  $("newTodoTitle").value = "";
  $("newTodoBody").value = "";
  $("newTodoDialog").showModal();
  setTimeout(() => $("newTodoTitle").focus(), 50);
}

async function createTodo() {
  const title = $("newTodoTitle").value.trim();
  if (!title) { toast("Bitte einen Titel eingeben."); return; }
  $("newTodoDialog").close();
  toast("TODO wird erstellt...");
  try {
    await api("/api/issues", {
      method: "POST",
      body: JSON.stringify({ title, body: $("newTodoBody").value.trim() })
    });
    toast("TODO erstellt");
    await loadIssues();
  } catch (err) {
    toast(`Fehler: ${err.message}`);
  }
}

async function quickToggleTodo(number, currentStatus) {
  const closing = currentStatus !== "closed";
  const payload = closing
    ? { state: "closed", labels: [] }
    : { state: "open" };
  try {
    await api(`/api/issues/${number}`, {
      method: "PATCH",
      body: JSON.stringify(payload)
    });
    toast(closing ? "TODO erledigt ✓" : "TODO wieder geöffnet");
    await loadIssues();
  } catch (err) {
    toast(`Fehler: ${err.message}`);
  }
}

// ── Pull Requests ────────────────────────────────────────────────────

function renderPulls(items) {
  const target = $("pullsList");
  target.innerHTML = "";
  if (!items.length) {
    target.innerHTML = `<div class="item-card"><p>Keine Pull Requests gefunden.</p></div>`;
    return;
  }
  items.forEach((item) => {
    const card = document.createElement("article");
    card.className = "item-card";
    card.innerHTML = `
      <header>
        <div>
          <h3>#${item.number} ${escapeHtml(item.title)}</h3>
          <p>${escapeHtml((item.body || "").slice(0, 220))}</p>
        </div>
        <span class="state">${escapeHtml(item.state)}</span>
      </header>
      <div>
        <button data-edit="pull" data-number="${item.number}">Bearbeiten</button>
        <a href="${item.html_url}" target="_blank" rel="noreferrer"><button>GitHub ↗</button></a>
      </div>
    `;
    target.appendChild(card);
  });
}

async function loadPulls() {
  state.pulls = await api("/api/pulls");
  renderPulls(state.pulls);
}

// ── Edit dialog ──────────────────────────────────────────────────────

function openEdit(type, number) {
  const items = type === "issue" ? state.issues : state.pulls;
  const item = items.find((e) => e.number === Number(number));
  if (!item) return;
  $("editType").value = type;
  $("editNumber").value = item.number;
  $("editTitle").textContent = type === "issue" ? `TODO #${item.number}` : `Pull Request #${item.number}`;
  $("editItemTitle").value = item.title || "";
  $("editItemBody").value = item.body || "";

  const sel = $("editItemState");
  if (type === "issue") {
    sel.innerHTML = `
      <option value="open">Offen</option>
      <option value="in_progress">In Bearbeitung</option>
      <option value="closed">Erledigt</option>
    `;
    sel.value = getTodoStatus(item);
  } else {
    sel.innerHTML = `
      <option value="open">open</option>
      <option value="closed">closed</option>
    `;
    sel.value = item.state || "open";
  }
  $("editDialog").showModal();
}

async function saveItem(event) {
  event.preventDefault();
  const type = $("editType").value;
  const number = $("editNumber").value;
  const selectedStatus = $("editItemState").value;

  const payload = {
    title: $("editItemTitle").value,
    body: $("editItemBody").value
  };

  if (type === "issue") {
    if (selectedStatus === "in_progress") {
      payload.state = "open";
      payload.labels = ["in-progress"];
    } else if (selectedStatus === "closed") {
      payload.state = "closed";
      payload.labels = [];
    } else {
      payload.state = "open";
      payload.labels = [];
    }
  } else {
    payload.state = selectedStatus;
  }

  await api(`/api/${type === "issue" ? "issues" : "pulls"}/${number}`, {
    method: "PATCH",
    body: JSON.stringify(payload)
  });
  $("editDialog").close();
  toast("Gespeichert");
  if (type === "issue") await loadIssues(); else await loadPulls();
}

// ── Settings ─────────────────────────────────────────────────────────

async function openSettings() {
  const settings = await api("/api/settings");
  $("githubUsername").value = settings.githubUsername || "";
  $("githubEmail").value = settings.githubEmail || "";
  $("githubToken").value = "";
  $("webdavUrl").value = settings.webdavUrl || "http://localhost:8080";
  $("webdavUsername").value = settings.webdavUsername || "zotero";
  $("webdavPassword").value = settings.webdavPassword || "changeme123";
  $("tokenHint").textContent = settings.tokenSet
    ? "GitHub Token ist gesetzt. Feld leer lassen, um ihn zu behalten."
    : "Kein GitHub Token gespeichert.";
  $("settingsDialog").showModal();
}

async function saveSettings(event) {
  event.preventDefault();
  await api("/api/settings", {
    method: "POST",
    body: JSON.stringify({
      githubUsername: $("githubUsername").value,
      githubEmail: $("githubEmail").value,
      githubToken: $("githubToken").value,
      webdavUrl: $("webdavUrl").value,
      webdavUsername: $("webdavUsername").value,
      webdavPassword: $("webdavPassword").value
    })
  });
  $("settingsDialog").close();
  toast("Einstellungen gespeichert");
  await loadStatus();
}

// ── Git actions ──────────────────────────────────────────────────────

async function pullRemote() {
  toast("Pull wird ausgefuehrt...");
  const result = await api("/api/pull", { method: "POST", body: "{}" });
  if (result.skipped) toast(result.reason);
  else toast(result.pulled ? "Pull abgeschlossen" : "Pull fehlgeschlagen");
  await Promise.all([loadStatus(), loadGraph()]);
}

function openCommitDialog() {
  const now = new Date();
  const pad = (n) => String(n).padStart(2, "0");
  const defaultMsg = `Manueller Sync ${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())} ${pad(now.getHours())}:${pad(now.getMinutes())}:${pad(now.getSeconds())}`;
  $("commitMessage").value = defaultMsg;
  $("commitDialog").showModal();
  $("commitMessage").select();
}

async function doManualCommit() {
  const message = $("commitMessage").value.trim();
  const push = $("commitPush").checked;
  if (!message) { toast("Bitte eine Commit-Nachricht eingeben."); return; }
  $("commitDialog").close();
  toast("Commit wird erstellt...");
  try {
    const result = await api("/api/commit", {
      method: "POST",
      body: JSON.stringify({ message, push })
    });
    if (result.ok) {
      toast(push && result.pushed ? `Committed & gepusht` : `Committed: ${result.message}`);
    } else {
      toast(`Fehler: ${result.error}`);
    }
  } catch (err) {
    toast(`Fehler: ${err.message}`);
  }
  await Promise.all([loadStatus(), loadGraph()]);
}

async function stopServer() {
  if (!confirm("Server wirklich stoppen? Die UI wird danach nicht mehr erreichbar sein.")) return;
  try {
    await api("/api/shutdown", { method: "POST", body: "{}" });
  } catch (_) { /* connection closes as expected */ }
  $("statusLine").textContent = "Server gestoppt. Seite neu laden um neu zu verbinden.";
  toast("Server wurde gestoppt.");
}

// ── Sidebar resize ───────────────────────────────────────────────────

(function initResize() {
  const handle = $("resizeHandle");
  let dragging = false, startX = 0, startW = 0;

  const getSidebarW = () =>
    parseInt(getComputedStyle(document.documentElement).getPropertyValue("--sidebar-w")) || 260;

  const setSidebarW = (w) => {
    const clamped = Math.max(160, Math.min(480, w));
    document.documentElement.style.setProperty("--sidebar-w", clamped + "px");
    return clamped;
  };

  handle.addEventListener("mousedown", (e) => {
    if (document.body.classList.contains("sidebar-collapsed")) return;
    dragging = true;
    startX = e.clientX;
    startW = getSidebarW();
    handle.classList.add("dragging");
    document.body.style.cursor = "col-resize";
    document.body.style.userSelect = "none";
    e.preventDefault();
  });

  document.addEventListener("mousemove", (e) => {
    if (!dragging) return;
    setSidebarW(startW + (e.clientX - startX));
  });

  document.addEventListener("mouseup", () => {
    if (!dragging) return;
    dragging = false;
    handle.classList.remove("dragging");
    document.body.style.cursor = "";
    document.body.style.userSelect = "";
    localStorage.setItem("sidebarW", getSidebarW());
  });

  const saved = localStorage.getItem("sidebarW");
  if (saved) setSidebarW(parseInt(saved));
})();

// ── Utilities ────────────────────────────────────────────────────────

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

// ── Event wiring ─────────────────────────────────────────────────────

document.querySelectorAll(".nav").forEach((b) => b.addEventListener("click", () => setView(b.dataset.view)));

document.body.addEventListener("click", (event) => {
  const edit = event.target.closest("[data-edit]");
  if (edit) { openEdit(edit.dataset.edit, edit.dataset.number); return; }

  const check = event.target.closest("[data-todo-number]");
  if (check) {
    quickToggleTodo(check.dataset.todoNumber, check.dataset.todoStatus).catch((e) => toast(e.message));
  }
});

$("refreshGraph").addEventListener("click", () => Promise.all([loadStatus(), loadGraph()]).catch((e) => toast(e.message)));
$("refreshIssues").addEventListener("click", () => loadIssues().catch((e) => toast(e.message)));
$("refreshPulls").addEventListener("click", () => loadPulls().catch((e) => toast(e.message)));
$("settingsBtn").addEventListener("click", () => openSettings().catch((e) => toast(e.message)));
$("pullBtn").addEventListener("click", () => pullRemote().catch((e) => toast(e.message)));
$("commitBtn").addEventListener("click", () => openCommitDialog());
$("commitSaveBtn").addEventListener("click", () => doManualCommit().catch((e) => toast(e.message)));
$("commitCancelBtn").addEventListener("click", () => $("commitDialog").close());
$("stopServerBtn").addEventListener("click", () => stopServer().catch((e) => toast(e.message)));
$("newTodoBtn").addEventListener("click", () => openNewTodoDialog());
$("newTodoSaveBtn").addEventListener("click", () => createTodo().catch((e) => toast(e.message)));
$("newTodoCancelBtn").addEventListener("click", () => $("newTodoDialog").close());
$("sidebarToggle").addEventListener("click", () => document.body.classList.toggle("sidebar-collapsed"));
$("saveItemBtn").addEventListener("click", saveItem);
$("saveSettingsBtn").addEventListener("click", saveSettings);
$("showClosedTodos").addEventListener("change", () => renderTodos(state.issues));

// Auto-refresh graph alle 5 Sekunden wenn Graph aktiv
setInterval(() => {
  if ($("graphView").classList.contains("active")) {
    Promise.all([loadStatus(), loadGraph()]).catch(() => {});
  }
}, 5000);

// Initial load
Promise.all([loadStatus(), loadGraph()])
  .then(() => Promise.allSettled([loadIssues(), loadPulls()]))
  .catch((e) => toast(e.message));
