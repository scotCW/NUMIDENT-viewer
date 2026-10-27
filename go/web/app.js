"use strict";
// NUMIDENT Viewer UI. Plain JS; talks to the local Go server.

const $ = (sel, root = document) => root.querySelector(sel);
const SETS = ["NUMSS5", "NUMCLM", "NUMDEATH"];
const SET_SHORT = { NUMSS5: "SS-5", NUMCLM: "CLAIM", NUMDEATH: "DEATH" };
const PAGE = 100;

const state = {
  health: null,
  search: null,      // {id, q, rows, shown, done, es}
  person: null,      // {id, ssn, done, es}
};

function esc(s) {
  return String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}
function el(tag, attrs = {}, html = "") {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, v);
  e.innerHTML = html;
  return e;
}
function fmtBytes(n) {
  if (n >= 1 << 30) return (n / (1 << 30)).toFixed(1) + " GB";
  if (n >= 1 << 20) return (n / (1 << 20)).toFixed(0) + " MB";
  if (n >= 1 << 10) return (n / (1 << 10)).toFixed(0) + " KB";
  return n + " B";
}
function fmtDur(s) {
  if (!isFinite(s) || s < 0) return "–";
  s = Math.round(s);
  const m = Math.floor(s / 60), r = s % 60;
  return m >= 60 ? `${Math.floor(m / 60)}h ${m % 60}m` : `${m}:${String(r).padStart(2, "0")}`;
}
function fmtSSN(s) { return /^\d{9}$/.test(s) ? `${s.slice(0, 3)}-${s.slice(3, 5)}-${s.slice(5)}` : s; }
function pill(set) { return `<span class="pill ${esc(set)}">${esc(SET_SHORT[set] || set)}</span>`; }

async function api(method, path, body) {
  const res = await fetch(path, {
    method, headers: body ? { "Content-Type": "application/json" } : {},
    body: body ? JSON.stringify(body) : undefined,
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || res.statusText);
  return data;
}

// ---------- dataset health: banner, set toggles, file picker ----------

function applyHealth(h) {
  state.health = h;
  const rep = h.report;
  const parts = rep.dir.split("/").filter(Boolean);
  $("#datadir").textContent = parts.length > 3 ? "…/" + parts.slice(-2).join("/") : rep.dir;
  $("#datadir").title = rep.dir;
  renderBanner(rep);
  renderSetBoxes(rep);
}

function renderBanner(rep) {
  const banner = $("#banner");
  if (rep.complete) { banner.hidden = true; return; }
  banner.hidden = false;
  banner.classList.toggle("danger", !rep.dirOk);
  $("#banner-title").textContent = rep.dirOk ? "Incomplete dataset" : "Data drive not connected";
  $("#banner-lines").textContent = rep.warnings.join("  ·  ");
  $("#banner-lines").title = rep.warnings.join("\n");
  const rows = rep.sets.map(s => {
    const probs = s.files.filter(f => f.status !== "ok" && f.status !== "missing")
      .map(f => `${String(f.number).padStart(2, "0")}: ${esc(f.problem || f.status)}`).join("<br>");
    return `<tr><td>${pill(s.set)} ${esc(s.label)}</td><td class="mono">${s.present} / ${s.expected}</td>
      <td class="mono">${esc(s.missingStr) || "—"}</td><td>${probs || "—"}</td><td class="mono">${fmtBytes(s.bytes)}</td></tr>`;
  }).join("");
  $("#banner-details").innerHTML = `<table><thead><tr><th>Set</th><th>Present</th><th>Missing</th><th>Problems</th><th>Searchable</th></tr></thead><tbody>${rows}</tbody></table>
    <p class="small muted">Searches use only the files present. Results and person pages say when missing files mean a record might not be shown.</p>
    ${rep.extra && rep.extra.length ? `<p class="small muted">Ignored unexpected files: ${rep.extra.map(esc).join(", ")}</p>` : ""}`;
}

$("#banner-toggle").addEventListener("click", () => {
  const d = $("#banner-details");
  d.hidden = !d.hidden;
  $("#banner-toggle").textContent = d.hidden ? "Details" : "Hide details";
  $("#banner-toggle").setAttribute("aria-expanded", String(!d.hidden));
});

function renderSetBoxes(rep) {
  const prev = selectedSets();
  const boxes = $("#set-boxes");
  boxes.innerHTML = "";
  const lists = $("#file-lists");
  lists.innerHTML = "";
  for (const s of rep.sets) {
    const usable = s.searchable > 0;
    const checked = usable && (prev === null || prev.includes(s.set));
    const partial = usable && s.searchable < s.expected;
    let meta = `${s.searchable} of ${s.expected} files · ${fmtBytes(s.bytes)}`;
    if (!usable) meta = rep.dirOk ? "No files found" : "Folder unavailable";
    else if ((s.missing || []).length) meta += ` · missing ${s.missingStr}`;
    boxes.appendChild(el("label", { class: "setbox" + (usable ? "" : " disabled") + (partial ? " partial" : "") },
      `<input type="checkbox" name="set" value="${s.set}" ${checked ? "checked" : ""} ${usable ? "" : "disabled"}>
       <span><span class="set-name">${esc(s.set)}</span> <span class="muted">${esc(s.label)}</span></span>
       <span class="set-meta">${esc(meta)}</span>`));

    const list = el("div", { class: "filelist" }, `<strong>${esc(s.set)}</strong>`);
    for (const f of s.files) {
      const ok = f.status !== "missing" && f.status !== "empty" && f.status !== "unreadable";
      const tag = f.status === "ok" ? "" : `<span class="tag">${esc(f.status)}</span>`;
      list.appendChild(el("label", { class: ok ? "" : "missing", title: f.problem || "" },
        `<input type="checkbox" name="file" value="${esc(f.name)}" data-set="${s.set}" ${ok ? "checked" : "disabled"}>
         <span class="mono">${esc(f.name)}</span> ${tag}<span class="fsize">${f.size ? fmtBytes(f.size) : ""}</span>`));
    }
    lists.appendChild(list);
  }
}

function selectedSets() {
  const boxes = document.querySelectorAll('input[name=set]');
  if (!boxes.length) return null;
  return [...boxes].filter(b => b.checked).map(b => b.value);
}

function selectedFiles(sets) {
  // Only send an explicit list when the user has unticked something.
  const all = [...document.querySelectorAll('input[name=file]:not(:disabled)')].filter(b => sets.includes(b.dataset.set));
  const on = all.filter(b => b.checked);
  return on.length === all.length ? [] : on.map(b => b.value);
}

// ---------- search ----------

function readQuery() {
  const f = $("#search-form");
  const v = n => String(f.elements[n].value || "").trim();
  const num = n => parseInt(v(n), 10) || 0;
  const sets = selectedSets() || [];
  return {
    sets, files: selectedFiles(sets),
    ssn: v("ssn"), first: v("first"), middle: v("middle"), last: v("last"),
    nameMode: v("nameMode") || "exact", altNames: f.elements.altNames.checked, sex: v("sex"),
    dobFrom: num("dobFrom"), dobTo: num("dobTo"), deathFrom: num("deathFrom"), deathTo: num("deathTo"),
    pobCity: v("pobCity"), pobState: v("pobState"),
    fatherFirst: v("fatherFirst"), fatherLast: v("fatherLast"), motherFirst: v("motherFirst"), motherLast: v("motherLast"),
    limit: num("limit"),
  };
}

function showFormError(msg) {
  const e = $("#form-error");
  e.textContent = msg || "";
  e.hidden = !msg;
}

$("#search-form").addEventListener("submit", async ev => {
  ev.preventDefault();
  showFormError("");
  const q = readQuery();
  if (!q.sets.length) return showFormError("Tick at least one dataset to search.");
  const anyFile = [...document.querySelectorAll('input[name=file]:checked')].some(b => q.sets.includes(b.dataset.set));
  if (!anyFile) return showFormError("No files selected in the ticked datasets.");
  if (location.hash) location.hash = "";
  stopSearch();
  try {
    const r = await api("POST", "/api/search", q);
    startStream(r.id, q);
  } catch (e) {
    showFormError(e.message);
  }
});

$("#btn-clear").addEventListener("click", () => { showFormError(""); });

function stopSearch() {
  if (state.search && state.search.es) state.search.es.close();
  if (state.search && !state.search.done) api("DELETE", `/api/search/${state.search.id}`).catch(() => {});
  state.search = null;
}

function startStream(id, q) {
  const s = { id, q, rows: [], shown: 0, done: false, es: null };
  state.search = s;
  $("#empty").hidden = true;
  $("#progress").hidden = false;
  $("#results").hidden = false;
  $("#res-limit").hidden = true;
  $("#res-table tbody").innerHTML = "";
  $("#btn-more").hidden = true;
  $("#btn-cancel").disabled = false;
  $("#prog-errors").innerHTML = "";
  $("#prog-bar").style.width = "0";
  $("#res-title").textContent = "Results";
  connect(s);
}

function connect(s) {
  const es = new EventSource(`/api/search/${s.id}/events?from=${s.rows.length}`);
  s.es = es;
  es.addEventListener("matches", e => {
    if (state.search !== s) return;
    const m = JSON.parse(e.data);
    if (m.from !== s.rows.length) return; // duplicate after reconnect
    s.rows.push(...m.rows);
    renderRows(s);
  });
  es.addEventListener("progress", e => { if (state.search === s) renderProgress(JSON.parse(e.data), false); });
  es.addEventListener("done", e => {
    es.close();
    if (state.search !== s) return;
    s.done = true;
    const snap = JSON.parse(e.data);
    renderProgress(snap, true);
    finishResults(s, snap);
  });
  es.onerror = () => {
    if (s.done) return;
    if (es.readyState === EventSource.CLOSED) {
      setTimeout(() => { if (state.search === s && !s.done) connect(s); }, 2000);
    }
  };
}

const STATUS_TEXT = {
  running: "Searching…", done: "Search complete", cancelled: "Search cancelled",
  limit: "Stopped at the match limit", error: "Search failed — no file could be read",
};

function headline(p) {
  if (p.status !== "partial") return STATUS_TEXT[p.status] || p.status;
  const what = `${p.filesFailed} of ${p.filesTotal} files could not be read`;
  return p.driveLost ? `Data drive disconnected — ${what}` : `Finished with errors — ${what}`;
}

function renderProgress(p, final) {
  const pct = p.total ? (100 * p.done / p.total) : 100;
  $("#prog-title").textContent = headline(p);
  $("#progress").classList.toggle("failed", p.filesFailed > 0);
  const bar = $("#prog-bar");
  bar.style.width = pct.toFixed(1) + "%";
  $("#prog-fail").style.width = (p.total ? 100 * p.unread / p.total : 0).toFixed(1) + "%";
  bar.parentElement.classList.toggle("done", final && p.status === "done");
  const binary = p.files.length && p.files.every(f => f.method === "binary" || f.state === "skipped");
  let stats;
  if (binary && final) {
    stats = [`SSN lookup in ${p.files.length} files`, `${(p.elapsed * 1000).toFixed(0)} ms`];
  } else {
    stats = [`${pct.toFixed(0)}%`, `${fmtBytes(p.done)} of ${fmtBytes(p.total)}`,
      `${(p.bytesPerSec / 1e6).toFixed(0)} MB/s`, final ? `took ${fmtDur(p.elapsed)}` : `${fmtDur(p.etaSeconds)} left`];
  }
  stats.push(`${p.matches.toLocaleString()} match${p.matches === 1 ? "" : "es"}`);
  $("#prog-stats").textContent = stats.join("  ·  ");
  $("#prog-sets").innerHTML = p.sets.map(sp => {
    const spPct = sp.total ? 100 * sp.done / sp.total : 100;
    const failPct = sp.total ? 100 * sp.unread / sp.total : 0;
    const failed = sp.failed ? ` · <span class="failed-count">${sp.failed} failed</span>` : "";
    return `<span>${pill(sp.set)}</span><div class="bar ${sp.filesDone === sp.files ? "done" : ""}"><div style="width:${spPct.toFixed(1)}%"></div><div class="fail" style="width:${failPct.toFixed(1)}%"></div></div>
      <span>${sp.filesDone}/${sp.files} files${failed} · ${fmtBytes(sp.done)} / ${fmtBytes(sp.total)}</span>`;
  }).join("");
  $("#prog-current").textContent = !final && p.current && p.current.length ? "Reading " + p.current.join(", ") : "";
  $("#prog-errors").innerHTML = (p.errors || []).map(e => `<li>${esc(e.name)}: ${esc(e.error)}</li>`).join("");
  $("#btn-cancel").hidden = final;
}

function rowHTML(r) {
  const parents = [r.father, r.mother].filter(Boolean).join(" / ");
  return `<td>${pill(r.set)}</td><td class="ssn">${esc(fmtSSN(r.ssn))}</td><td title="${esc(r.name)}">${esc(r.name)}</td>
    <td class="num">${esc(r.born)}</td><td title="${esc(r.place)}">${esc(r.place)}</td><td class="dim">${esc(r.sex)}</td><td class="num">${esc(r.died)}</td>
    <td class="dim" title="${esc(parents)}">${esc(parents)}</td><td class="dim" title="${esc(r.entry)}">${esc(r.entry)}</td><td class="num dim">${esc(r.cycle)}</td>`;
}

function appendRows(s, upto) {
  const tbody = $("#res-table tbody");
  const frag = document.createDocumentFragment();
  while (s.shown < s.rows.length && s.shown < upto) {
    const r = s.rows[s.shown++];
    frag.appendChild(el("tr", { "data-ssn": r.ssn, tabindex: "0", title: `${r.file} · byte ${r.offset}` }, rowHTML(r)));
  }
  tbody.appendChild(frag);
}

function renderRows(s) {
  appendRows(s, Math.max(PAGE, s.shown));
  const more = s.rows.length - s.shown;
  $("#btn-more").hidden = more <= 0;
  $("#btn-more").textContent = `Show ${Math.min(PAGE, more)} more (${more.toLocaleString()} not shown)`;
  $("#res-title").textContent = `${s.rows.length.toLocaleString()} result${s.rows.length === 1 ? "" : "s"}${s.done ? "" : " so far"}`;
}

$("#btn-more").addEventListener("click", () => {
  const s = state.search;
  if (!s) return;
  appendRows(s, s.shown + PAGE);
  renderRows(s);
});

function coverageText() {
  const rep = state.health && state.health.report;
  return rep && !rep.complete ? " Note: " + rep.warnings.join("; ") + " — a matching record could be in a missing file." : "";
}

function finishResults(s, snap) {
  renderRows(s);
  const lim = $("#res-limit");
  const pctRead = snap.total ? (100 * snap.done / snap.total).toFixed(0) : 100;
  if (snap.status === "limit") {
    lim.hidden = false;
    lim.innerHTML = `Stopped after ${snap.limit.toLocaleString()} matches (${pctRead}% of the data read). Narrow the search, or
      <button type="button" class="btn-link" id="btn-raise">search again with a limit of ${Math.min(100000, snap.limit * 5).toLocaleString()}</button>.`;
    $("#btn-raise").onclick = () => {
      $("#search-form").elements.limit.value = Math.min(100000, snap.limit * 5);
      $("#search-form").requestSubmit();
    };
  } else if (snap.status === "partial") {
    lim.hidden = false;
    const names = (snap.errors || []).map(e => e.name).join(", ");
    lim.textContent = (snap.driveLost
      ? `The data drive was disconnected during the search. `
      : `Some files could not be read. `) +
      `${snap.filesFailed} of ${snap.filesTotal} files count as not searched (${names}); matches in them are missing from these results.` +
      (snap.driveLost ? " Reconnect the drive, click Rescan and search again." : "");
  } else if (snap.status === "cancelled") {
    lim.hidden = false;
    lim.textContent = `Cancelled after reading ${pctRead}% of the data; the ${s.rows.length.toLocaleString()} matches found so far are shown.`;
  }
  if (snap.driveLost) api("GET", "/api/health").then(applyHealth).catch(() => {});
  if (!s.rows.length && (snap.status === "done" || snap.status === "error" || snap.status === "partial")) {
    $("#res-table tbody").innerHTML = `<tr><td colspan="10" class="empty-row">No matches in the files searched.${esc(coverageText())}</td></tr>`;
  }
}

$("#btn-cancel").addEventListener("click", cancelSearch);
async function cancelSearch() {
  const s = state.search;
  if (!s || s.done) return;
  $("#btn-cancel").disabled = true;
  try { await api("DELETE", `/api/search/${s.id}`); } catch (e) { /* already finished */ }
}

const tbody = $("#res-table tbody");
tbody.addEventListener("click", ev => {
  const tr = ev.target.closest("tr[data-ssn]");
  if (tr && /^\d{9}$/.test(tr.dataset.ssn)) location.hash = "#person/" + tr.dataset.ssn;
});
tbody.addEventListener("keydown", ev => {
  if (ev.key === "Enter") { const tr = ev.target.closest("tr[data-ssn]"); if (tr) tr.click(); }
});

// ---------- person view ----------

window.addEventListener("hashchange", route);

function route() {
  const m = location.hash.match(/^#person\/(\d{9})$/);
  if (m) openPerson(m[1]); else closePerson();
}

function closePerson() {
  if (state.person && state.person.es) state.person.es.close();
  if (state.person && !state.person.done) api("DELETE", `/api/search/${state.person.id}`).catch(() => {});
  state.person = null;
  $("#person-view").hidden = true;
  $("#search-view").hidden = false;
}

$("#btn-back").addEventListener("click", () => { location.hash = ""; });

async function openPerson(ssn) {
  closePerson();
  $("#search-view").hidden = true;
  $("#person-view").hidden = false;
  $(".main").scrollTop = 0;
  $("#person-title").textContent = "SSN " + fmtSSN(ssn);
  $("#person-sub").textContent = "";
  $("#person-body").innerHTML = "";
  $("#person-progress").hidden = false;
  $("#pp-bar").style.width = "0";
  $("#pp-stats").textContent = "";
  const sets = selectedSets() || SETS;
  let r;
  try {
    r = await api("POST", "/api/search", { ssn, sets, limit: 10000 });
  } catch (e) {
    $("#person-body").innerHTML = `<p class="form-error">${esc(e.message)}</p>`;
    $("#person-progress").hidden = true;
    return;
  }
  const p = { id: r.id, ssn, done: false };
  state.person = p;
  const es = new EventSource(`/api/search/${r.id}/events`);
  p.es = es;
  es.addEventListener("progress", e => {
    if (state.person !== p) return;
    const snap = JSON.parse(e.data);
    const pct = snap.total ? 100 * snap.done / snap.total : 100;
    $("#pp-bar").style.width = pct.toFixed(1) + "%";
    const scanning = snap.files.filter(f => f.method === "scan").length;
    $("#pp-title").textContent = scanning ? `Looking up… ${scanning} file(s) must be read in full` : "Looking up…";
    $("#pp-stats").textContent = `${pct.toFixed(0)}%  ·  ${snap.matches} record(s)  ·  ${fmtDur(snap.etaSeconds)} left`;
  });
  es.addEventListener("done", async e => {
    es.close();
    if (JSON.parse(e.data).driveLost) api("GET", "/api/health").then(applyHealth).catch(() => {});
    if (state.person !== p) return;
    p.done = true;
    $("#person-progress").hidden = true;
    try {
      renderPerson(await api("GET", `/api/search/${p.id}/person`));
    } catch (e) {
      $("#person-body").innerHTML = `<p class="form-error">${esc(e.message)}</p>`;
    }
  });
}

$("#pp-cancel").addEventListener("click", () => {
  if (state.person) api("DELETE", `/api/search/${state.person.id}`).catch(() => {});
});

function nm(n) { return n ? [n.first, n.middle, n.last, n.suffix].filter(Boolean).join(" ") : ""; }
function cd(c) { return c && c.code ? (c.desc ? `${c.desc} (${c.code})` : c.code) : ""; }
function kv(pairs) {
  const rows = pairs.filter(([, v]) => v !== undefined && v !== null && v !== "");
  return rows.length ? `<dl class="kv">${rows.map(([k, v]) => `<dt>${esc(k)}</dt><dd>${v}</dd>`).join("")}</dl>` : "";
}
function srcSummary(sources) {
  const counts = {};
  for (const src of sources) {
    const set = src.split(" ")[0];
    counts[set] = (counts[set] || 0) + 1;
  }
  return Object.entries(counts).map(([k, n]) => (SET_SHORT[k] || k) + (n > 1 ? " ×" + n : "")).join(" · ");
}
function variants(f, full) {
  if (!f) return "";
  return f.variants.map(v => `<span class="variant">${esc(v.value)}<span class="src" title="${esc(v.sources.join("\n"))}">${
    esc(full ? v.sources.join("; ") : srcSummary(v.sources))}</span></span>`).join("");
}

function renderPerson(p) {
  const body = $("#person-body");
  const fact = k => p.facts.find(f => f.field === k);
  const name = fact("name") ? fact("name").variants[0].value : "";
  const born = fact("dob") ? fact("dob").variants[0].value : "";
  const died = fact("dod") ? fact("dod").variants[0].value : "";
  $("#person-title").textContent = name || "Unknown name";
  $("#person-sub").textContent = [`SSN ${fmtSSN(p.ssn)}`, born || died ? `${born || "?"} – ${died || ""}` : "",
    `${p.records.length} record${p.records.length === 1 ? "" : "s"}`].filter(Boolean).join("   ·   ");

  let html = "";
  if (!p.records.length) {
    html += `<div class="card"><h2>No records found</h2><p class="muted">Nothing for this SSN in the files searched.</p></div>`;
  }
  const conflicts = p.facts.filter(f => f.conflict);
  if (conflicts.length) {
    html += `<div class="card conflicts"><h2>Records disagree (${conflicts.length})</h2>${conflicts.map(f =>
      `<div class="conflict-item"><strong>${esc(f.label)}</strong>${variants(f, true)}</div>`).join("")}</div>`;
  }
  html += `<div class="person-grid">`;
  html += `<div class="card"><h2>Names</h2>${kv([["Name", variants(fact("name"))], ["Other name used", variants(fact("other"))]]) || '<p class="muted">—</p>'}</div>`;
  html += `<div class="card"><h2>Birth</h2>${kv([["Date", variants(fact("dob"))], ["Place", variants(fact("pob"))], ["Sex", variants(fact("sex"))], ["Race (recorded)", variants(fact("race"))]]) || '<p class="muted">—</p>'}</div>`;
  html += `<div class="card"><h2>Parents</h2>${kv([["Father", variants(fact("father"))], ["Mother", variants(fact("mother"))]]) || '<p class="muted">Not recorded</p>'}</div>`;
  if (fact("dod") || fact("zip")) {
    html += `<div class="card"><h2>Death</h2>${kv([["Date", variants(fact("dod"))], ["Last residence ZIP", variants(fact("zip"))]])}</div>`;
  }
  html += `</div>`;
  if (p.coverage.length) {
    html += `<div class="card coverage"><h2>What was searched</h2><ul>${p.coverage.map(c => `<li>${esc(c)}</li>`).join("")}</ul></div>`;
  }
  html += `<div class="card"><h2>Timeline</h2><ol class="timeline" id="timeline"></ol></div>`;
  body.innerHTML = html;
  const tl = $("#timeline");
  p.records.forEach((r, i) => tl.appendChild(timelineItem(r, i)));
}

function timelineItem(r, i) {
  const li = el("li", { class: r.set });
  const kind = { NUMSS5: "SS-5 application", NUMCLM: (r.entry.code === "D" ? "Death claim" : "Life claim"), NUMDEATH: "Death record" }[r.set];
  const date = r.cycleDate || (r.postings && r.postings[0] && r.postings[0].posted) || "";
  let pairs = [["Name", esc(nm(r.name))], ["Born", esc(r.dob)], ["Sex", esc(cd(r.sex))], ["Entry", esc(cd(r.entry))]];
  if (r.set !== "NUMDEATH") {
    pairs.push(["Birthplace", esc([r.pobCity, r.pobState].filter(Boolean).join(", ") + (r.foreignBorn ? " (foreign born)" : ""))],
      ["Father", esc(nm(r.father))], ["Mother", esc(nm(r.mother))], ["Form", esc(cd(r.formCode))], ["Office code", esc(r.doCode)]);
  }
  if (r.set === "NUMSS5") {
    pairs.push(["Race/ethnicity", esc(cd(r.race))], ["Citizenship", esc(cd(r.citizenship))], ["Evidence", esc(cd(r.interview))],
      ["Other name used", esc(nm(r.otherName))], ["Signature name", esc(nm(r.sigName))], ["Signed by", esc(cd(r.sigCode))],
      ["Prior DOB", esc(r.priorDob)], ["DOB corrected", r.dobChanged ? "yes" : ""]);
  }
  if (r.set === "NUMCLM") {
    pairs.push(["Claim filed", esc(r.claimDate)], ["Date of onset", esc(r.onsetDate)], ["Date of death", esc(r.dodClaim)], ["Field office", esc(r.foAddress)]);
  }
  pairs.push(["Reference no.", esc(r.refNum)], ["Conversion", esc(cd(r.conversion))], ["Logically deleted", r.deleted ? "yes" : ""]);
  let postings = "";
  for (const d of r.postings || []) {
    postings += `<div class="posting"><h4>Death posting ${d.index}${d.dod ? " · died " + esc(d.dod) : ""}</h4>${kv([
      ["Name", esc(nm(d.name))], ["Born", esc(d.dob)], ["Source", esc(cd(d.source))], ["Proof", esc(cd(d.proof))],
      ["Verified EDR", esc(cd(d.verifiedEdr))], ["Programs", esc(cd(d.program))], ["Residence ZIP", esc(d.zipResidence)],
      ["Lump-sum ZIP", esc(d.zipLumpSum)], ["Other number", esc(d.otherNum)], ["Certificate", esc(d.certNum)], ["Posted", esc(d.posted)]])}</div>`;
  }
  li.innerHTML = `<div class="tl-head"><span class="tl-date">${esc(date) || "date unknown"}</span>${pill(r.set)}
      <span class="tl-title">${esc(kind)}</span><span class="muted small">${esc(r.entry.desc || "")}</span></div>
    <div class="tl-body">
      <details><summary>Details</summary>${kv(pairs)}${postings}</details>
      <details><summary>Raw record · ${esc(r.file)} · byte ${r.offset}</summary>${rawOverlay(r)}</details>
    </div>`;
  wireOverlay(li);
  return li;
}

function rawOverlay(r) {
  const raw = r.raw;
  const fields = (r.fields || []).slice().sort((a, b) => a.start - b.start);
  let out = "", pos = 1;
  fields.forEach((f, i) => {
    if (f.start < pos) return;
    out += esc(raw.slice(pos - 1, f.start - 1));
    out += `<span class="f f${i % 6}" data-i="${i}" title="${esc(f.label)} · cols ${f.start}–${f.end} · ${esc(f.value)}">${esc(raw.slice(f.start - 1, f.end))}</span>`;
    pos = f.end + 1;
  });
  out += esc(raw.slice(pos - 1));
  let ruler = "";
  for (let c = 1; c <= raw.length; c += 10) ruler += String(c).padEnd(10, " ");
  const legend = fields.map((f, i) => `<tr data-i="${i}"><td><span class="swatch f${i % 6}"></span></td><td>${f.start}–${f.end}</td><td>${esc(f.label)}</td><td class="mono">${esc(f.value)}</td></tr>`).join("");
  return `<div class="raw"><pre class="ruler">${esc(ruler)}</pre><pre>${out}</pre></div>
    <table class="legend"><tbody>${legend}</tbody></table>`;
}

function wireOverlay(node) {
  const hl = (i, on) => node.querySelectorAll(`[data-i="${i}"]`).forEach(n => n.classList.toggle("hl", on));
  node.addEventListener("mouseover", e => { const t = e.target.closest("[data-i]"); if (t) hl(t.dataset.i, true); });
  node.addEventListener("mouseout", e => { const t = e.target.closest("[data-i]"); if (t) hl(t.dataset.i, false); });
}

// ---------- settings, rescan, quit, keyboard ----------

function openSettings() {
  const f = $("#settings-form");
  const c = state.health.config;
  f.elements.dataDir.value = c.dataDir;
  f.elements.concurrency.value = String(Math.min(4, c.concurrency));
  f.elements.resultLimit.value = c.resultLimit;
  $("#settings-error").hidden = true;
  $("#settings").hidden = false;
  f.elements.dataDir.focus();
}
$("#btn-settings").addEventListener("click", openSettings);
$("#settings-cancel").addEventListener("click", () => { $("#settings").hidden = true; });
$("#settings").addEventListener("click", e => { if (e.target.id === "settings") $("#settings").hidden = true; });
$("#settings-form").addEventListener("submit", async ev => {
  ev.preventDefault();
  const f = ev.target;
  try {
    const h = await api("POST", "/api/settings", {
      dataDir: f.elements.dataDir.value.trim(),
      concurrency: parseInt(f.elements.concurrency.value, 10),
      resultLimit: parseInt(f.elements.resultLimit.value, 10) || 1000,
    });
    applyHealth(h);
    $("#search-form").elements.limit.placeholder = h.config.resultLimit;
    $("#settings").hidden = true;
  } catch (e) {
    $("#settings-error").textContent = e.message;
    $("#settings-error").hidden = false;
  }
});
$("#btn-rescan").addEventListener("click", async () => {
  $("#btn-rescan").disabled = true;
  try { applyHealth(await api("POST", "/api/rescan")); } finally { $("#btn-rescan").disabled = false; }
});
$("#btn-quit").addEventListener("click", async () => {
  if (!confirm("Stop the NUMIDENT Viewer? Any running search will end.")) return;
  await api("POST", "/api/quit").catch(() => {});
  document.body.innerHTML = `<div class="empty"><h2>NUMIDENT Viewer has stopped</h2><p>You can close this tab.</p></div>`;
});

document.addEventListener("keydown", ev => {
  if (ev.key !== "Escape") return;
  if (!$("#settings").hidden) { $("#settings").hidden = true; return; }
  if (!$("#person-view").hidden) {
    if (state.person && !state.person.done) api("DELETE", `/api/search/${state.person.id}`).catch(() => {});
    else location.hash = "";
    return;
  }
  if (state.search && !state.search.done) cancelSearch();
});

// ---------- start ----------

(async function init() {
  try {
    const h = await api("GET", "/api/health");
    applyHealth(h);
    $("#search-form").elements.limit.placeholder = h.config.resultLimit;
  } catch (e) {
    showFormError("Cannot reach the viewer: " + e.message);
  }
  route();
})();
