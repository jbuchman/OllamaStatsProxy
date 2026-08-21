const $ = (id) => document.getElementById(id);
const nf = new Intl.NumberFormat();
let historyData = [];
let clearConfiguredAPIKey = false;
let adminAuthenticated = false;
let adminPasswordConfigured = false;

const bytes = (n) => {
  if (n == null) return "–";
  if (n < 1024) return `${n} B`;
  if (n < 1048576) return `${(n / 1024).toFixed(1)} KB`;
  if (n < 1073741824) return `${(n / 1048576).toFixed(1)} MB`;
  return `${(n / 1073741824).toFixed(1)} GB`;
};

const escapeHTML = (value) =>
  String(value ?? "").replace(/[&<>"']/g, (c) => {
    return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[
      c
    ];
  });

const cell = (label, value, classes = "") =>
  `<td data-label="${label}" class="${classes}">${value}</td>`;

const resourceLink = (resource) => {
  try {
    const url = new URL(resource);
    if (url.protocol === "http:" || url.protocol === "https:") {
      const safeURL = escapeHTML(url.href);
      return `<a class="resource-link" href="${safeURL}" target="_blank" rel="noopener noreferrer">${escapeHTML(resource)}</a>`;
    }
  } catch (_) {
    // Search queries and malformed URLs remain plain text.
  }
  return escapeHTML(resource);
};

const bar = (label, value) => {
  const val = value ?? 0;
  const pct = value == null ? "–" : `${value.toFixed(0)}%`;
  return `
    <div class="bar-row">
      <span>${label}</span>
      <span class="bar"><b style="width:${val}%"></b></span>
      <span class="num">${pct}</span>
    </div>
  `;
};

async function refresh() {
  try {
    const [response, benchmarkResponse] = await Promise.all([
      fetch("/stats", { cache: "no-store" }),
      fetch("/benchmarks", { cache: "no-store" }),
    ]);
    if (!response.ok) throw new Error(`HTTP ${response.status}`);

    const data = await response.json();
    const benchmarks = benchmarkResponse.ok
      ? await benchmarkResponse.json()
      : [];

    $("connection").className = data.ollamaReachable ? "status" : "bad";
    $("connection").textContent = data.ollamaReachable
      ? `● ollama ${data.ollamaVersion ?? "?"}  token proxy active`
      : "● ollama unreachable";

    $("uptime").textContent = `session ${Math.floor(
      data.uptimeSeconds / 60
    )}m${String(Math.floor(data.uptimeSeconds % 60)).padStart(2, "0")}s`;

    $("out").textContent = nf.format(data.tokens.outputTokens);
    $("prompt").textContent = nf.format(data.tokens.promptTokens);
    $("requests").textContent = nf.format(data.tokens.requests);
    $("tps").textContent = data.tokens.liveTokensPerSecond.toFixed(1);

    const web = data.webTools;
    $("webTotal").textContent = nf.format(web.totalRequests);
    $("webSearches").textContent = nf.format(web.searchRequests);
    $("webFetches").textContent = nf.format(web.fetchRequests);
    $("webBytes").textContent = bytes(web.responseBytes);
    $("webToolRows").innerHTML = web.recent.map((r) => `
      <tr>
        ${cell("time", new Date(r.startedAt).toLocaleTimeString(), "dim")}
        ${cell("caller", escapeHTML(r.source))}
        ${cell("tool", escapeHTML(r.tool))}
        ${cell("resource", resourceLink(r.resource), "wide resource")}
        ${cell("results / bytes", r.resultCount != null ? nf.format(r.resultCount) + " results" : bytes(r.responseBytes), "num")}
        ${cell("time", r.durationSeconds.toFixed(2) + "s", "num")}
        ${cell("state", escapeHTML(r.state), `state ${r.state}`)}
      </tr>`).join("") ||
      `<tr>${cell("", "no web tool resources requested yet", "dim wide")}</tr>`;

    historyData.push(data.tokens.liveTokensPerSecond);
    historyData = historyData.slice(-60);
    const peak = Math.max(1, ...historyData);
    $("spark").innerHTML = historyData
      .map(
        (v) =>
          `<i style="height:${Math.max(2, (v / peak) * 100)}%"></i>`
      )
      .join("");

    $("requestRows").innerHTML =
      data.recentRequests
        .map(
          (r) => `
        <tr>
          ${cell("#", r.id, "dim")}
          ${cell("model", escapeHTML(r.model), "wide")}
          ${cell("endpoint", escapeHTML(r.endpoint), "wide")}
          ${cell("out tok", nf.format(r.outputTokens), "num")}
          ${cell("prompt", r.promptTokens ? nf.format(r.promptTokens) : "–", "num")}
          ${cell("tok/s", r.tokensPerSecond.toFixed(1), "num")}
          ${cell("cpu avg", r.averageCPUPercent != null ? r.averageCPUPercent.toFixed(1) + "%" : "–", "num")}
          ${cell("ram avg", bytes(r.averageMemoryUsedBytes), "num")}
          ${cell("time", r.elapsedSeconds.toFixed(1) + "s", "num")}
          ${cell("state", escapeHTML(r.state), `state ${r.state}`)}
        </tr>`
        )
        .join("") ||
      `<tr>${cell("", "no requests through proxy yet", "dim wide")}</tr>`;

    $("system").innerHTML =
      bar("cpu total", data.system.cpuPercent) +
      `<div class="dim">
        ${data.system.coreCount} cores ·
        load ${data.system.loadAverage.map((v) => v.toFixed(2)).join(" ")} ·
        ram ${bytes(data.system.memoryUsedBytes)} /
        ${bytes(data.system.memoryTotalBytes)}
      </div>`;

    $("processRows").innerHTML =
      data.system.ollamaProcesses
        .map(
          (p) => `
        <tr>
          ${cell("pid", p.pid, "dim")}
          ${cell("process", `ollama ${escapeHTML(p.kind)}`, "wide")}
          ${cell("cpu%", p.cpuPercent.toFixed(0), "num")}
          ${cell("threads", p.threads, "num")}
          ${cell("rss", bytes(p.residentBytes), "num")}
        </tr>`
        )
        .join("") ||
      `<tr>${cell("", "no ollama processes found", "dim wide")}</tr>`;

    const g = data.gpu;
    $("gpu").innerHTML =
      bar("device", g.deviceUtilizationPercent) +
      bar("renderer", g.rendererUtilizationPercent) +
      bar("tiler", g.tilerUtilizationPercent) +
      `<div class="dim">
        gpu mem ${bytes(g.memoryInUseBytes)} in use /
        ${bytes(g.allocatedSystemMemoryBytes)} wired<br />
        unified memory – shared with system ram
      </div>`;

    $("modelRows").innerHTML =
      data.loadedModels
        .map(
          (m) => `
        <tr>
          ${cell("model", `<b>${escapeHTML(m.name)}</b>`, "wide")}
          ${cell("size", bytes(m.size), "num")}
          ${cell("vram", bytes(m.sizeVRAM), "num")}
          ${cell(
            "placement",
            `<span style="color:${
              m.gpuPercent >= 100 ? "var(--green)" : "var(--yellow)"
            }">${m.gpuPercent ? m.gpuPercent + "% GPU" : "100% CPU"}</span>`
          )}
          ${cell("quant", escapeHTML(m.quantization ?? "–"))}
          ${cell("ctx", m.contextLength ?? "–", "num")}
          ${cell(
            "expires",
            m.expiresAt ? new Date(m.expiresAt).toLocaleTimeString() : "–",
            "num dim"
          )}
        </tr>`
        )
        .join("") ||
      `<tr>${cell("", "no models loaded", "dim wide")}</tr>`;

    $("benchmarkRows").innerHTML =
      benchmarks
        .map(
          (b) => `
        <tr>
          ${cell("model", `<b>${escapeHTML(b.model)}</b>`, "wide")}
          ${cell("runs", b.runs, "num")}
          ${cell("generation tok/s", b.averageOutputTokensPerSecond.toFixed(1), "num")}
          ${cell(
            "prompt tok/s",
            b.averagePromptTokensPerSecond?.toFixed(1) ?? "–",
            "num"
          )}
          ${cell(
            "TTFT",
            b.averageTimeToFirstTokenSeconds != null
              ? b.averageTimeToFirstTokenSeconds.toFixed(2) + "s"
              : "–",
            "num"
          )}
          ${cell("total", b.averageTotalDurationSeconds.toFixed(2) + "s", "num")}
          ${cell("cpu avg", b.averageCPUPercent != null ? b.averageCPUPercent.toFixed(1) + "%" : "–", "num")}
          ${cell("ram avg", bytes(b.averageMemoryUsedBytes), "num")}
        </tr>`
        )
        .join("") ||
      `<tr>${cell("", "no completed benchmarks yet", "dim wide")}</tr>`;
  } catch (error) {
    $("connection").className = "bad";
    $("connection").textContent = "● monitor disconnected";
    console.error("Unable to refresh monitor:", error);
  }
}

async function clearStats() {
  if (!adminAuthenticated) {
    if (adminPasswordConfigured) $("adminLoginDialog").showModal();
    return;
  }
  if (!window.confirm("Delete all completion and web-tool history? This cannot be undone.")) {
    return;
  }

  const button = $("clearStats");
  button.disabled = true;
  button.textContent = "clearing…";
  try {
    const response = await fetch("/history", {
      method: "DELETE",
      cache: "no-store",
    });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    historyData = [];
    await refresh();
    button.textContent = "cleared";
    window.setTimeout(() => {
      button.textContent = "clear stats";
    }, 1200);
  } catch (error) {
    button.textContent = "clear failed";
    console.error("Unable to clear stats:", error);
    window.alert(`Unable to clear stats: ${error.message}`);
  } finally {
    button.disabled = false;
  }
}

async function loadConfiguration() {
  try {
    const response = await fetch("/config", { cache: "no-store" });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const config = await response.json();
    $("configProvider").value = config.webSearchProvider ?? "";
    $("configSearchURL").value = config.webSearchURL ?? "";
    $("configFetchMB").value = config.webFetchMaxMB;
    $("configFetchCharacters").value = config.webFetchMaxCharacters;
    $("configFetchEnabled").checked = config.webFetchEnabled;
    $("configFetchPrivateNetworks").checked = config.webFetchAllowPrivateNetworks;
    $("configToolRounds").value = config.serverToolRounds;
    $("configToolsEnabled").checked = config.serverToolsEnabled;
    $("apiKeyState").textContent = config.webSearchAPIKeyConfigured ? "(configured)" : "(not configured)";
    $("configStatus").className = "dim";
    $("configStatus").textContent = config.restartRequired ? "restart required to apply saved settings" : "";
    clearConfiguredAPIKey = false;
  } catch (error) {
    $("configStatus").textContent = `unable to load: ${error.message}`;
    $("configStatus").className = "bad";
  }
}

async function loadAdminSession() {
  const response = await fetch("/admin/session", { cache: "no-store" });
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  const session = await response.json();
  adminAuthenticated = session.authenticated;
  adminPasswordConfigured = session.passwordConfigured;
  if (adminAuthenticated) await loadConfiguration();
}

async function loginAdmin(event) {
  event.preventDefault();
  const password = $("adminLoginPassword").value;
  $("adminLoginStatus").textContent = "authenticating…";
  try {
    const response = await fetch("/admin/login", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ username: "admin", password }),
    });
    if (!response.ok) throw new Error("invalid password");
    adminAuthenticated = true;
    $("adminLoginPassword").value = "";
    $("adminLoginStatus").textContent = "";
    $("adminLoginDialog").close();
    await loadConfiguration();
    $("settingsPanel").open = true;
  } catch (error) {
    $("adminLoginStatus").textContent = error.message;
  }
}

async function saveConfiguration(event) {
  event.preventDefault();
  const submit = event.currentTarget.querySelector('[type="submit"]');
  submit.disabled = true;
  $("configStatus").className = "dim";
  $("configStatus").textContent = "saving…";
  try {
    const response = await fetch("/config", {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        webSearchProvider: $("configProvider").value || null,
        webSearchAPIKey: $("configAPIKey").value || null,
        clearWebSearchAPIKey: clearConfiguredAPIKey,
        webSearchURL: $("configSearchURL").value || null,
        webFetchMaxMB: Number($("configFetchMB").value),
        webFetchMaxCharacters: Number($("configFetchCharacters").value),
        webFetchEnabled: $("configFetchEnabled").checked,
        webFetchAllowPrivateNetworks: $("configFetchPrivateNetworks").checked,
        serverToolsEnabled: $("configToolsEnabled").checked,
        serverToolRounds: Number($("configToolRounds").value),
        adminPassword: $("configAdminPassword").value || null,
      }),
    });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const saved = await response.json();
    const passwordChanged = $("configAdminPassword").value.length > 0;
    $("configAPIKey").value = "";
    $("configAdminPassword").value = "";
    if (passwordChanged) {
      adminAuthenticated = false;
      adminPasswordConfigured = true;
      $("settingsPanel").open = false;
      $("adminLoginDialog").showModal();
      $("adminLoginStatus").textContent = "password changed — sign in again";
    } else {
      await loadConfiguration();
      $("configStatus").textContent = saved.restartRequired
        ? "saved — restart the proxy to apply"
        : "saved — applied immediately";
    }
  } catch (error) {
    $("configStatus").className = "bad";
    $("configStatus").textContent = `save failed: ${error.message}`;
  } finally {
    submit.disabled = false;
  }
}

$("clearAPIKey").addEventListener("click", () => {
  clearConfiguredAPIKey = true;
  $("configAPIKey").value = "";
  $("apiKeyState").textContent = "(will be cleared on save)";
});
$("settingsPanel").addEventListener("toggle", () => {
  if ($("settingsPanel").open && !adminAuthenticated) {
    $("settingsPanel").open = false;
    if (adminPasswordConfigured) $("adminLoginDialog").showModal();
  }
});
$("adminLoginForm").addEventListener("submit", loginAdmin);
$("cancelAdminLogin").addEventListener("click", () => $("adminLoginDialog").close());
$("adminLogout").addEventListener("click", async () => {
  await fetch("/admin/logout", { method: "POST" });
  await loadAdminSession();
  $("settingsPanel").open = false;
});
$("settingsForm").addEventListener("submit", saveConfiguration);
$("clearStats").addEventListener("click", clearStats);
loadAdminSession().catch((error) => console.error("Unable to load admin session:", error));
refresh();
setInterval(refresh, 1000);
