// CodexBar popup frontend. Talks to Rust only via Tauri IPC:
//   invoke('state')  → RenderState snapshot (in-memory, cheap)
//   invoke('cost')   → /cost proxy, cached Rust-side for 120s
//   invoke('open_url' | 'hide_popup' | 'quit_app')
// Field names mirror src/client.rs serialization (camelCase).

const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;

// TODO(upstream): expose dashboard/status URLs in
// `codexbar config providers --format json` instead of this map
// (they exist in Sources/CodexBarCore/Providers/*/…ProviderDescriptor.swift).
const URLS = {
  codex: {
    dashboard: 'https://chatgpt.com/codex/settings/usage',
    status: 'https://status.openai.com/',
  },
  claude: {
    dashboard: 'https://claude.ai/settings/usage',
    status: 'https://status.claude.com/',
  },
};

let state = null;       // RenderState from Rust
let costs = null;       // Vec<CostReport> from Rust
let costError = null;
let selected = null;    // provider id of the active tab

const $ = (id) => document.getElementById(id);

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

// ---- formatting helpers ----------------------------------------------------

function fmtTokens(n) {
  if (n == null) return null;
  if (n >= 1e9) return (n / 1e9).toFixed(1) + 'B';
  if (n >= 1e6) return (n / 1e6).toFixed(1) + 'M';
  if (n >= 1e3) return (n / 1e3).toFixed(1) + 'K';
  return String(n);
}

function fmtUSD(v) {
  if (v == null) return null;
  return '$' + v.toFixed(2);
}

function humanizeSecs(secs) {
  const d = Math.floor(secs / 86400);
  const h = Math.floor((secs % 86400) / 3600);
  const m = Math.floor((secs % 3600) / 60);
  if (d > 0) return `${d}d ${h}h`;
  if (h > 0) return `${h}h ${m}m`;
  if (m > 0) return `${m}m`;
  return 'under 1m';
}

function agoText(secs) {
  if (secs < 10) return 'just now';
  if (secs < 90) return `${Math.floor(secs)}s ago`;
  if (secs < 3600) return `${Math.floor(secs / 60)}m ago`;
  return `${Math.floor(secs / 3600)}h ago`;
}

// Mirrors menu.rs window_label, with popup-friendly names.
function windowLabel(minutes, slot) {
  if (minutes == null) {
    return ['Session', 'Weekly', 'Monthly'][slot] || 'Window';
  }
  if (minutes >= 40000) return 'Monthly';
  if (minutes >= 9000) return 'Weekly';
  if (minutes >= 1440) return `${Math.ceil(minutes / 1440)}-day`;
  if (slot === 0) return `Session (${Math.ceil(minutes / 60)}h)`;
  if (minutes >= 60) return `${Math.ceil(minutes / 60)}h`;
  return `${minutes}m`;
}

function resetText(w) {
  if (w.resetsAt) {
    const at = Date.parse(w.resetsAt);
    if (!Number.isNaN(at)) {
      const secs = (at - Date.now()) / 1000;
      return secs <= 0 ? 'Resets now' : `Resets in ${humanizeSecs(secs)}`;
    }
  }
  return w.resetDescription ? `Resets ${w.resetDescription}` : '';
}

function fillClass(percent, grey) {
  if (grey) return 'fill-stale';
  if (percent > 85) return 'fill-crit';
  if (percent > 60) return 'fill-warn';
  return 'fill-ok';
}

// Displayable rate windows of a row, in slot order (mirrors client.rs windows()).
function windowsOf(row) {
  const u = row.usage;
  if (!u) return [];
  return [u.primary, u.secondary, u.tertiary]
    .map((w, slot) => ({ w, slot }))
    .filter(({ w }) => w && !w.isSyntheticPlaceholder && w.usedPercent != null);
}

function worstPercent(row) {
  const ps = windowsOf(row).map(({ w }) => w.usedPercent);
  return ps.length ? Math.max(...ps) : null;
}

function displayName(provider) {
  return (state && state.names && state.names[provider])
    || provider.charAt(0).toUpperCase() + provider.slice(1);
}

// ---- rendering -------------------------------------------------------------

function render() {
  const rows = (state && state.rows) || [];
  if (!rows.some((r) => r.provider === selected)) {
    selected = rows.length ? rows[0].provider : null;
  }
  renderTabs(rows);
  renderCard(rows.find((r) => r.provider === selected));
  renderLinks();
}

function renderTabs(rows) {
  const tabs = $('tabs');
  tabs.replaceChildren();
  for (const row of rows) {
    const tab = el('button', 'tab' + (row.provider === selected ? ' active' : ''));
    tab.appendChild(el('span', 'name', displayName(row.provider)));
    const mini = el('span', 'mini');
    const fill = el('i');
    const worst = worstPercent(row);
    const grey = row.stale || (row.error && worst == null);
    fill.className = fillClass(worst ?? 0, grey);
    fill.style.width = `${Math.min(100, Math.max(0, worst ?? 0))}%`;
    mini.appendChild(fill);
    tab.appendChild(mini);
    tab.addEventListener('click', () => { selected = row.provider; render(); });
    tabs.appendChild(tab);
  }
}

function renderCard(row) {
  const main = $('main');
  main.replaceChildren();

  if (!row) {
    const msg = state && state.status
      ? `⚠ ${state.status}`
      : (state && state.serveUp ? 'Fetching usage…' : 'Starting codexbar serve…');
    main.appendChild(el('div', 'placeholder', msg));
    return;
  }

  const card = el('div', 'card');

  // Head: name, plan badge, stale badge.
  const head = el('div', 'card-head');
  head.appendChild(el('h2', null, displayName(row.provider)));
  const plan = row.usage
    && (row.usage.loginMethod || (row.usage.identity && row.usage.identity.loginMethod));
  if (plan) head.appendChild(el('span', 'badge', plan));
  if (row.stale) head.appendChild(el('span', 'badge stale', 'stale'));
  card.appendChild(head);

  // "Updated Xs ago" — per-provider timestamp, falling back to global fetch age.
  let updated = null;
  if (row.usage && row.usage.updatedAt) {
    const at = Date.parse(row.usage.updatedAt);
    if (!Number.isNaN(at)) updated = agoText((Date.now() - at) / 1000);
  }
  if (updated == null && state.lastFetchSecsAgo != null) {
    updated = agoText(state.lastFetchSecsAgo);
  }
  if (updated) card.appendChild(el('div', 'updated', `Updated ${updated}`));

  // Error / stale banner.
  if (row.error) {
    const msg = row.error.message || 'provider fetch failed';
    const suffix = row.stale ? ' — showing last known data' : '';
    card.appendChild(el('div', 'banner', `⚠ ${msg}${suffix}`));
  }

  // One section per rate window.
  const wins = windowsOf(row);
  if (!wins.length && !row.error) {
    card.appendChild(el('div', 'cost-note', 'No usage data reported.'));
  }
  for (const { w, slot } of wins) {
    const percent = Math.min(100, Math.max(0, w.usedPercent));
    const section = el('div', 'window');

    const row1 = el('div', 'row1');
    row1.appendChild(el('span', 'label', windowLabel(w.windowMinutes, slot)));
    row1.appendChild(el('span', 'reset', resetText(w)));
    section.appendChild(row1);

    const bar = el('div', 'bar');
    const fill = el('i');
    fill.className = fillClass(percent, row.stale);
    fill.style.width = `${percent}%`;
    bar.appendChild(fill);
    section.appendChild(bar);

    const row2 = el('div', 'row2');
    row2.appendChild(el('span', 'pct', `${Math.round(w.usedPercent)}% used`));
    section.appendChild(row2);

    // Pace maps by slot: primary window ↔ pace.primary, secondary ↔ pace.secondary.
    const pace = row.pace && [row.pace.primary, row.pace.secondary][slot];
    if (pace && pace.summary) {
      section.appendChild(el('div', 'pace', pace.summary.startsWith('Pace')
        ? pace.summary
        : `Pace: ${pace.summary}`));
    }
    card.appendChild(section);
  }

  renderCost(card, row.provider);
  main.appendChild(card);
}

function renderCost(card, provider) {
  card.appendChild(el('div', 'section-title', 'Cost'));

  if (!costs) {
    card.appendChild(el('div', 'cost-note',
      costError ? `Cost unavailable: ${costError}` : 'Loading cost…'));
    return;
  }
  const report = costs.find((c) => c.provider === provider);
  if (!report || (report.error && !report.daily.length && !report.totals)) {
    card.appendChild(el('div', 'cost-note', 'No local cost data for this provider.'));
    return;
  }

  const today = new Date().toLocaleDateString('en-CA'); // local YYYY-MM-DD
  const todayEntry = report.daily.find((d) => d.date === today);
  // Dollar amounts serialize under "totalCost" (upstream key, kept by client.rs).
  addCostRow(card, 'Today',
    todayEntry ? todayEntry.totalCost : null,
    todayEntry ? todayEntry.totalTokens : null);

  const totals = report.totals || {};
  addCostRow(card, `Last ${report.historyDays || 30} days`,
    report.last30DaysCostUSD ?? totals.totalCost,
    report.last30DaysTokens ?? totals.totalTokens);
}

function addCostRow(card, label, usd, tokens) {
  const parts = [];
  const money = fmtUSD(usd);
  const toks = fmtTokens(tokens);
  if (money) parts.push(money);
  if (toks) parts.push(`${toks} tokens`);
  const rowEl = el('div', 'cost-row');
  rowEl.appendChild(el('span', 'k', label));
  rowEl.appendChild(el('span', 'v', parts.length ? parts.join(' · ') : '—'));
  card.appendChild(rowEl);
}

function renderLinks() {
  const urls = URLS[selected] || {};
  $('link-dashboard').hidden = !urls.dashboard;
  $('link-status').hidden = !urls.status;
}

// ---- data + events ---------------------------------------------------------

async function refreshState() {
  try {
    state = await invoke('state');
  } catch (e) {
    state = { rows: [], names: {}, status: String(e), serveUp: false };
  }
  render();
}

async function refreshCost() {
  try {
    costs = await invoke('cost');
    costError = null;
  } catch (e) {
    costs = null;
    costError = String(e);
  }
  render();
}

function refreshAll() {
  refreshState();
  refreshCost();
}

$('close').addEventListener('click', () => invoke('hide_popup'));
$('link-quit').addEventListener('click', () => invoke('quit_app'));
$('link-settings').addEventListener('click', () => {
  const note = $('settings-note');
  note.hidden = !note.hidden;
});
for (const key of ['dashboard', 'status']) {
  $(`link-${key}`).addEventListener('click', () => {
    const url = (URLS[selected] || {})[key];
    if (url) invoke('open_url', { url });
  });
}
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') invoke('hide_popup');
});

listen('state-updated', refreshState);
listen('popup-shown', refreshAll);
window.addEventListener('focus', refreshAll);

// Countdown / "updated ago" ticker; re-pull the cheap state snapshot when focused.
setInterval(() => {
  if (document.hasFocus()) refreshState();
  else render();
}, 20000);

refreshAll();
