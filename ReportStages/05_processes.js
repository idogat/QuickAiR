// ── PROCESSES TAB ─────────────────────────────────────────────────────────────
let procFilters = { search: '', hasConns: false, noPath: false };
let procSort    = { col: 'ProcessId', dir: 1 };
let procData    = [];

function renderProcesses() {
  const panel  = el('panel-processes');
  const d      = activeData();
  if (!d) { panel.innerHTML = '<div class="solo-notice">No file loaded.</div>'; return; }

  const COLS = '60px 60px 120px 160px 300px 1fr 80px';

  panel.innerHTML = `
    <div class="filter-bar">
      <input type="text" id="proc-search" placeholder="Search name, PID, path, cmdline&hellip;" style="width:280px"
             oninput="procFilters.search=this.value;applyProcFilters()">
      <label><input type="checkbox" onchange="procFilters.hasConns=this.checked;applyProcFilters()"> Has connections</label>
      <label><input type="checkbox" onchange="procFilters.noPath=this.checked;applyProcFilters()"> No executable path</label>
      <span id="proc-count" style="color:var(--muted);font-size:11px;margin-left:8px"></span>
    </div>
    <div class="tbl-wrap">
      <div class="tbl-header" style="grid-template-columns:${COLS}" id="proc-header"></div>
      <div id="proc-vs"></div>
    </div>`;

  state.vsInstances['proc'] = null;
  buildProcHeader(COLS);
  applyProcFilters();
}

function buildProcHeader(COLS) {
  const headers = [
    { key:'ProcessId',       label:'PID'      },
    { key:'ParentProcessId', label:'PPID'     },
    { key:'_parentName',     label:'Parent'   },
    { key:'Name',            label:'Name'     },
    { key:'ExecutablePath',  label:'Path'     },
    { key:'CommandLine',     label:'CmdLine'  },
    { key:'_connCount',      label:'Conns'    },
  ];
  const h = el('proc-header');
  if (!h) return;
  h.innerHTML = headers.map(hd => {
    const cls = procSort.col === hd.key ? (procSort.dir===1?'th sort-asc':'th sort-desc') : 'th';
    return `<div class="${cls}" onclick="procSortBy('${hd.key}')">${esc(hd.label)}</div>`;
  }).join('');
}

function applyProcFilters() {
  const d = activeData(); if (!d) return;
  const lq = procFilters.search.toLowerCase();

  // Build connection count map
  const connMap = {};
  (d.network_tcp||[]).forEach(c => {
    if (c.OwningProcess) connMap[c.OwningProcess] = (connMap[c.OwningProcess]||0)+1;
  });

  // Build PID -> name map
  const nameMap = {};
  (d.processes||[]).forEach(p => nameMap[p.ProcessId] = p.Name);

  let rows = (d.processes||[]).map(p => Object.assign({}, p, {
    _connCount:  connMap[p.ProcessId] || 0,
    _parentName: nameMap[p.ParentProcessId] || '',
  }));

  if (lq) rows = rows.filter(p =>
    str(p.Name).includes(lq) || str(p.ProcessId).includes(lq) ||
    str(p.ExecutablePath).includes(lq) || str(p.CommandLine).includes(lq)
  );
  if (procFilters.hasConns) rows = rows.filter(p => p._connCount > 0);
  if (procFilters.noPath)   rows = rows.filter(p => !p.ExecutablePath);

  rows.sort((a,b) => {
    const av = a[procSort.col]; const bv = b[procSort.col];
    if (typeof av === 'number') return (av - bv) * procSort.dir;
    return String(av||'').localeCompare(String(bv||'')) * procSort.dir;
  });
  procData = rows;

  const cnt = el('proc-count');
  if (cnt) cnt.textContent = rows.length + ' processes';

  const COLS = '60px 60px 120px 160px 300px 1fr 80px';
  state.expandedRows['proc'] = null;

  if (state.vsInstances['proc']) {
    state.vsInstances['proc'].update(rows);
  } else {
    state.vsInstances['proc'] = createVS('proc-vs', COLS, rows, renderProcRow, onProcRowClick);
  }
}

function renderProcRow(p, i) {
  const connCls  = p._connCount > 0 ? 'link' : 'dim';
  const isFallback = p.source === 'dotnet_fallback';
  const fbBadge  = isFallback
    ? ' <span title="source: dotnet_fallback" style="color:var(--amber);font-size:9px;vertical-align:middle">[fb]</span>'
    : '';
  const nameCls  = isFallback ? 'td amber' : 'td';
  return `
    <div class="td mono">${p.ProcessId}</div>
    <div class="td dim">${p.ParentProcessId}</div>
    <div class="td dim">${esc(trunc(p._parentName,16))}</div>
    <div class="${nameCls}">${esc(trunc(p.Name,20))}${fbBadge}</div>
    <div class="td dim">${esc(trunc(p.ExecutablePath||'',40))}</div>
    <div class="td dim">${esc(trunc(p.CommandLine||'',60))}</div>
    <div class="td ${connCls}" onclick="if(${p._connCount}>0){event.stopPropagation();gotoNetworkPid(${p.ProcessId})}">${p._connCount||''}</div>`;
}

function onProcRowClick(i, p, rowEl) {
  const vsWrap = el('proc-vs');
  const prev   = state.expandedRows['proc'];
  // Remove previous expand
  const prevEl = vsWrap ? vsWrap.querySelector('.expand-row') : null;
  if (prevEl) prevEl.remove();
  if (prev === i) { state.expandedRows['proc'] = null; return; }
  state.expandedRows['proc'] = i;

  const d = activeData();
  const connMap = {};
  (d.network_tcp||[]).forEach(c => {
    if (c.OwningProcess == p.ProcessId) connMap[c.RemoteAddress+':'+c.RemotePort] = c;
  });
  const myConns = Object.values(connMap);
  const children = (d.processes||[]).filter(c => c.ParentProcessId == p.ProcessId);

  let connsHTML = '';
  if (myConns.length) {
    const adAliases = getAdapterAliases();
    connsHTML = `<h4>Network Connections (${myConns.length})</h4>
    <table class="expand-tbl"><tr>
      <th>Remote IP</th><th>Port</th><th>State</th><th>DNS Match</th><th>Reverse DNS</th><th>Interface</th><th>Private</th>
    </tr>` +
    myConns.map(c => {
      const ia    = c.InterfaceAlias || '';
      const iCol  = ifaceColor(ia, adAliases);
      return `<tr>
      <td class="mono"><a onclick="gotoNetworkIp('${esc(c.RemoteAddress)}')">${esc(c.RemoteAddress)}</a></td>
      <td>${c.RemotePort}</td>
      <td>${esc(c.State)}</td>
      <td>${esc(c.DnsMatch||'')}</td>
      <td>${esc(c.ReverseDns||'')}</td>
      <td><span style="color:${iCol};font-weight:bold">${esc(ia)}</span></td>
      <td>${c.IsPrivateIP?'yes':''}</td>
    </tr>`;
    }).join('') + '</table>';
  }

  let childHTML = '';
  if (children.length) {
    childHTML = `<h4>Child Processes (${children.length})</h4>` +
      children.map(c => `<a onclick="gotoProcessPid(${c.ProcessId})">${esc(c.Name)} [${c.ProcessId}]</a>`).join('  ');
  }

  const expand = document.createElement('div');
  expand.className = 'expand-row';
  expand.innerHTML = `
    <div class="kv-grid">
      <span class="k">CommandLine</span>  <span class="v">${esc(p.CommandLine||'—')}</span>
      <span class="k">ExecutablePath</span><span class="v">${esc(p.ExecutablePath||'—')}</span>
      <span class="k">CreationDateUTC</span><span class="v">${esc(p.CreationDateUTC||'')}</span>
      <span class="k">CreationDateLocal</span><span class="v">${esc(p.CreationDateLocal||'')}</span>
      <span class="k">WorkingSetSize</span><span class="v">${fmtBytes(p.WorkingSetSize)}</span>
      <span class="k">VirtualSize</span>   <span class="v">${fmtBytes(p.VirtualSize)}</span>
      <span class="k">SessionId</span>     <span class="v">${p.SessionId}</span>
      <span class="k">HandleCount</span>   <span class="v">${p.HandleCount}</span>
    </div>
    ${connsHTML}
    ${childHTML}`;

  // Insert after the row
  const viewport = rowEl.closest('.vscroll-viewport');
  if (viewport) {
    const inner = viewport.querySelector('.vscroll-inner');
    const top   = parseInt(rowEl.style.top) + ROW_H;
    expand.style.position = 'absolute';
    expand.style.top      = top + 'px';
    expand.style.left     = '0';
    expand.style.width    = '100%';
    inner.appendChild(expand);
  }
}

function procSortBy(col) {
  if (procSort.col === col) procSort.dir *= -1; else { procSort.col = col; procSort.dir = 1; }
  buildProcHeader('60px 60px 120px 160px 300px 1fr 80px');
  applyProcFilters();
}

function highlightProcessPid(pid) {
  const idx = procData.findIndex(p => p.ProcessId == pid);
  if (idx < 0) return;
  const vs = state.vsInstances['proc'];
  if (vs) vs.scrollToIndex(idx);
}

function gotoProcessPid(pid) { switchTab('processes'); setTimeout(() => highlightProcessPid(pid), 100); }
function gotoNetworkPid(pid) { switchTab('network'); setTimeout(() => highlightNetworkPid(pid), 100); }
function gotoNetworkIp(ip)   { switchTab('network'); setTimeout(() => highlightNetworkIp(ip), 100); }

function fmtBytes(b) {
  if (!b) return '0 B';
  b = parseInt(b);
  if (b > 1073741824) return (b/1073741824).toFixed(1)+' GB';
  if (b > 1048576)    return (b/1048576).toFixed(1)+' MB';
  if (b > 1024)       return (b/1024).toFixed(0)+' KB';
  return b+' B';
}

