
// ── VERSION ───────────────────────────────────────────────────────────────────
const ANALYZER_VERSION = "2.4";

// ── STATE ────────────────────────────────────────────────────────────────────
const state = {
  hosts: {},        // { hostname: { manifest, processes, network_tcp, dns_cache } }
  activeHost: null,
  vsInstances: {},  // virtual scroll instances keyed by id
  expandedRows: {}, // { tableId: rowIndex }
  filtered: {},     // { tab: sortedRows[] } for sortTable
};

// ── SORT/RESIZE CSS ───────────────────────────────────────────────────────────
(function injectSortResizeCSS() {
  const s = document.createElement('style');
  s.textContent = `
    .sortable-th { cursor: pointer; user-select: none; }
    .sort-arrow { color: var(--muted); font-size: 0.8em; }
    .sort-arrow.asc { color: var(--accent); }
    .sort-arrow.desc { color: var(--accent); }
    .resize-handle {
      position: absolute; right: 0; top: 0;
      width: 5px; height: 100%;
      cursor: col-resize;
      background: transparent;
      z-index: 1;
    }
    .resize-handle:hover { background: var(--border); }
    th { position: relative; }
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
    if (av == null && bv == null) return 0;
    if (av == null) return 1;
    if (bv == null) return -1;
    if (numeric) return (Number(av) - Number(bv)) * dir;
    return String(av).localeCompare(String(bv)) * dir;
  });
}

// ── RESIZABLE COLUMNS ─────────────────────────────────────────────────────────
// Works on div-based virtual scroll headers (tbl-header containing .th divs)
function addResizeHandles(headerId, tabName) {
  const header = document.getElementById(headerId);
  if (!header) return;
  const ths = header.querySelectorAll('.th');
  ths.forEach((th, colIndex) => {
    // Restore saved width
    const saved = sessionStorage.getItem('colWidth_' + tabName + '_' + colIndex);
    if (saved) {
      th.style.width = saved + 'px';
      th.style.minWidth = saved + 'px';
    }
    // Remove existing handle to avoid duplicates on re-render
    const existing = th.querySelector('.col-resize-handle');
    if (existing) existing.remove();
    const handle = document.createElement('div');
    handle.className = 'col-resize-handle';
    th.appendChild(handle);

    // BUG 2: track whether a drag occurred to suppress the post-mouseup click
    let resizeDragging = false;
    let resizeDragOccurred = false;

    handle.addEventListener('mousedown', function(e) {
      e.preventDefault();
      e.stopPropagation();  // prevents sort trigger on th mousedown
      resizeDragging = true;
      resizeDragOccurred = false;
      const startX = e.clientX;
      const startWidth = th.offsetWidth;
      handle.classList.add('dragging');

      function onMove(ev) {
        resizeDragOccurred = true;  // BUG 2: mark drag as occurred
        const delta = ev.clientX - startX;
        const newWidth = Math.max(40, startWidth + delta);
        // BUG 1: apply to header cell
        th.style.width = newWidth + 'px';
        th.style.minWidth = newWidth + 'px';
        // BUG 1: apply to ALL body cells in same column on every mousemove
        applyColWidthToRows(tabName, colIndex, newWidth);
        // BUG 1: save to sessionStorage on every move so scroll reapply works
        sessionStorage.setItem('colWidth_' + tabName + '_' + colIndex, newWidth);
      }
      function onUp() {
        resizeDragging = false;
        document.removeEventListener('mousemove', onMove);
        document.removeEventListener('mouseup', onUp);
        handle.classList.remove('dragging');
      }
      document.addEventListener('mousemove', onMove);
      document.addEventListener('mouseup', onUp);
    });

    // BUG 2: suppress the click event that fires after mouseup when drag occurred
    handle.addEventListener('click', function(e) {
      if (resizeDragOccurred) {
        resizeDragOccurred = false;
        e.stopPropagation();
      }
    });
  });
}

function applyColWidthToRows(tabName, colIndex, width) {
  // Map tabName to vs container id
  const vsId = { processes:'proc-vs', network:'net-vs', dns:'dns-vs', dlls:'dlls-vs', fleet:'fleet-vs' }[tabName];
  if (!vsId) return;
  const vs = document.getElementById(vsId);
  if (!vs) return;
  vs.querySelectorAll('.vrow').forEach(row => {
    if (row.cells) { // regular table rows
      if (row.cells[colIndex]) { row.cells[colIndex].style.width = width + 'px'; }
    } else { // div-based rows
      const cells = row.children;
      if (cells[colIndex]) {
        cells[colIndex].style.width = width + 'px';
        cells[colIndex].style.minWidth = width + 'px';
      }
    }
  });
}

function restoreColWidths(tabName, headerId) {
  const header = document.getElementById(headerId);
  if (!header) return;
  const ths = header.querySelectorAll('.th');
  ths.forEach((th, colIndex) => {
    const saved = sessionStorage.getItem('colWidth_' + tabName + '_' + colIndex);
    if (saved) {
      th.style.width = saved + 'px';
      th.style.minWidth = saved + 'px';
    }
  });
}

// BUG 3: re-apply saved column widths to all visible vrows after virtual scroll render
function reapplyColWidthsFromStorage(tabName, vsEl) {
  if (!tabName || !vsEl) return;
  for (let i = 0; i < 20; i++) {
    const saved = sessionStorage.getItem('colWidth_' + tabName + '_' + i);
    if (!saved) continue;
    vsEl.querySelectorAll('.vrow').forEach(function(row) {
      const cells = row.children;
      if (cells[i]) {
        cells[i].style.width = saved + 'px';
        cells[i].style.minWidth = saved + 'px';
      }
    });
  }
}

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
      // Build DLL count per process (CAPABILITY: DLL Count column)
      const hasDlls = Array.isArray(data.DLLs) && data.DLLs.length > 0;
      const dllCountMap = {};
      if (hasDlls) {
        data.DLLs.forEach(dll => {
          dllCountMap[dll.ProcessId] = (dllCountMap[dll.ProcessId] || 0) + 1;
        });
      }
      data.processes.forEach(p => {
        p.DLLCount = hasDlls ? (dllCountMap[p.ProcessId] || 0) : null;
      });
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
  renderActiveTab();
}

function updateTabVisibility() {
  const d = activeData();
  const dllsBtn = el('tab-dlls');
  if (dllsBtn) {
    dllsBtn.style.display = (d && d.DLLs && d.DLLs.length > 0) ? '' : 'none';
  }
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
  updateTabVisibility();
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
    case 'dlls':      renderDlls();      break;
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

// Placeholder will be hidden once files load; auto-trigger picker on init
window.addEventListener('load', () => {
  setTimeout(() => {
    document.getElementById('fileInput').click();
  }, 100);
});

