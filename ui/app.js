const state = {
  issues: [],
  pulls: []
};

const $ = (id) => document.getElementById(id);

async function api(path, options = {}) {
  const response = await fetch(path, {
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
  setTimeout(() => node.classList.remove("show"), 2600);
}

function setView(name) {
  document.querySelectorAll(".nav").forEach((button) => button.classList.toggle("active", button.dataset.view === name));
  document.querySelectorAll(".view").forEach((view) => view.classList.remove("active"));
  $(`${name}View`).classList.add("active");
  $("viewTitle").textContent = name === "graph" ? "Source Control Graph" : name === "issues" ? "Issues" : "Pull Requests";
}

async function loadStatus() {
  const status = await api("/api/status");
  $("repoName").textContent = status.repo?.remote || "lokales Repository";
  $("branchBadge").textContent = status.branch || "no branch";
  $("syncBadge").textContent = `${status.ahead} ahead / ${status.behind} behind`;
  const ignored = status.ignoredData ? ` · ${status.ignoredData} ignorierte data-Dateien` : "";
  $("statusLine").textContent = status.dirty ? `Lokale Aenderungen vorhanden · data: ${status.dataChanges}${ignored}` : `Arbeitsbaum sauber${ignored}`;
}

async function loadGraph() {
  const commits = await api("/api/log");
  const graph = $("commitGraph");
  graph.innerHTML = "";
  commits.forEach((commit) => {
    const row = document.createElement("div");
    row.className = "commit-row";
    row.innerHTML = `
      <div class="rail"><span class="dot"></span></div>
      <div>
        <div class="commit-subject">${escapeHtml(commit.subject)}</div>
        <div class="commit-meta">${escapeHtml(commit.author)} · ${new Date(commit.date).toLocaleString()}</div>
      </div>
      <div class="commit-hash">${escapeHtml(commit.short)}</div>
    `;
    graph.appendChild(row);
  });
}

async function loadIssues() {
  state.issues = await api("/api/issues");
  renderItems("issuesList", "issue", state.issues);
}

async function loadPulls() {
  state.pulls = await api("/api/pulls");
  renderItems("pullsList", "pull", state.pulls);
}

function renderItems(targetId, type, items) {
  const target = $(targetId);
  target.innerHTML = "";
  if (!items.length) {
    target.innerHTML = `<div class="item-card"><p>Keine Eintraege gefunden.</p></div>`;
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
        <button data-edit="${type}" data-number="${item.number}">Bearbeiten</button>
        <a href="${item.html_url}" target="_blank" rel="noreferrer"><button>GitHub</button></a>
      </div>
    `;
    target.appendChild(card);
  });
}

function openEdit(type, number) {
  const items = type === "issue" ? state.issues : state.pulls;
  const item = items.find((entry) => entry.number === Number(number));
  if (!item) return;
  $("editType").value = type;
  $("editNumber").value = item.number;
  $("editTitle").textContent = `${type === "issue" ? "Issue" : "Pull Request"} #${item.number}`;
  $("editItemTitle").value = item.title || "";
  $("editItemBody").value = item.body || "";
  $("editItemState").value = item.state || "open";
  $("editDialog").showModal();
}

async function saveItem(event) {
  event.preventDefault();
  const type = $("editType").value;
  const number = $("editNumber").value;
  const body = {
    title: $("editItemTitle").value,
    body: $("editItemBody").value,
    state: $("editItemState").value
  };
  await api(`/api/${type === "issue" ? "issues" : "pulls"}/${number}`, {
    method: "PATCH",
    body: JSON.stringify(body)
  });
  $("editDialog").close();
  toast("Gespeichert");
  if (type === "issue") await loadIssues(); else await loadPulls();
}

async function openSettings() {
  const settings = await api("/api/settings");
  $("githubUsername").value = settings.githubUsername || "";
  $("githubEmail").value = settings.githubEmail || "";
  $("githubToken").value = "";
  $("webdavUrl").value = settings.webdavUrl || "http://localhost:8080";
  $("webdavUsername").value = settings.webdavUsername || "zotero";
  $("webdavPassword").value = settings.webdavPassword || "changeme123";
  $("tokenHint").textContent = settings.tokenSet ? "GitHub Token ist gesetzt. Feld leer lassen, um ihn zu behalten." : "Kein GitHub Token gespeichert.";
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

async function pullRemote() {
  toast("Pull wird ausgefuehrt...");
  const result = await api("/api/pull", { method: "POST", body: "{}" });
  if (result.skipped) toast(result.reason);
  else toast(result.pulled ? "Pull abgeschlossen" : "Pull fehlgeschlagen");
  await Promise.all([loadStatus(), loadGraph()]);
}

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

document.querySelectorAll(".nav").forEach((button) => button.addEventListener("click", () => setView(button.dataset.view)));
document.body.addEventListener("click", (event) => {
  const edit = event.target.closest("[data-edit]");
  if (edit) openEdit(edit.dataset.edit, edit.dataset.number);
});

$("refreshGraph").addEventListener("click", () => Promise.all([loadStatus(), loadGraph()]).catch((error) => toast(error.message)));
$("refreshIssues").addEventListener("click", () => loadIssues().catch((error) => toast(error.message)));
$("refreshPulls").addEventListener("click", () => loadPulls().catch((error) => toast(error.message)));
$("settingsBtn").addEventListener("click", () => openSettings().catch((error) => toast(error.message)));
$("pullBtn").addEventListener("click", () => pullRemote().catch((error) => toast(error.message)));
$("sidebarToggle").addEventListener("click", () => document.body.classList.toggle("sidebar-collapsed"));
$("saveItemBtn").addEventListener("click", saveItem);
$("saveSettingsBtn").addEventListener("click", saveSettings);

Promise.all([loadStatus(), loadGraph()])
  .then(() => Promise.allSettled([loadIssues(), loadPulls()]))
  .catch((error) => toast(error.message));
