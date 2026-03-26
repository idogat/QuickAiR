// ╔══════════════════════════════════════╗
// ║  Quicker — 03_core.js                ║
// ║  Global state, file loader, chunked  ║
// ║  FileReader, tab router, virtual     ║
// ║  scroll engine, sort engine, resize  ║
// ║  handles, global search, drag-drop,  ║
// ║  host management                     ║
// ╠══════════════════════════════════════╣
// ║  Reads    : JSON files via FileReader ║
// ║  Writes   : fleetIndex, activeHost,   ║
// ║             userIndex, sortState,     ║
// ║             colWidths                 ║
// ║  Functions: el, esc, str, triggerLoad,║
// ║    handleFiles, loadJsonFile,         ║
// ║    switchHost, removeHost, activeData,║
// ║    switchTab, renderActiveTab,        ║
// ║    createVS, sortTable, applySortTo-  ║
// ║    Rows, addResizeHandles, updateBad- ║
// ║    ges, updateMeta, onGlobalSearch,   ║
// ║    buildUserIndex, rebuildUserIndex,  ║
// ║    navigateToRow, gotoProcess,        ║
// ║    gotoNetwork, getAdapterAliases,    ║
// ║    ifaceColor, getProcName, fmtUTC,   ║
// ║    fmtBytes, trunc                    ║
// ║  Depends  : 02_shell.html (DOM)       ║
// ║  Version  : 3.41                      ║
// ╚══════════════════════════════════════╝

// ── VERSION ───────────────────────────────────────────────────────────────────
const ANALYZER_VERSION = "3.6";

// ── STATE ────────────────────────────────────────────────────────────────────
const state = {
  hosts: {},        // { hostname: { manifest, processes, network_tcp, network_udp, dns_cache, network_adapters } }
  activeHost: null,
  vsInstances: {},  // virtual scroll instances keyed by id
  expandedRows: {}, // { tableId: rowIndex }
  filtered: {},     // { tab: sortedRows[] } for sortTable
  executions: {},   // { hostname: executionResultObj } from *_execution_*.json
};

// ── SORT/RESIZE CSS ───────────────────────────────────────────────────────────
(function injectSortResizeCSS() {
  const s = document.createElement('style');
  s.textContent = `
    .sortable-th { cursor: pointer; user-select: none; }
    .sort-arrow { color: var(--muted); font-size: 0.8em; }
    .sort-arrow.asc { color: var(--accent); }
    .sort-arrow.desc { color: var(--accent); }
  `;
  document.head.appendChild(s);
})();

(function injectHostSelectorCSS() {
  const s = document.createElement('style');
  s.textContent = `
    .host-selector-wrap{position:relative;display:inline-block;vertical-align:middle}
    .host-selector-current{background:var(--surface);border:1px solid var(--border);color:var(--text);padding:4px 22px 4px 8px;font-family:inherit;font-size:12px;border-radius:3px;cursor:pointer;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:260px;min-width:140px;display:inline-block;position:relative}
    .host-selector-current:after{content:'▾';position:absolute;right:5px;top:50%;transform:translateY(-50%);color:var(--muted);pointer-events:none}
    .host-selector-current:hover{border-color:var(--accent)}
    .host-dropdown{position:absolute;top:calc(100% + 2px);left:0;z-index:200;background:var(--surface);border:1px solid var(--border);border-radius:4px;min-width:220px;max-height:300px;overflow-y:auto;box-shadow:0 4px 12px rgba(0,0,0,.5)}
    .host-dropdown-item{display:flex;align-items:center;gap:6px;padding:5px 8px;border-bottom:1px solid var(--border)}
    .host-dropdown-item:last-child{border-bottom:none}
    .host-dropdown-item:hover{background:var(--row-hov)}
    .host-dropdown-item.active .host-name{color:var(--accent)}
    .host-name{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:12px;cursor:pointer}
    .host-name:hover{color:var(--accent)}
    .host-rm-btn{background:none!important;border:none!important;color:var(--muted);padding:2px 4px;cursor:pointer;font-size:13px;flex-shrink:0;line-height:1}
    .host-rm-btn:hover{color:var(--red)!important}
    .host-rm-confirm{color:var(--red)!important;border-color:var(--red)!important;font-size:10px;padding:1px 5px}
    .host-rm-cancel{font-size:10px;padding:1px 5px}
    .fleet-rm-cell{display:flex!important;align-items:center;justify-content:center;cursor:pointer;color:var(--muted);font-size:14px}
    .fleet-rm-cell:hover{color:var(--red)}
    .fleet-rm-confirm{color:var(--red)!important;border-color:var(--red)!important;font-size:10px;padding:1px 4px}
    .fleet-rm-cancel{font-size:10px;padding:1px 4px}
  `;
  document.head.appendChild(s);
})();

// ── SORT STATE ────────────────────────────────────────────────────────────────
const sortState = { tab: null, column: null, dir: 'none' };

function sortTable(tab, colKey, numeric) {
  if (sortState.tab === tab && sortState.column === colKey) {
    if (sortState.dir === 'none') sortState.dir = 'asc';
    else if (sortState.dir === 'asc') sortState.dir = 'desc';
    else sortState.dir = 'none';
  } else {
    sortState.tab = tab; sortState.column = colKey; sortState.dir = 'asc';
  }
  // Update arrow indicators
  document.querySelectorAll('.sort-arrow').forEach(el => {
    el.classList.remove('asc','desc');
    el.textContent = '⇅';
  });
  const arrowEl = document.getElementById('sort-' + tab + '-' + colKey);
  if (arrowEl) {
    if (sortState.dir === 'asc')  { arrowEl.textContent = '↑'; arrowEl.classList.add('asc'); }
    if (sortState.dir === 'desc') { arrowEl.textContent = '↓'; arrowEl.classList.add('desc'); }
  }
  // Re-render the tab
  switch(tab) {
    case 'processes': applyProcFilters(); break;
    case 'network':   applyNetFilters();  break;
    case 'dns':       applyDnsFilters();  break;
    case 'dlls':      applyDllFilters();  break;
    case 'fleet':     renderFleet();      break;
    case 'users':     usersApplyFilters(); break;
  }
}

function makeSortHeader(label, tab, colKey, numeric) {
  return `<th class="sortable-th" onclick="sortTable('${tab}','${colKey}',${numeric?'true':'false'})">` +
    `${esc(label)} <span class="sort-arrow" id="sort-${tab}-${colKey}">⇅</span></th>`;
}

function applySortToRows(rows, colKey, numeric) {
  if (!sortState.dir || sortState.dir === 'none') return rows;
  const dir = sortState.dir === 'asc' ? 1 : -1;
  return rows.slice().sort((a, b) => {
    const av = a[colKey]; const bv = b[colKey];
    if (numeric) {
      const an = parseFloat(av ?? -1);
      const bn = parseFloat(bv ?? -1);
      return (an - bn) * dir;
    }
    if (av == null && bv == null) return 0;
    if (av == null) return 1;
    if (bv == null) return -1;
    return String(av).localeCompare(String(bv)) * dir;
  });
}

// ── RESIZABLE COLUMNS ─────────────────────────────────────────────────────────
// colWidths[tabName] = [w0, w1, ...] in pixels — source of truth for grid-template-columns
const colWidths = {};

// VS container IDs per tabName
const VS_IDS  = { processes:'proc-vs', network:'net-vs', dns:'dns-vs', dlls:'dlls-vs', fleet:'fleet-vs', users:'users-vs' };
const HDR_IDS = { processes:'proc-header', network:'net-header', dns:'dns-header', dlls:'dlls-header', fleet:'fleet-header', users:'users-header' };

// Apply current colWidths[tabName] as grid-template-columns to header + all visible vrows
function _applyGridTemplate(tabName) {
  const widths = colWidths[tabName];
  if (!widths || !widths.length) return;
  const template = widths.map(function(w) { return w + 'px'; }).join(' ');
  const hdr = document.getElementById(HDR_IDS[tabName]);
  if (hdr) hdr.style.gridTemplateColumns = template;
  const vsEl = document.getElementById(VS_IDS[tabName]);
  if (vsEl) vsEl.querySelectorAll('.vrow').forEach(function(row) {
    row.style.gridTemplateColumns = template;
  });
}

function addResizeHandles(headerId, tabName) {
  const header = document.getElementById(headerId);
  if (!header) return;
  const ths = header.querySelectorAll('.th');
  if (!ths.length) return;

  // Initialize pixel widths: sessionStorage first, then offsetWidth
  const widths = Array.from(ths).map(function(th, i) {
    const saved = sessionStorage.getItem('colWidth_' + tabName + '_' + i);
    return saved ? parseInt(saved, 10) : th.offsetWidth;
  });
  colWidths[tabName] = widths;

  // Apply initial grid template (converts any 1fr to measured px)
  _applyGridTemplate(tabName);

  ths.forEach(function(th, colIndex) {
    // Remove existing handle to avoid duplicates on re-render
    var existing = th.querySelector('.resizer');
    if (existing) existing.remove();
    var handle = document.createElement('div');
    handle.className = 'resizer';
    th.appendChild(handle);

    handle.addEventListener('mousedown', function(e) {
      e.preventDefault();
      e.stopPropagation();
      handle.classList.add('resizing');
      var startX = e.clientX;
      var startW = widths[colIndex];

      function onMove(ev) {
        var newW = Math.max(40, startW + (ev.clientX - startX));
        widths[colIndex] = newW;
        sessionStorage.setItem('colWidth_' + tabName + '_' + colIndex, newW);
        _applyGridTemplate(tabName);
      }
      function onUp() {
        handle.classList.remove('resizing');
        document.removeEventListener('mousemove', onMove);
        document.removeEventListener('mouseup', onUp);
      }
      document.addEventListener('mousemove', onMove);
      document.addEventListener('mouseup', onUp);
    });

    // Always stop click from bubbling to th — prevents sort on handle click
    handle.addEventListener('click', function(e) {
      e.stopPropagation();
    });
  });
}

// no-op: addResizeHandles now handles restoration from sessionStorage
function restoreColWidths(tabName, headerId) {}

// Re-apply grid-template-columns to all vrows after virtual scroll render
function reapplyColWidthsFromStorage(tabName, vsEl) {
  if (!tabName || !vsEl) return;
  var widths = colWidths[tabName];
  if (!widths || !widths.length) return;
  var template = widths.map(function(w) { return w + 'px'; }).join(' ');
  vsEl.querySelectorAll('.vrow').forEach(function(row) {
    row.style.gridTemplateColumns = template;
  });
}

// ── CROSS-HOST USER INDEX ─────────────────────────────────────────────────────
function buildUserIndex(allHosts) {
  const idx = {};

  allHosts.forEach(host => {
    const u = host.Users;
    if (!u) return;
    const hostname = host.manifest ? host.manifest.hostname : '?';

    // Index users by SID
    if (u.users) {
      u.users.forEach(user => {
        const key = user.SID;
        if (!key) return;
        if (!idx[key]) {
          idx[key] = {
            SID:         user.SID,
            Username:    user.Username,
            Domain:      user.Domain,
            AccountType: user.AccountType,
            SIDMetadata: user.SIDMetadata,
            domainInfo:  null,
            machines:    []
          };
        }
        idx[key].machines.push({
          hostname:        hostname,
          FirstLogon:      user.FirstLogon,
          LastLogon:       user.LastLogonUTC,
          LastLogonSource: user.LastLogonSource,
          ProfilePath:     user.ProfilePath,
          IsLoaded:        user.IsLoaded,
          HasLocalAccount: user.HasLocalAccount,
          LocalDisabled:   user.LocalDisabled
        });
      });
    }

    // Enrich with DC domain_accounts by SID
    if (u.domain_accounts) {
      u.domain_accounts.forEach(da => {
        const key = da.SID;
        if (!key) return;
        if (idx[key]) {
          idx[key].domainInfo = {
            dcHost:          hostname,
            WhenCreated:     da.WhenCreatedUTC,
            LastLogonAD:     da.LastLogonUTC,
            PasswordLastSet: da.PasswordLastSetUTC,
            Enabled:         da.Enabled,
            LockedOut:       da.LockedOut,
            BadLogonCount:   da.BadLogonCount,
            Source:          da.Source
          };
          if (da.SamAccountName) idx[key].Username = da.SamAccountName;
        }
      });
    }
  });

  return idx;
}

// ── FILE LOADER ───────────────────────────────────────────────────────────────
function triggerLoad() {
  document.getElementById('fileInput').click();
}

function rebuildUserIndex() {
  window.userIndex = buildUserIndex(Object.values(state.hosts));
}

function handleFiles(files) {
  if (!files || !files.length) return;
  const fileArr = Array.from(files);
  showProgress('Loading 0 / ' + fileArr.length, 0);
  let done = 0;
  fileArr.forEach(f => {
    loadJsonFile(f, () => {
      done++;
      setProgress(done / fileArr.length * 100);
      setProgressLabel('Loading ' + done + ' / ' + fileArr.length);
      // Update UI after EACH file so hosts appear as they load
      const ph = document.getElementById('placeholder');
      if (Object.keys(state.hosts).length > 0) ph.classList.remove('show');
      rebuildHostSelector();
      updateBadges();
      updateMeta();
      updateTabVisibility();
      rebuildUserIndex();
      renderActiveTab();
      if (done === fileArr.length) hideProgress();
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
      // Handle execution result JSONs (from Executor.ps1)
      if (data.ExecutionId && data.ComputerName && !data.manifest) {
        state.executions[data.ComputerName] = data;
        onDone(); return;
      }
      const host = (data.manifest && data.manifest.hostname) ? data.manifest.hostname : file.name.replace(/\.json$/i,'');
      // Normalize new JSON keys (v2.0) with backwards compat for old format
      data.processes   = data.Processes   || data.processes   || [];
      data.network_tcp = (data.Network && data.Network.tcp) || data.network_tcp || [];
      data.dns_cache   = (data.Network && data.Network.dns) || data.dns_cache   || [];
      data.network_udp = (data.Network && data.Network.udp) || data.network_udp || [];
      data.network_adapters = (data.manifest && data.manifest.network_adapters) || [];
      // Build DLL count per process (CAPABILITY: DLL Count column)
      const hasDlls = Array.isArray(data.DLLs) && data.DLLs.length > 0;
      const dllCountMap = {};
      if (hasDlls) {
        data.DLLs.forEach(dll => {
          dllCountMap[dll.ProcessId] = (dllCountMap[dll.ProcessId] || 0) + 1;
        });
      }
      data.processes.forEach(p => {
        p.DLLCount = hasDlls ? parseInt(dllCountMap[p.ProcessId] || 0, 10) : null;
      });
      // Duplicate detection by hostname — skip if already loaded
      if (state.hosts[host]) { onDone(); return; }
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
  updateTabVisibility();
  rebuildUserIndex();
  renderActiveTab();
}

function updateTabVisibility() {
  const d = activeData();
  const dllsBtn = el('tab-dlls');
  if (dllsBtn) {
    dllsBtn.style.display = (d && d.DLLs && d.DLLs.length > 0) ? '' : 'none';
  }
  const usersBtn = el('tab-users');
  if (usersBtn) {
    const hasUsers = Object.values(state.hosts).some(h => h.Users);
    usersBtn.style.display = hasUsers ? '' : 'none';
  }
}

function removeHost(hostname) {
  if (!state.hosts[hostname]) return;
  const wasActive = (state.activeHost === hostname);
  delete state.hosts[hostname];
  const remaining = Object.keys(state.hosts);
  rebuildUserIndex();
  rebuildHostSelector();
  updateBadges();
  updateMeta();
  updateTabVisibility();
  const dd = el('hostSelectorDropdown');
  if (dd) dd.style.display = 'none';
  if (remaining.length === 0) {
    state.activeHost = null;
    const ph = document.getElementById('placeholder');
    if (ph) ph.classList.add('show');
    renderActiveTab();
  } else if (wasActive) {
    switchHost(remaining[0]);
  } else {
    renderActiveTab();
  }
}

function rebuildHostSelector() {
  const curr = el('hostSelectorCurrent');
  const dd   = el('hostSelectorDropdown');
  if (!curr || !dd) return;
  const hosts = Object.keys(state.hosts);
  if (hosts.length === 0) {
    curr.textContent = '-- No files loaded --';
    dd.innerHTML = '';
    return;
  }
  curr.textContent = state.activeHost || hosts[0];
  dd.innerHTML = hosts.map(h => `
    <div class="host-dropdown-item${h === state.activeHost ? ' active' : ''}">
      <span class="host-name" onclick="selectHostFromDropdown('${esc(h)}')">${esc(h)}</span>
      <button class="host-rm-btn" onclick="hostDropdownStartRemove(event,'${esc(h)}')" title="Remove host">×</button>
    </div>`).join('');
}

function toggleHostDropdown(e) {
  if (e) e.stopPropagation();
  const dd = el('hostSelectorDropdown');
  if (!dd) return;
  dd.style.display = dd.style.display === 'none' ? '' : 'none';
}

function selectHostFromDropdown(hostname) {
  const dd = el('hostSelectorDropdown');
  if (dd) dd.style.display = 'none';
  switchHost(hostname);
}

function hostDropdownStartRemove(e, hostname) {
  e.stopPropagation();
  const item = e.target.closest('.host-dropdown-item');
  if (!item) { removeHost(hostname); return; }
  if (item._removeTimer) clearTimeout(item._removeTimer);
  item.innerHTML = `<span class="host-name">${esc(hostname)}</span>
    <button class="host-rm-confirm" onclick="hostDropdownConfirmRemove(event,'${esc(hostname)}')">Confirm ×</button>
    <button class="host-rm-cancel" onclick="hostDropdownCancelRemove(event,'${esc(hostname)}')">Cancel</button>`;
  item._removeTimer = setTimeout(() => {
    if (item.isConnected) rebuildHostSelector();
  }, 3000);
}

function hostDropdownConfirmRemove(e, hostname) {
  e.stopPropagation();
  const item = e.target.closest('.host-dropdown-item');
  if (item && item._removeTimer) clearTimeout(item._removeTimer);
  removeHost(hostname);
}

function hostDropdownCancelRemove(e, hostname) {
  e.stopPropagation();
  const item = e.target.closest('.host-dropdown-item');
  if (item && item._removeTimer) clearTimeout(item._removeTimer);
  rebuildHostSelector();
}

function switchHost(h) {
  if (!h || !state.hosts[h]) return;
  state.activeHost = h;
  state.expandedRows = {};
  // Reset users view state on every host switch (userIndex is global — do NOT rebuild)
  usersView   = 'peruser';
  usersSearch = '';
  rebuildHostSelector();
  updateBadges();
  updateMeta();
  updateTabVisibility();
  renderActiveTab();
}

function activeData() { return state.activeHost ? state.hosts[state.activeHost] : null; }

function updateBadges() {
  const d = activeData();
  if (!d) { ['b-procs','b-active','b-ips','b-dns'].forEach(id => el(id).textContent = '0'); return; }
  el('b-procs').textContent  = d.processes ? d.processes.length : 0;
  const allConns = (d.network_tcp || []).concat(d.network_udp || []);
  const active = allConns.filter(c => c.State === 'ESTABLISHED').length;
  el('b-active').textContent = active;
  const ips = new Set(allConns.filter(c => c.RemoteAddress && c.RemoteAddress !== '0.0.0.0' && c.RemoteAddress !== '::').map(c => c.RemoteAddress));
  el('b-ips').textContent   = ips.size;
  const matches = allConns.filter(c => c.DnsMatch).length;
  el('b-dns').textContent   = matches;
  if (typeof updateExecuteBadge === 'function') updateExecuteBadge();
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
    case 'dlls':      renderDlls();      break;
    case 'users':     renderUsers();     break;
    case 'execute':   renderExecute();   break;
  }
}

// ── VIRTUAL SCROLL ENGINE ─────────────────────────────────────────────────────
const ROW_H    = 28;
const BUFFER   = 20;
const MAX_ROWS = 60;

function createVS(containerId, columns, data, rowRenderer, onRowClick, tabName) {
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

  // Expansion state — tracks which row is expanded and its pixel height
  let expandIdx    = -1;
  let expandHeight = 0;

  function totalHeight()  { return data.length * ROW_H + expandHeight; }
  function getRowTop(i)   { return i * ROW_H + (expandIdx >= 0 && i > expandIdx ? expandHeight : 0); }

  let lastStart = -1;
  function render() {
    const scrollTop = viewport.scrollTop;
    const visH      = viewport.clientHeight;
    const start     = Math.max(0, Math.floor(scrollTop / ROW_H) - BUFFER);
    const end       = Math.min(data.length, Math.ceil((scrollTop + visH) / ROW_H) + BUFFER);
    if (start === lastStart && inner.querySelectorAll('.vrow').length > 0) return;
    lastStart = start;

    // Remove vrow nodes outside range; preserve .expand-row
    Array.from(inner.children).forEach(n => {
      if (!n.classList.contains('vrow')) return;
      const idx = parseInt(n.dataset.idx);
      if (idx < start || idx >= end) n.remove();
    });

    // Update tops of remaining rows (expansion shifts rows below expandIdx)
    inner.querySelectorAll('.vrow').forEach(n => {
      n.style.top = getRowTop(parseInt(n.dataset.idx)) + 'px';
    });

    // Reposition expand-row if present
    const expEl = inner.querySelector('.expand-row');
    if (expEl && expandIdx >= 0) {
      expEl.style.top = (getRowTop(expandIdx) + ROW_H) + 'px';
    }

    // Add missing nodes
    const existing = new Set(Array.from(inner.querySelectorAll('.vrow')).map(n => parseInt(n.dataset.idx)));
    for (let i = start; i < end && (i - start) < MAX_ROWS; i++) {
      if (existing.has(i)) continue;
      const row = document.createElement('div');
      row.className = 'vrow';
      row.dataset.idx = i;
      row.style.top = getRowTop(i) + 'px';
      row.style.gridTemplateColumns = columns;
      row.innerHTML = rowRenderer(data[i], i);
      row.addEventListener('click', ev => {
        if (ev.target.classList.contains('link')) return;
        onRowClick(i, data[i], row);
      });
      inner.appendChild(row);
    }
    // BUG 3: re-apply saved column widths after every render so scroll doesn't lose widths
    if (tabName) reapplyColWidthsFromStorage(tabName, inner);
  }

  viewport.addEventListener('scroll', render);
  setTimeout(render, 0);

  return {
    viewport, inner, render,
    scrollToIndex(idx) {
      viewport.scrollTop = Math.max(0, idx * ROW_H - viewport.clientHeight / 2);
      setTimeout(render, 50);
    },
    // FIX 1: update closure variable `data`, not just this.data
    update(newData) {
      data = newData;
      expandIdx = -1; expandHeight = 0;
      inner.style.height = totalHeight() + 'px';
      inner.innerHTML = '';
      lastStart = -1;
      render();
    },
    // FIX 2: insert expand panel below row idx, push subsequent rows down
    expand(idx, contentEl) {
      const old = inner.querySelector('.expand-row');
      if (old) old.remove();
      expandIdx    = idx;
      expandHeight = 0;
      contentEl.classList.add('expand-row');
      contentEl.style.cssText = 'position:absolute;left:0;width:100%;top:' + (getRowTop(idx) + ROW_H) + 'px';
      inner.appendChild(contentEl);
      // Measure actual rendered height then re-layout
      requestAnimationFrame(() => {
        expandHeight = contentEl.offsetHeight || 200;
        inner.style.height = totalHeight() + 'px';
        lastStart = -1;
        render();
      });
    },
    collapse() {
      const old = inner.querySelector('.expand-row');
      if (old) old.remove();
      expandIdx = -1; expandHeight = 0;
      inner.style.height = totalHeight() + 'px';
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
  const hwrap = el('hostSelectorWrap');
  const hdd   = el('hostSelectorDropdown');
  if (hdd && hwrap && !hwrap.contains(e.target)) hdd.style.display = 'none';
});

// ── HELPERS ───────────────────────────────────────────────────────────────────
function el(id) { return document.getElementById(id); }
function esc(s) { return String(s||'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;'); }
function str(v) { return v == null ? '' : String(v).toLowerCase(); }
function trunc(s, n) { s = String(s||''); return s.length > n ? s.slice(0,n-1)+'…' : s; }
function fmtUTC(s) {
  if (!s) return '<span style="color:var(--muted)">&#8212;</span>';
  try {
    const d = new Date(s);
    if (isNaN(d)) return '<span style="color:var(--muted)">&#8212;</span>';
    const pad = n => String(n).padStart(2, '0');
    return esc(d.getUTCFullYear() + '-' +
      pad(d.getUTCMonth() + 1) + '-' +
      pad(d.getUTCDate()) + ' ' +
      pad(d.getUTCHours()) + ':' +
      pad(d.getUTCMinutes()) + ':' +
      pad(d.getUTCSeconds()) + ' UTC');
  } catch(e) { return '<span style="color:var(--muted)">&#8212;</span>'; }
}

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

// ── NAVIGATION WITH ROW HIGHLIGHT ─────────────────────────────────────────────
function navigateToRow(tab, matchField, matchValue) {
  switchTab(tab);
  setTimeout(function() {
    const tabMap = {
      processes: { data: procData, vsKey: 'proc' },
      network:   { data: netData,  vsKey: 'net'  },
      dns:       { data: dnsData,  vsKey: 'dns'  },
      dlls:      { data: dllData,  vsKey: 'dlls' },
    };
    const entry = tabMap[tab];
    if (!entry) return;
    const idx = entry.data.findIndex(function(r) { return String(r[matchField]) === String(matchValue); });
    const vs = state.vsInstances[entry.vsKey];
    if (!vs) return;
    if (idx >= 0) {
      vs.viewport.scrollTop = Math.max(0, idx * ROW_H - vs.viewport.clientHeight / 2);
      setTimeout(function() {
        vs.render();
        setTimeout(function() {
          const inner = vs.viewport.querySelector('.vscroll-inner');
          if (!inner) return;
          const rowEl = inner.querySelector('[data-idx="' + idx + '"]');
          if (!rowEl) return;
          // Clear any existing highlight
          inner.querySelectorAll('.row-highlight').forEach(function(el) {
            el.classList.remove('row-highlight', 'fade');
          });
          // FIX 3: brighter pulse, 3s hold then 1.5s fade
          rowEl.classList.add('row-highlight');
          setTimeout(function() { rowEl.classList.add('fade'); }, 3000);
          setTimeout(function() { rowEl.classList.remove('row-highlight', 'fade'); }, 4500);
        }, 50);
      }, 50);
    }
  }, 100);
}

// Execution dialog removed — functionality moved to EXECUTE tab (09b_execute.js)

// Placeholder will be hidden once files load; auto-trigger picker on init
window.addEventListener('load', () => {
  setTimeout(() => {
    document.getElementById('fileInput').click();
  }, 100);
});

