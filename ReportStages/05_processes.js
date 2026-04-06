// ╔══════════════════════════════════════╗
// ║  QuickAiR — 05_processes.js           ║
// ║  Processes tab render, virtual       ║
// ║  scroll, row expand, inline network  ║
// ║  detail, DLL count, Owner,           ║
// ║  IntegrityLevel display              ║
// ╠══════════════════════════════════════╣
// ║  Reads    : activeHost.Processes,     ║
// ║             activeHost.DLLs           ║
// ║  Writes   : procFilters, procSort     ║
// ║  Functions: renderProcesses,          ║
// ║    applyProcFilters, renderProcRow,   ║
// ║    onProcRowClick, gotoProcessPid,    ║
// ║    gotoNetworkPid, gotoNetworkIp,     ║
// ║    gotoProcessDlls, renderSignedIcon, ║
// ║    integrityRank, renderIntegrityBadge║
// ║    fmtBytes                           ║
// ║  Depends  : 03_core.js               ║
// ║  Version  : 3.52                      ║
// ╚══════════════════════════════════════╝

// ── PROCESSES TAB ─────────────────────────────────────────────────────────────
let procFilters = { search: '' };
let procSort    = { col: 'ProcessId', dir: 1 };
let procData    = [];

function renderSignedIcon(sig) {
  if (!sig) return '<span style="color:var(--muted)">?</span>';
  const cat = sig.SignatureType === 'Catalog' ? '<span style="font-size:8px;color:var(--amber)" title="Catalog-signed (hash in Windows catalog DB)">&#9679;</span>' : '';
  if (sig.IsSigned === true  && sig.IsValid === true)  return '<span style="color:var(--green)">&#10003;</span>' + cat;
  if (sig.IsSigned === true  && sig.IsValid === false) return '<span style="color:var(--red)">&#10007;</span>' + cat;
  if (sig.IsSigned === true  && sig.IsValid == null)   return '<span style="color:var(--green)">&#10003;</span>' + cat;
  if (sig.IsSigned === false) return '<span style="color:var(--muted)">&mdash;</span>';
  return '<span style="color:var(--amber)">?</span>';
}

function integrityRank(level) {
  if (!level) return 0;
  switch (level) {
    case 'System':           return 7;
    case 'ProtectedProcess': return 6;
    case 'High':             return 5;
    case 'MediumPlus':       return 4;
    case 'Medium':           return 3;
    case 'Low':              return 2;
    case 'Untrusted':        return 1;
    default:                 return 0;
  }
}

function renderIntegrityBadge(level) {
  if (!level) return '<span style="color:var(--muted)">&mdash;</span>';
  switch (level) {
    case 'System':
    case 'High':
      return '<span style="color:var(--red)">' + esc(level) + '</span>';
    case 'Low':
    case 'Untrusted':
    case 'MediumPlus':
      return '<span style="color:var(--amber)">' + esc(level) + '</span>';
    default:
      return '<span>' + esc(level) + '</span>';
  }
}

function renderProcesses() {
  const panel  = el('panel-processes');
  const d      = activeData();
  if (!d) { panel.innerHTML = '<div class="solo-notice">No file loaded.</div>'; return; }

  const COLS = '60px 60px 120px 160px 300px 1fr 80px 55px 40px 120px 130px 120px 80px';

  panel.innerHTML = `
    <div class="filter-bar">
      <input type="text" id="proc-search" placeholder="Search name, PID, path, cmdline, owner&hellip;" style="width:280px"
             oninput="procFilters.search=this.value;applyProcFilters()">
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

const PROC_COLS = '60px 60px 120px 160px 300px 1fr 80px 55px 40px 120px 130px 120px 80px';

function buildProcHeader(COLS) {
  const headers = [
    { key:'ProcessId',       label:'PID'    },
    { key:'ParentProcessId', label:'PPID'   },
    { key:'_parentName',     label:'Parent' },
    { key:'Name',            label:'Name'   },
    { key:'ExecutablePath',  label:'Path'   },
    { key:'CommandLine',     label:'CmdLine'},
    { key:'_connCount',      label:'Conns'  },
    { key:'DLLCount',        label:'DLLs'   },
    { key:'_signed',         label:'Sig'    },
    { key:'_signerCompany',  label:'Signer' },
    { key:'_sha256Short',    label:'SHA256' },
    { key:'Owner',           label:'Owner'  },
    { key:'IntegrityLevel',  label:'Integrity' },
  ];
  const h = el('proc-header');
  if (!h) return;
  h.innerHTML = headers.map(hd => {
    const numeric = /Id$|PID$|PPID$|Count$|Session$|Handle$|^IntegrityLevel$/.test(hd.key);
    const arrow = (sortState.tab === 'processes' && sortState.column === hd.key)
      ? (sortState.dir === 'asc' ? '↑' : sortState.dir === 'desc' ? '↓' : '⇅') : '⇅';
    const arrowCls = (sortState.tab === 'processes' && sortState.column === hd.key && sortState.dir !== 'none')
      ? ' class="sort-arrow ' + sortState.dir + '"' : ' class="sort-arrow"';
    return `<div class="th sortable-th" onclick="sortTable('processes','${hd.key}',${numeric})">${esc(hd.label)} <span id="sort-processes-${hd.key}"${arrowCls}>${arrow}</span></div>`;
  }).join('');
  setTimeout(() => addResizeHandles('proc-header', 'processes'), 0);
}

function applyProcFilters() {
  const d = activeData(); if (!d) return;
  const lq = procFilters.search.toLowerCase();

  // Build connection count map (TCP + UDP)
  const connMap = {};
  (d.network_tcp||[]).concat(d.network_udp||[]).forEach(c => {
    if (c.OwningProcess) connMap[c.OwningProcess] = (connMap[c.OwningProcess]||0)+1;
  });

  // Build PID -> name map
  const nameMap = {};
  (d.processes||[]).forEach(p => nameMap[p.ProcessId] = p.Name);

  let rows = (d.processes||[]).map(p => {
    const sig = p.Signature || null;
    const sha256Short = p.SHA256 ? (p.SHA256.slice(0,16)+'...') : (p.SHA256Error ? p.SHA256Error : '');
    return Object.assign({}, p, {
      _connCount:     connMap[p.ProcessId] || 0,
      _parentName:    nameMap[p.ParentProcessId] || '',
      _signed:        sig ? sig.IsSigned : null,
      _signerCompany: sig ? (sig.SignerCompany || '') : '',
      _sha256Short:   sha256Short,
      _intRank:       integrityRank(p.IntegrityLevel),
    });
  });

  if (lq) rows = rows.filter(p =>
    str(p.Name).toLowerCase().includes(lq) || str(p.ProcessId).includes(lq) ||
    str(p.ExecutablePath).toLowerCase().includes(lq) || str(p.CommandLine).toLowerCase().includes(lq) ||
    str(p.Owner).toLowerCase().includes(lq)
  );
  // Apply sortTable if active for this tab
  const numericProcCols = new Set(['ProcessId','ParentProcessId','_connCount','DLLCount','SessionId','HandleCount','_intRank']);
  if (sortState.tab === 'processes' && sortState.column && sortState.dir !== 'none') {
    let sortCol = sortState.column;
    if (sortCol === 'IntegrityLevel') sortCol = '_intRank';
    rows = applySortToRows(rows, sortCol, numericProcCols.has(sortCol));
  } else {
    rows.sort((a,b) => {
      const av = a[procSort.col]; const bv = b[procSort.col];
      if (typeof av === 'number') return (av - bv) * procSort.dir;
      return String(av||'').localeCompare(String(bv||'')) * procSort.dir;
    });
  }
  procData = rows;
  state.filtered['processes'] = rows;

  const cnt = el('proc-count');
  if (cnt) cnt.textContent = rows.length + ' processes';

  state.expandedRows['proc'] = null;

  if (state.vsInstances['proc']) {
    state.vsInstances['proc'].update(rows);
  } else {
    state.vsInstances['proc'] = createVS('proc-vs', PROC_COLS, rows, renderProcRow, onProcRowClick, 'processes');
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
    <div class="td mono">${esc(p.ProcessId)}</div>
    <div class="td dim">${esc(p.ParentProcessId)}</div>
    <div class="td dim">${esc(p._parentName)}</div>
    <div class="${nameCls}">${esc(p.Name)}${fbBadge}</div>
    <div class="td dim">${esc(p.ExecutablePath||'')}</div>
    <div class="td dim">${esc(p.CommandLine||'')}</div>
    <div class="td ${connCls}" onclick="if(${parseInt(p._connCount,10)||0}>0){event.stopPropagation();gotoNetworkPid(${parseInt(p.ProcessId,10)||0})}">${p._connCount||''}</div>
    <div class="td dim">${p.DLLCount != null ? p.DLLCount : '—'}</div>
    <div class="td">${renderSignedIcon(p.Signature)}</div>
    <div class="td dim">${esc(p._signerCompany||'')}</div>
    <div class="td mono dim" title="${esc(p.SHA256||'')}">${esc(p._sha256Short||'')}</div>
    <div class="td dim">${esc(p.Owner||'')}</div>
    <div class="td">${renderIntegrityBadge(p.IntegrityLevel)}</div>`;
}

function onProcRowClick(i, p, rowEl) {
  const vs   = state.vsInstances['proc'];
  const prev = state.expandedRows['proc'];
  if (prev === i) {
    state.expandedRows['proc'] = null;
    if (vs) vs.collapse();
    return;
  }
  state.expandedRows['proc'] = i;

  const d = activeData();
  const connMap = {};
  const tcpSet = new Set(d.network_tcp||[]);
  (d.network_tcp||[]).concat(d.network_udp||[]).forEach(c => {
    if (c.OwningProcess == p.ProcessId) {
      const key = (c.RemoteAddress||'')+ ':' + (c.RemotePort||'') + ':' + (c.LocalPort||'');
      if (!connMap[key]) connMap[key] = Object.assign({ _proto: tcpSet.has(c) ? 'TCP' : 'UDP' }, c);
    }
  });
  const myConns = Object.values(connMap);
  const children = (d.processes||[]).filter(c => c.ParentProcessId == p.ProcessId);

  let connsHTML = '';
  if (myConns.length) {
    const adAliases = getAdapterAliases();
    connsHTML = `<h4>Network Connections (${myConns.length})</h4>
    <table class="expand-tbl"><tr>
      <th>Proto</th><th>Remote IP</th><th>Port</th><th>State</th><th>DNS Match</th><th>Reverse DNS</th><th>Interface</th><th>Private</th>
    </tr>` +
    myConns.map(c => {
      const ia   = c.InterfaceAlias || '';
      const iCol = ifaceColor(ia, adAliases);
      return `<tr>
      <td>${c._proto}</td>
      <td class="mono"><a onclick="gotoNetworkIp('${esc(escJs(c.RemoteAddress||''))}')">${esc(c.RemoteAddress||'—')}</a></td>
      <td>${c.RemotePort!=null?c.RemotePort:'—'}</td><td>${esc(c.State||'—')}</td>
      <td>${esc(c.DnsMatch||'')}</td><td>${esc(c.ReverseDns||'')}</td>
      <td><span style="color:${iCol};font-weight:bold">${esc(ia)}</span></td>
      <td>${c.IsPrivateIP?'yes':''}</td></tr>`;
    }).join('') + '</table>';
  }

  let childHTML = '';
  if (children.length) {
    childHTML = `<h4>Child Processes (${children.length})</h4>` +
      children.map(c => `<a onclick="gotoProcessPid(${parseInt(c.ProcessId,10)||0})">${esc(c.Name)} [${c.ProcessId}]</a>`).join('  ');
  }

  const dllCountHTML = p.DLLCount != null
    ? `<span class="detail-value"><a onclick="event.stopPropagation();gotoProcessDlls(${parseInt(p.ProcessId,10)||0})">${p.DLLCount} modules</a></span>`
    : `<span class="detail-value">—</span>`;

  const expand = document.createElement('div');
  expand.innerHTML = `
    <div class="kv-grid">
      <span class="k">CommandLine</span>   <span class="v">${esc(p.CommandLine||'—')}</span>
      <span class="k">ExecutablePath</span> <span class="v">${esc(p.ExecutablePath||'—')}</span>
      <span class="k">CreationDateUTC</span><span class="v">${fmtUTC(p.CreationDateUTC)}</span>
      <span class="k">WorkingSetSize</span> <span class="v">${fmtBytes(p.WorkingSetSize)}</span>
      <span class="k">VirtualSize</span>    <span class="v">${fmtBytes(p.VirtualSize)}</span>
      <span class="k">SessionId</span>      <span class="v">${esc(p.SessionId)}</span>
      <span class="k">HandleCount</span>    <span class="v">${esc(p.HandleCount)}</span>
      <span class="k">Owner</span>          <span class="v">${esc(p.Owner||'—')}</span>
      <span class="k">IntegrityLevel</span> <span class="v">${esc(p.IntegrityLevel||'—')}</span>
      ${!p.IntegrityLevel && p.IntegrityLevelError ? '<span class="k">IntegrityError</span><span class="v" style="color:var(--amber)">' + esc(p.IntegrityLevelError) + '</span>' : ''}
      <span class="k">Loaded DLLs</span>   ${dllCountHTML}
      ${p.SHA256 ? `<span class="k">SHA256</span><span class="v mono">${esc(p.SHA256)}</span>` : ''}
      ${!p.SHA256 && p.SHA256Error ? `<span class="k">SHA256Error</span><span class="v" style="color:var(--amber)">${esc(p.SHA256Error)}</span>` : ''}
      ${p.Signature ? `<span class="k">Sig Status</span>   <span class="v${/^PS2_/.test(p.Signature.Status||'')?' style="color:var(--amber)"':''}">${esc(p.Signature.Status||'—')}${/^PS2_/.test(p.Signature.Status||'')?' (unvalidated)':''}</span>
      <span class="k">IsOSBinary</span>   <span class="v" style="color:${p.Signature.IsOSBinary===true?'var(--green)':p.Signature.IsOSBinary===false?'var(--red)':'var(--muted)'}">${p.Signature.IsOSBinary===true?'Yes':p.Signature.IsOSBinary===false?'No':'—'}</span>
      <span class="k">SignatureType</span><span class="v">${esc(p.Signature.SignatureType||'—')}</span>
      ${p.Signature.CatalogFile ? `<span class="k">CatalogFile</span> <span class="v mono">${esc(p.Signature.CatalogFile)}</span>` : ''}
      <span class="k">${p.Signature.CatalogFile ? 'CatalogSigner' : 'SignerSubject'}</span> <span class="v">${esc(p.Signature.SignerSubject||'—')}</span>
      <span class="k">${p.Signature.CatalogFile ? 'CatalogSignerCo' : 'SignerCompany'}</span> <span class="v">${esc(p.Signature.SignerCompany||'—')}</span>
      <span class="k">Issuer</span>       <span class="v">${esc(p.Signature.Issuer||'—')}</span>
      <span class="k">Thumbprint</span>   <span class="v mono">${esc(p.Signature.Thumbprint||'—')}</span>
      <span class="k">NotAfter</span>     <span class="v">${esc(p.Signature.NotAfter||'—')}</span>
      <span class="k">TimeStamper</span>  <span class="v">${esc(p.Signature.TimeStamper||'—')}</span>` : ''}
    </div>
    ${connsHTML}${childHTML}`;

  if (vs) vs.expand(i, expand);
}


function highlightProcessPid(pid) {
  const idx = procData.findIndex(p => p.ProcessId == pid);
  if (idx < 0) return;
  const vs = state.vsInstances['proc'];
  if (vs) vs.scrollToIndex(idx);
}

function gotoProcessPid(pid) { navigateToRow('processes', 'ProcessId', pid); }
function gotoNetworkPid(pid) { switchTab('network'); setTimeout(() => highlightNetworkPid(pid), 100); }
function gotoNetworkIp(ip)   { switchTab('network'); setTimeout(() => highlightNetworkIp(ip), 100); }
function gotoProcessDlls(pid) {
  switchTab('dlls');
  setTimeout(() => {
    dllFilters.search = String(pid);
    const inp = el('dlls-search');
    if (inp) inp.value = String(pid);
    applyDllFilters();
  }, 100);
}

function fmtBytes(b) {
  if (b == null || b === '') return '\u2014';
  b = parseInt(b);
  if (!b) return '0 B';
  if (b > 1073741824) return (b/1073741824).toFixed(1)+' GB';
  if (b > 1048576)    return (b/1048576).toFixed(1)+' MB';
  if (b > 1024)       return (b/1024).toFixed(0)+' KB';
  return b+' B';
}

