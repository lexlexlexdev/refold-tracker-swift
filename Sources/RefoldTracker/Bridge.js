// Same-origin, read-only discovery. Mutations run only after an explicit native command.
(() => {
  const actions = new Map();
  const allowed = new Map([
    [60202, "Anki"],
    [30104, "Podcast / video listening"],
    [20101, "문법 / 읽기 / 쓰기 / 발음"]
  ]);

  function parseRows(text) {
    const rows = new Map();
    for (const line of text.split("\n")) {
      const separator = line.indexOf(":");
      if (separator < 0) continue;
      const payload = line.slice(separator + 1);
      if (!payload.startsWith("{") && !payload.startsWith("[")) continue;
      try { rows.set(line.slice(0, separator), JSON.parse(payload)); } catch {}
    }
    return rows;
  }

  function pageRows(document) {
    let text = "";
    const prefix = "self.__next_f.push(";
    for (const script of document.scripts) {
      const source = script.textContent || "";
      const start = source.indexOf(prefix);
      if (start < 0) continue;
      const end = source.lastIndexOf(")");
      try {
        const part = JSON.parse(source.slice(start + prefix.length, end));
        if (typeof part[1] === "string") text += part[1];
      } catch {}
    }
    return parseRows(text);
  }

  function visit(value, callback) {
    if (!value || typeof value !== "object") return;
    callback(value);
    for (const child of Object.values(value)) visit(child, callback);
  }

  async function request(url, options = {}) {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 30000);
    try {
      const response = await fetch(url, { ...options, credentials: "same-origin", signal: controller.signal });
      const text = await response.text();
      return { response, text };
    } finally { clearTimeout(timeout); }
  }

  async function history() {
    const { response, text } = await request("/dashboard");
    if (!response.ok) throw new Error(`Dashboard HTTP ${response.status}`);
    if (new URL(response.url).pathname.includes("login")) throw new Error("Sign in to Refold using the sign-in window.");
    const document = new DOMParser().parseFromString(text, "text/html");
    const rows = pageRows(document);
    const entries = new Map();
    let hasTimeline = false;
    for (const value of rows.values()) visit(value, item => {
      if (Object.hasOwn(item, "loadMoreFn") && Object.hasOwn(item, "items")) hasTimeline = true;
      if (item.type === "action" && item.id && typeof item.durationMs === "number") {
        entries.set(String(item.id), {
          id: String(item.id), name: item.name, activityId: String(item.activityId),
          activityName: item.activityName, durationMs: Math.round(item.durationMs),
          languageCode: item.languageCode, attributedDate: item.attributedDate,
          startTime: item.startTime || null, note: item.note || null
        });
        hasTimeline = true;
      }
    });
    if (!hasTimeline) throw new Error("Cannot read history. Sign in, or update the adapter for the current Refold version.");

    // Discover build-specific Server Action IDs instead of hard-coding hashes.
    if (!actions.has("saveAction") || !actions.has("editUserAction") || !actions.has("deleteUserAction")) {
      const scripts = [...document.scripts].map(script => script.src)
        .filter(url => url.includes("/_next/static/chunks/") && new URL(url).origin === location.origin);
      await Promise.all(scripts.map(async url => {
        const { response, text } = await request(url);
        if (!response.ok) return;
        const pattern = /createServerReference\)\("([a-f0-9]+)"[^;]{0,250}?"(saveAction|editUserAction|deleteUserAction)"\)/g;
        for (const match of text.matchAll(pattern)) actions.set(match[2], match[1]);
      }));
    }
    return { entries: [...entries.values()], canWrite: actions.has("saveAction") && actions.has("editUserAction") && actions.has("deleteUserAction") };
  }

  async function mutate(name, payload) {
    const id = actions.get(name);
    if (!id) throw new Error("Refold operation not found. Refresh history.");
    const { response, text } = await request("/dashboard", {
      method: "POST",
      headers: { "Next-Action": id, "Content-Type": "text/plain;charset=UTF-8", "Accept": "text/x-component" },
      body: JSON.stringify([payload])
    });
    if (!response.ok) { actions.clear(); throw new Error(`Refold HTTP ${response.status}; check the result in history.`); }
    if (!(response.headers.get("content-type") || "").includes("text/x-component")) {
      throw new Error("Unexpected Refold response. Check your sign-in and the operation result.");
    }
    const rows = parseRows(text);
    const root = rows.get("0");
    let result = root && root.a;
    const seen = new Set();
    while (typeof result === "string" && result.startsWith("$") && !seen.has(result)) {
      seen.add(result);
      result = rows.get(result.replace(/^\$@?/, ""));
    }
    if (!result || typeof result.success !== "boolean") throw new Error("Unknown operation result. Check history.");
    if (!result.success) throw new Error(result.message || (result.errors || []).map(e => e.message).join(", ") || "Refold rejected the operation.");
    return { success: true };
  }

  window.refoldNative = {
    history,
    delete(payload) {
      if (!Number.isSafeInteger(payload.id) || payload.id <= 0) throw new Error("Invalid entry ID");
      return mutate("deleteUserAction", payload);
    },
    save(payload) {
      if (payload.languageCode !== "ko" || allowed.get(payload.activityId) !== payload.nickname ||
          payload.source !== "STOPWATCH" || !(payload.durationMs > 0)) throw new Error("Invalid tracking action");
      return mutate("saveAction", payload);
    },
    edit(payload) {
      if (payload.languageCode !== "ko" || allowed.get(Number(payload.activityId)) !== payload.nickname ||
          !(payload.durationMilliseconds > 0)) throw new Error("Invalid edit action");
      return mutate("editUserAction", payload);
    }
  };
})();
