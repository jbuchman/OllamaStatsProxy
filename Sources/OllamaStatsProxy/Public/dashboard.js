const $ = (id) => document.getElementById(id);
const nf = new Intl.NumberFormat();
let historyData = [];
let clearConfiguredAPIKey = false;
let adminAuthenticated = false;
let adminPasswordConfigured = false;
const historyPageSize = 10;
let requestPage = 1;
let requestTotalPages = 1;
let webPage = 1;
let webTotalPages = 1;
let expandedRequestID = null;
let filterTimer = null;
let refreshSequence = 0;
const modelActionsInProgress = new Map();
const modelActionNotices = new Map();
let interactionUntil = 0;

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

const modelProgressHTML = (pending) => `<div class="model-progress" role="status" aria-live="polite">
  <span class="activity-spinner" aria-hidden="true"></span>
  ${escapeHTML(pending.label)} · ${Math.max(0, Math.floor((Date.now() - pending.startedAt) / 1000))}s
</div>`;

function updateTableHTML(id, html) {
  const element = $(id);
  if (Date.now() < interactionUntil || element.innerHTML === html) return;
  element.innerHTML = html;
}

async function refresh() {
  const sequence = ++refreshSequence;
  try {
    const requestParameters = new URLSearchParams({ page: requestPage, pageSize: historyPageSize });
    const webParameters = new URLSearchParams({ page: webPage, pageSize: historyPageSize });
    if ($("requestSearch").value) requestParameters.set("q", $("requestSearch").value);
    if ($("requestState").value) requestParameters.set("state", $("requestState").value);
    if ($("webSearch").value) webParameters.set("q", $("webSearch").value);
    if ($("webState").value) webParameters.set("state", $("webState").value);
    const [response, benchmarkResponse, requestPageResponse, webPageResponse] = await Promise.all([
      fetch("/stats", { cache: "no-store" }),
      fetch("/benchmarks", { cache: "no-store" }),
      fetch(`/requests?${requestParameters}`, { cache: "no-store" }),
      fetch(`/web-tools/page?${webParameters}`, { cache: "no-store" }),
    ]);
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    if (!requestPageResponse.ok || !webPageResponse.ok) throw new Error("Unable to load history pages");

    const data = await response.json();
    const benchmarks = benchmarkResponse.ok
      ? await benchmarkResponse.json()
      : [];
    const requests = await requestPageResponse.json();
    const webTools = await webPageResponse.json();
    if (sequence !== refreshSequence) return;
    requestPage = requests.page;
    requestTotalPages = requests.totalPages;
    webPage = webTools.page;
    webTotalPages = webTools.totalPages;

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
    updateTableHTML("webToolRows", webTools.items.map((r) => `
      <tr>
        ${cell("time", new Date(r.startedAt).toLocaleTimeString(), "dim")}
        ${cell("caller", escapeHTML(r.source))}
        ${cell("tool", escapeHTML(r.tool))}
        ${cell("resource", resourceLink(r.resource), "wide resource")}
        ${cell("results / bytes", r.resultCount != null ? nf.format(r.resultCount) + " results" : bytes(r.responseBytes), "num")}
        ${cell("time", r.durationSeconds.toFixed(2) + "s", "num")}
        ${cell("state", escapeHTML(r.state), `state ${r.state}`)}
      </tr>`).join("") ||
      `<tr>${cell("", "no web tool resources requested yet", "dim wide")}</tr>`);
    updatePagination("web", webPage, webTotalPages, webTools.totalItems);

    historyData.push(data.tokens.liveTokensPerSecond);
    historyData = historyData.slice(-60);
    const peak = Math.max(1, ...historyData);
    $("spark").innerHTML = historyData
      .map(
        (v) =>
          `<i style="height:${Math.max(2, (v / peak) * 100)}%"></i>`
      )
      .join("");

    updateTableHTML("requestRows",
      requests.items
        .map(
          (r) => `
        <tr class="history-row" data-request-id="${r.id}" title="Show request timing details">
          ${cell("#", r.id, "dim")}
          ${cell("model", escapeHTML(r.model), "wide")}
          ${cell("endpoint", escapeHTML(r.endpoint), "wide")}
          ${cell("out tok", nf.format(r.outputTokens), "num")}
          ${cell("prompt", r.promptTokens ? nf.format(r.promptTokens) : "–", "num")}
          ${cell("tok/s", r.tokensPerSecond.toFixed(1), "num")}
          ${cell("cpu avg", r.averageCPUPercent != null ? r.averageCPUPercent.toFixed(1) + "%" : "–", "num")}
          ${cell("gpu avg", r.averageGPUPercent != null ? r.averageGPUPercent.toFixed(1) + "%" : "–", "num")}
          ${cell("ram avg", bytes(r.averageMemoryUsedBytes), "num")}
          ${cell("time", r.elapsedSeconds.toFixed(1) + "s", "num")}
          ${cell("state", escapeHTML(r.state), `state ${r.state}`)}
          ${cell("action", r.endedAt == null
            ? `<button class="stop-button" type="button" data-request-id="${r.id}">stop</button>`
            : "–")}
        </tr>`
        )
        .join("") ||
      `<tr>${cell("", "no requests through proxy yet", "dim wide")}</tr>`);
    updatePagination("request", requestPage, requestTotalPages, requests.totalItems);
    if (expandedRequestID != null && requests.items.some((request) => request.id === expandedRequestID)) {
      await loadRequestDetail(expandedRequestID);
    }

    $("system").innerHTML =
      bar("cpu total", data.system.cpuPercent) +
      `<div class="dim">
        ${data.system.coreCount} cores ·
        load ${data.system.loadAverage.map((v) => v.toFixed(2)).join(" ")} ·
        ram ${bytes(data.system.memoryUsedBytes)} /
        ${bytes(data.system.memoryTotalBytes)}
      </div>`;

    updateTableHTML("processRows",
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
      `<tr>${cell("", "no ollama processes found", "dim wide")}</tr>`);

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

    const installedModels = data.installedModels?.length
      ? data.installedModels
      : data.loadedModels.map((model) => ({
          name: model.name, size: model.size, parameterSize: null, quantization: model.quantization,
        }));
    updateTableHTML("modelRows",
      installedModels
        .map((m) => {
          const loaded = data.loadedModels.find((candidate) => candidate.name === m.name);
          const indefinitelyLoaded = loaded?.keepAlive === "-1"
            || (loaded?.expiresAt && new Date(loaded.expiresAt).getUTCFullYear() >= 9000);
          const pending = modelActionsInProgress.get(m.name);
          const notice = modelActionNotices.get(m.name);
          if (notice && notice.until <= Date.now()) modelActionNotices.delete(m.name);
          const controls = pending
            ? modelProgressHTML(pending)
            : loaded
            ? `<div class="model-controls">
                <button class="secondary-button model-action" data-model="${escapeHTML(m.name)}" data-keep-alive="5m">expire 5m</button>
                <button class="secondary-button model-action" data-model="${escapeHTML(m.name)}" data-keep-alive="-1" ${indefinitelyLoaded ? "disabled" : ""}>${indefinitelyLoaded ? "kept loaded" : "keep loaded"}</button>
                <button class="stop-button model-action" data-model="${escapeHTML(m.name)}" data-keep-alive="0">unload</button>
                ${notice && notice.until > Date.now() ? `<span class="action-success" role="status">${escapeHTML(notice.message)}</span>` : ""}
              </div>`
            : `<button class="secondary-button model-action" data-model="${escapeHTML(m.name)}" data-keep-alive="-1">preload</button>`;
          return `<tr>
          ${cell("model", `<b>${escapeHTML(m.name)}</b>`, "wide")}
          ${cell("size", bytes(m.size), "num")}
          ${cell("vram", loaded ? bytes(loaded.sizeVRAM) : "–", "num")}
          ${cell("placement", loaded
            ? `<span style="color:${loaded.gpuPercent >= 100 ? "var(--green)" : "var(--yellow)"}">${loaded.gpuPercent ? loaded.gpuPercent + "% GPU" : "100% CPU"}</span>`
            : `<span class="dim">unloaded</span>`)}
          ${cell("quant", escapeHTML(m.quantization ?? loaded?.quantization ?? "–"))}
          ${cell("ctx", loaded?.contextLength ?? "–", "num")}
          ${cell("expires", loaded?.expiresAt ? new Date(loaded.expiresAt).toLocaleTimeString() : "–", "num dim")}
          ${cell("controls", controls, "wide")}
        </tr>`;
        })
        .join("") ||
      `<tr>${cell("", "no models loaded", "dim wide")}</tr>`);

    updateTableHTML("benchmarkRows",
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
          ${cell("gpu avg", b.averageGPUPercent != null ? b.averageGPUPercent.toFixed(1) + "%" : "–", "num")}
          ${cell("ram avg", bytes(b.averageMemoryUsedBytes), "num")}
          ${cell("speed Δ", deltaBadge(b.outputTokensPerSecondDeltaPercent, false), "num")}
          ${cell("TTFT Δ", deltaBadge(b.timeToFirstTokenDeltaPercent, true), "num")}
        </tr>`
        )
        .join("") ||
      `<tr>${cell("", "no completed benchmarks yet", "dim wide")}</tr>`);
  } catch (error) {
    if (sequence !== refreshSequence) return;
    $("connection").className = "bad";
    $("connection").textContent = "● monitor disconnected";
    console.error("Unable to refresh monitor:", error);
  }
}

function deltaBadge(value, higherIsWorse) {
  if (value == null || !Number.isFinite(value)) return `<span class="delta neutral">–</span>`;
  const regression = higherIsWorse ? value > 5 : value < -5;
  const improvement = higherIsWorse ? value < -5 : value > 5;
  const className = regression ? "bad" : improvement ? "good" : "neutral";
  const sign = value > 0 ? "+" : "";
  return `<span class="delta ${className}">${sign}${value.toFixed(1)}%</span>`;
}

function timelineRow(label, start, duration, total, className = "") {
  const safeTotal = Math.max(total, 0.001);
  const left = Math.max(0, Math.min(100, start / safeTotal * 100));
  const width = Math.max(0.5, Math.min(100 - left, duration / safeTotal * 100));
  return `<div class="timeline-row">
    <span>${escapeHTML(label)}</span>
    <span class="timeline-track"><i class="timeline-segment ${className}" style="left:${left}%;width:${width}%"></i></span>
    <span class="num">${duration.toFixed(2)}s</span>
  </div>`;
}

async function loadRequestDetail(requestID) {
  const sourceRow = $(`requestRows`).querySelector(`tr[data-request-id="${requestID}"]`);
  if (!sourceRow) return;
  try {
    const response = await fetch(`/requests/${requestID}`, { cache: "no-store" });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const detail = await response.json();
    const request = detail.request;
    const total = Math.max(request.elapsedSeconds, request.totalDurationSeconds ?? 0, 0.001);
    const load = Math.min(request.loadDurationSeconds ?? 0, total);
    const prompt = request.promptTokensPerSecond > 0 ? request.promptTokens / request.promptTokensPerSecond : 0;
    const generation = request.tokensPerSecond > 0 ? request.outputTokens / request.tokensPerSecond : Math.max(0, total - load - prompt);
    const requestStart = new Date(request.startedAt).getTime();
    const timeline = [
      load > 0 ? timelineRow("model load", 0, load, total) : "",
      prompt > 0 ? timelineRow("prompt eval", load, prompt, total) : "",
      generation > 0 ? timelineRow("generation", load + prompt, generation, total, "generation") : "",
      ...detail.webTools.map((tool) => timelineRow(
        `${tool.tool}: ${tool.host ?? tool.resource}`,
        Math.max(0, (new Date(tool.startedAt).getTime() - requestStart) / 1000),
        tool.durationSeconds,
        total,
        "tool"
      )),
    ].join("");
    const existing = sourceRow.nextElementSibling;
    if (existing?.classList.contains("detail-row")) existing.remove();
    sourceRow.insertAdjacentHTML("afterend", `<tr class="detail-row"><td colspan="12">
      <div class="request-detail">
        <div class="detail-meta">
          <span>started ${new Date(request.startedAt).toLocaleString()}</span>
          <span>label ${escapeHTML(request.benchmarkLabel ?? "–")}</span>
          <span>temperature ${request.temperature ?? "–"}</span>
          <span>context ${request.contextLength ?? "–"}</span>
          <span>samples ${request.resourceSampleCount}</span>
          <span>${detail.webTools.length} linked tool call${detail.webTools.length === 1 ? "" : "s"}</span>
        </div>
        <div class="timeline">${timeline || `<span class="dim">Timing phases are not available for this request.</span>`}</div>
      </div>
    </td></tr>`);
  } catch (error) {
    console.error(`Unable to load request #${requestID}:`, error);
  }
}

async function applyModelLifecycle(model, keepAlive, button) {
  if (!adminAuthenticated) {
    if (adminPasswordConfigured) $("adminLoginDialog").showModal();
    return;
  }
  if (modelActionsInProgress.has(model)) return;
  const label = keepAlive === "0" ? "unloading" : keepAlive === "5m" ? "setting expiration" : "loading model";
  const pending = { label, startedAt: Date.now() };
  modelActionsInProgress.set(model, pending);
  const currentControls = button.closest(".model-controls") ?? button;
  currentControls.outerHTML = modelProgressHTML(pending);
  refresh();
  try {
    const response = await fetch("/models/lifecycle", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ model, keepAlive }),
    });
    if (!response.ok) {
      const payload = await response.json().catch(() => ({}));
      throw new Error(payload.error ?? `HTTP ${response.status}`);
    }
    const message = keepAlive === "0" ? "unloaded" : keepAlive === "5m" ? "expiration set" : "kept loaded";
    modelActionNotices.set(model, { message, until: Date.now() + 5000 });
  } catch (error) {
    window.alert(`Unable to update ${model}: ${error.message}`);
  } finally {
    modelActionsInProgress.delete(model);
    await refresh();
  }
}

function updatePagination(prefix, page, totalPages, totalItems) {
  $(`${prefix}PageStatus`).textContent = `page ${page} of ${totalPages} · ${nf.format(totalItems)} items`;
  $(`${prefix}Previous`).disabled = page <= 1;
  $(`${prefix}Next`).disabled = page >= totalPages;
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
    requestPage = 1;
    webPage = 1;
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

async function cancelRequest(requestID, button) {
  if (!adminAuthenticated) {
    if (adminPasswordConfigured) $("adminLoginDialog").showModal();
    return;
  }
  button.disabled = true;
  button.textContent = "stopping…";
  try {
    const response = await fetch(`/requests/${requestID}/cancel`, {
      method: "POST",
      cache: "no-store",
    });
    if (!response.ok && response.status !== 409) throw new Error(`HTTP ${response.status}`);
    await refresh();
  } catch (error) {
    button.disabled = false;
    button.textContent = "stop";
    window.alert(`Unable to stop request #${requestID}: ${error.message}`);
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
$("requestRows").addEventListener("click", (event) => {
  const button = event.target.closest(".stop-button");
  if (button) {
    cancelRequest(Number(button.dataset.requestId), button);
    return;
  }
  const row = event.target.closest(".history-row");
  if (!row) return;
  const requestID = Number(row.dataset.requestId);
  if (expandedRequestID === requestID) {
    expandedRequestID = null;
    if (row.nextElementSibling?.classList.contains("detail-row")) row.nextElementSibling.remove();
  } else {
    expandedRequestID = requestID;
    loadRequestDetail(requestID);
  }
});
document.addEventListener("pointerdown", () => { interactionUntil = Date.now() + 1000; }, true);
$("modelRows").addEventListener("click", (event) => {
  const button = event.target.closest(".model-action");
  if (button) applyModelLifecycle(button.dataset.model, button.dataset.keepAlive, button);
});
const filtersChanged = () => {
  window.clearTimeout(filterTimer);
  filterTimer = window.setTimeout(() => {
    requestPage = 1;
    webPage = 1;
    expandedRequestID = null;
    refresh();
  }, 250);
};
$("requestSearch").addEventListener("input", filtersChanged);
$("requestState").addEventListener("change", filtersChanged);
$("webSearch").addEventListener("input", filtersChanged);
$("webState").addEventListener("change", filtersChanged);
$("requestPrevious").addEventListener("click", () => { requestPage = Math.max(1, requestPage - 1); refresh(); });
$("requestNext").addEventListener("click", () => { requestPage = Math.min(requestTotalPages, requestPage + 1); refresh(); });
$("webPrevious").addEventListener("click", () => { webPage = Math.max(1, webPage - 1); refresh(); });
$("webNext").addEventListener("click", () => { webPage = Math.min(webTotalPages, webPage + 1); refresh(); });
loadAdminSession().catch((error) => console.error("Unable to load admin session:", error));
refresh();
setInterval(refresh, 1000);
