
// ── VERSION ───────────────────────────────────────────────────────────────────
const ANALYZER_VERSION = "1.6";

// ── STATE ────────────────────────────────────────────────────────────────────
const state = {
  hosts: {},        // { hostname: { manifest, processes, network_tcp, dns_cache } }
  activeHost: null,
  vsInstances: {},  // virtual scroll instances keyed by id
  expandedRows: {}, // { tableId: rowIndex }
};

// ── FILE LOADER ───────────────────────────────────────────────────────────────
function triggerLoad() {
  document.getElementById('fileInput').click();
}

function handleFiles(files) {
  if (!files || !files.length) return;
  showProgress('Loading 0 / ' + files.length, 0);
  let done = 0;
  Array.from(files).forEach(f => {
    loadJsonFile(f, () => {
      done++;
      setProgress(done / files.length * 100);
      setProgressLabel('Loading ' + done + ' / ' + files.length);
      if (done === files.length) {
        hideProgress();
        refreshAll();
      }
    });
  });
}

function loadJsonFile(file, onDone) {
  if (file.size > 10 * 1024 * 1024) {
    console.warn('Large file: ' + file.name + ' (' + (file.size / 1024 / 1024).toFixed(1) + ' MB)');
  }
  const reader = new FileReader();
  reader.onload = e => {
    try {
      const data = JSON.parse(e.target.result);
      const host = (data.manifest && data.manifest.hostname) ? data.manifest.hostname : file.name.replace(/\.json$/i,'');
      // Normalize new JSON keys (v2.0) with backwards compat for old format
      data.processes   = data.Processes   || data.processes   || [];
      data.network_tcp = (data.Network && data.Network.tcp) || data.network_tcp || [];
      data.dns_cache   = (data.Network && data.Network.dns) || data.dns_cache   || [];
      // Expose Network_source from manifest for fleet/manifest panel
      state.hosts[host] = data;
      if (!state.activeHost) state.activeHost = host;
    } catch(ex) {
      console.error('Parse error in ' + file.name + ': ' + ex.message);
    }
    onDone();
  };
  reader.onerror = () => { console.error('Read error: ' + file.name); onDone(); };
  reader.readAsText(file);
}

// ── DRAG & DROP ───────────────────────────────────────────────────────────────
(function initDrop() {
  const dz = document.getElementById('drop-zone');
  document.addEventListener('dragover',  e => { e.preventDefault(); dz.classList.add('show'); });
  document.addEventListener('dragleave', e => { if (!e.relatedTarget) dz.classList.remove('show'); });
  document.addEventListener('drop', e => {
    e.preventDefault();
    dz.classList.remove('show');
    handleFiles(e.dataTransfer.files);
  });
})();

// ── PROGRESS ─────────────────────────────────────────────────────────────────
function showProgress(label, pct) {
  document.getElementById('progress-overlay').classList.add('show');
  setProgressLabel(label); setProgress(pct);
}
function hideProgress() { document.getElementById('progress-overlay').classList.remove('show'); }
function setProgress(pct) { document.getElementById('progress-bar').style.width = pct + '%'; }
function setProgressLabel(t) { document.getElementById('progress-label').textContent = t; }

// ── REFRESH ALL ───────────────────────────────────────────────────────────────
function refreshAll() {
  const ph = document.getElementById('placeholder');
  if (Object.keys(state.hosts).length > 0) {
    ph.classList.remove('show');
  }
  rebuildHostSelector();
  updateBadges();
  updateMeta();
  renderActiveTab();
}

function rebuildHostSelector() {
  const sel = document.getElementById('hostSelector');
  sel.innerHTML = '';
  Object.keys(state.hosts).forEach(h => {
    const o = document.createElement('option');
    o.value = h; o.textContent = h;
    if (h === state.activeHost) o.selected = true;
    sel.appendChild(o);
  });
}

function switchHost(h) {
  if (!h || !state.hosts[h]) return;
  state.activeHost = h;
  state.expandedRows = {};
  updateBadges();
  updateMeta();
  renderActiveTab();
}

function activeData() { return state.activeHost ? state.hosts[state.activeHost] : null; }

function updateBadges() {
  const d = activeData();
  if (!d) { ['b-procs','b-active','b-ips','b-dns'].forEach(id => el(id).textContent = '0'); return; }
  el('b-procs').textContent  = d.processes ? d.processes.length : 0;
  const active = (d.network_tcp || []).filter(c => c.State === 'ESTABLISHED').length;
  el('b-active').textContent = active;
  const ips = new Set((d.network_tcp || []).filter(c => c.RemoteAddress && c.RemoteAddress !== '0.0.0.0' && c.RemoteAddress !== '::').map(c => c.RemoteAddress));
  el('b-ips').textContent   = ips.size;
  const matches = (d.network_tcp || []).filter(c => c.DnsMatch).length;
  el('b-dns').textContent   = matches;
}

function updateMeta() {
  const d = activeData();
  if (!d || !d.manifest) { el('collectionMeta').textContent = ''; return; }
  const m = d.manifest;
  el('collectionMeta').textContent =
    (m.collection_time_utc || '') + '  |  ' +
    (m.target_os_caption || m.target_os_version || '') + '  |  ' +
    'PS ' + (m.target_ps_version || '?') + '  |  ' +
    (m.Network_source ? (m.Network_source.network || '') : (m.network_source || '')) + '/' + (m.Network_source ? (m.Network_source.dns || '') : (m.dns_source || ''));
}

// ── TAB ROUTER ────────────────────────────────────────────────────────────────
let activeTab = 'fleet';
function switchTab(tab) {
  activeTab = tab;
  document.querySelectorAll('.tab-btn').forEach(b => b.classList.remove('active'));
  document.querySelectorAll('.tab-panel').forEach(p => p.classList.remove('active'));
  el('tab-' + tab).classList.add('active');
  el('panel-' + tab).classList.add('active');
  renderActiveTab();
}

function renderActiveTab() {
  switch(activeTab) {
    case 'fleet':     renderFleet();     break;
    case 'processes': renderProcesses(); break;
    case 'network':   renderNetwork();   break;
    case 'dns':       renderDns();       break;
  }
}

// ── VIRTUAL SCROLL ENGINE ─────────────────────────────────────────────────────
const ROW_H    = 28;
const BUFFER   = 20;
const MAX_ROWS = 60;

function createVS(containerId, columns, data, rowRenderer, onRowClick) {
  const wrap = el(containerId);
  if (!wrap) return null;
  wrap.innerHTML = '';

  const viewport = document.createElement('div');
  viewport.className = 'vscroll-viewport';
  viewport.style.maxHeight = '480px';
  const inner = document.createElement('div');
  inner.className = 'vscroll-inner';
  inner.style.height = (data.length * ROW_H) + 'px';
  viewport.appendChild(inner);
  wrap.appendChild(viewport);

  let lastStart = -1;
  function render() {
    const scrollTop = viewport.scrollTop;
    const visH      = viewport.clientHeight;
    const start     = Math.max(0, Math.floor(scrollTop / ROW_H) - BUFFER);
    const end       = Math.min(data.length, Math.ceil((scrollTop + visH) / ROW_H) + BUFFER);
    if (start === lastStart && inner.children.length > 0) return;
    lastStart = start;

    // Remove nodes outside range
    Array.from(inner.children).forEach(n => {
      const idx = parseInt(n.dataset.idx);
      if (idx < start || idx >= end) n.remove();
    });

    // Add missing nodes
    const existing = new Set(Array.from(inner.children).map(n => parseInt(n.dataset.idx)));
    for (let i = start; i < end && (i - start) < MAX_ROWS; i++) {
      if (existing.has(i)) continue;
      const row = document.createElement('div');
      row.className = 'vrow';
      row.dataset.idx = i;
      row.style.top = (i * ROW_H) + 'px';
      row.style.gridTemplateColumns = columns;
      row.innerHTML = rowRenderer(data[i], i);
      row.addEventListener('click', ev => {
        if (ev.target.classList.contains('link')) return;
        onRowClick(i, data[i], row);
      });
      inner.appendChild(row);
    }
  }

  viewport.addEventListener('scroll', render);
  setTimeout(render, 0);

  return { viewport, inner, render, data,
    scrollToIndex(idx) {
      viewport.scrollTop = idx * ROW_H;
      setTimeout(render, 50);
    },
    update(newData) {
      this.data = newData;
      inner.style.height = (newData.length * ROW_H) + 'px';
      inner.innerHTML = '';
      lastStart = -1;
      render();
    }
  };
}

// ── GLOBAL SEARCH ─────────────────────────────────────────────────────────────
function onGlobalSearch(q) {
  const panel = el('gsearch-panel');
  if (!q || q.length < 2) { panel.classList.remove('show'); panel.innerHTML = ''; return; }
  const d = activeData();
  if (!d) { panel.classList.remove('show'); return; }
  const lq = q.toLowerCase();

  const pMatches = (d.processes || []).filter(p =>
    str(p.Name).includes(lq) || str(p.ProcessId).includes(lq) ||
    str(p.ExecutablePath).includes(lq) || str(p.CommandLine).includes(lq)
  ).slice(0, 20);

  const nMatches = (d.network_tcp || []).filter(c =>
    str(c.RemoteAddress).includes(lq) || str(c.RemotePort).includes(lq) ||
    str(c.LocalAddress).includes(lq)  || str(c.LocalPort).includes(lq) ||
    str(c.State).includes(lq)         || str(c.DnsMatch).includes(lq) ||
    str(c.ReverseDns).includes(lq)    || str(c.InterfaceAlias).includes(lq)
  ).slice(0, 20);

  const dMatches = (d.dns_cache || []).filter(e =>
    str(e.Entry).includes(lq) || str(e.Data).includes(lq)
  ).slice(0, 20);

  if (!pMatches.length && !nMatches.length && !dMatches.length) {
    panel.innerHTML = '<div class="gs-empty">No results</div>';
    panel.classList.add('show');
    return;
  }

  let html = '';
  if (pMatches.length) {
    html += '<div class="gs-section">Processes (' + pMatches.length + ')</div>';
    pMatches.forEach((p, i) => {
      html += `<div class="gs-row" onclick="gotoProcess(${p.ProcessId})">
        <div class="gs-main">${esc(p.Name)} [PID ${p.ProcessId}]</div>
        <div class="gs-sub">${esc(p.ExecutablePath || p.CommandLine || '')}</div>
      </div>`;
    });
  }
  if (nMatches.length) {
    html += '<div class="gs-section">Network (' + nMatches.length + ')</div>';
    nMatches.forEach(c => {
      const pname = getProcName(c.OwningProcess, d);
      html += `<div class="gs-row" onclick="gotoNetwork('${esc(c.RemoteAddress)}')">
        <div class="gs-main">${esc(c.RemoteAddress)}:${c.RemotePort} ← ${esc(pname)}</div>
        <div class="gs-sub">${esc(c.State)} ${esc(c.DnsMatch || c.ReverseDns || '')}</div>
      </div>`;
    });
  }
  if (dMatches.length) {
    html += '<div class="gs-section">DNS (' + dMatches.length + ')</div>';
    dMatches.forEach(e => {
      html += `<div class="gs-row" onclick="switchTab('dns')">
        <div class="gs-main">${esc(e.Entry)}</div>
        <div class="gs-sub">${esc(e.Data || '')}</div>
      </div>`;
    });
  }

  panel.innerHTML = html;
  panel.classList.add('show');
}

function closeGSearch() {
  el('gsearch-panel').classList.remove('show');
  el('globalSearch').value = '';
}

document.addEventListener('click', e => {
  const gs = el('gsearch-panel');
  if (gs && !gs.contains(e.target) && e.target.id !== 'globalSearch') {
    gs.classList.remove('show');
  }
});

// ── HELPERS ───────────────────────────────────────────────────────────────────
function el(id) { return document.getElementById(id); }
function esc(s) { return String(s||'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;'); }
function str(v) { return v == null ? '' : String(v).toLowerCase(); }
function trunc(s, n) { s = String(s||''); return s.length > n ? s.slice(0,n-1)+'…' : s; }

// Returns ordered list of adapter InterfaceAlias values from active host manifest
function getAdapterAliases() {
  const d = activeData();
  if (!d || !d.manifest || !d.manifest.network_adapters) return [];
  return d.manifest.network_adapters.map(a => a.InterfaceAlias || a.AdapterName || '').filter(Boolean);
}

// Returns a CSS color string for a given InterfaceAlias value
function ifaceColor(alias, adapterAliases) {
  if (!alias) return 'var(--muted)';
  if (alias === 'ALL_INTERFACES') return 'var(--amber)';
  if (alias === 'LOOPBACK')       return 'var(--muted)';
  if (alias === 'UNKNOWN')        return 'var(--red)';
  const idx = (adapterAliases || []).indexOf(alias);
  if (idx === 0) return 'var(--accent)';
  if (idx === 1) return 'var(--green)';
  return 'var(--text)';
}
function getProcName(pid, data) {
  if (!data || !data.processes) return String(pid);
  const p = data.processes.find(p => p.ProcessId == pid);
  return p ? p.Name : String(pid);
}
function gotoProcess(pid) {
  closeGSearch();
  switchTab('processes');
  setTimeout(() => highlightProcessPid(pid), 100);
}
function gotoNetwork(ip) {
  closeGSearch();
  switchTab('network');
  setTimeout(() => highlightNetworkIp(ip), 100);
}

// Placeholder will be hidden once files load; auto-trigger picker on init
window.addEventListener('load', () => {
  setTimeout(() => {
    document.getElementById('fileInput').click();
  }, 100);
});

