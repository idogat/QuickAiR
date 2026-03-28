// ╔══════════════════════════════════════╗
// ║  QuickAiR — 06b_dlls.js               ║
// ║  DLLs tab render, virtual scroll,    ║
// ║  row expand, signature display,      ║
// ║  SHA256 display, private path        ║
// ║  highlighting, quick-filters         ║
// ╠══════════════════════════════════════╣
// ║  Reads    : activeHost.DLLs           ║
// ║  Writes   : dllFilters, dllSort       ║
// ║  Functions: renderDlls,               ║
// ║    applyDllFilters, renderDllRow,     ║
// ║    onDllRowClick, dllGotoProcess      ║
// ║  Depends  : 03_core.js               ║
// ║  Version  : 3.50                      ║
// ╚══════════════════════════════════════╝

// ── DLLs TAB ──────────────────────────────────────────────────────────────────

// Inject row-private style
(function() {
  const s = document.createElement('style');
  s.textContent = '.row-private { background: rgba(255,180,0,0.15); }';
  document.head.appendChild(s);
})();

let dllFilters = { search: '', unsignedOnly: false, privateOnly: false };
let dllSort    = { col: 'ProcessName', dir: 1 };
let dllData    = [];


function renderDlls() {
  const panel = el('panel-dlls');
  const d     = activeData();
  if (!d) { panel.innerHTML = '<div class="solo-notice">No file loaded.</div>'; return; }

  if (!d.DLLs || !d.DLLs.length) {
    panel.innerHTML = '<div class="solo-notice">No DLL data in this JSON.</div>';
    return;
  }

  const COLS = '140px 55px 160px 220px 90px 140px 145px 55px 40px 120px';

  panel.innerHTML = `
    <div class="filter-bar" id="dlls-filter-bar">
      <input type="text" id="dlls-search" placeholder="Process, DLL, path, company, signer&hellip;" style="width:280px"
             oninput="dllFilters.search=this.value;applyDllFilters()">
      <label style="margin-left:12px;font-size:11px;cursor:pointer"><input type="checkbox" id="dlls-unsigned" onchange="dllFilters.unsignedOnly=this.checked;applyDllFilters()"> Unsigned only</label>
      <label style="margin-left:8px;font-size:11px;cursor:pointer"><input type="checkbox" id="dlls-private" onchange="dllFilters.privateOnly=this.checked;applyDllFilters()"> Private path only</label>
      <span id="dlls-count" style="color:var(--muted);font-size:11px;margin-left:8px"></span>
    </div>
    <div class="tbl-wrap">
      <div class="tbl-header" style="grid-template-columns:${COLS}" id="dlls-header"></div>
      <div id="dlls-vs"></div>
    </div>`;

  state.vsInstances['dlls'] = null;
  buildDllHeader(COLS);
  applyDllFilters();
}

function buildDllHeader(COLS) {
  const headers = [
    { key: 'ProcessName',  label: 'Process',  numeric: false },
    { key: 'ProcessId',    label: 'PID',      numeric: true  },
    { key: 'ModuleName',   label: 'DLL Name', numeric: false },
    { key: 'ModulePath',   label: 'Path',     numeric: false },
    { key: 'FileVersion',  label: 'Version',  numeric: false },
    { key: 'Company',      label: 'Company',  numeric: false },
    { key: 'FileHash',     label: 'SHA256',   numeric: false },
    { key: 'IsPrivatePath',label: 'Private',  numeric: false },
    { key: '_signed',      label: 'Sig',      numeric: false },
    { key: '_signerCo',    label: 'Signer',   numeric: false },
  ];
  const h = el('dlls-header');
  if (!h) return;
  h.style.gridTemplateColumns = COLS;
  h.innerHTML = headers.map(hd => {
    const arrow = (sortState.tab === 'dlls' && sortState.column === hd.key)
      ? (sortState.dir === 'asc' ? '↑' : sortState.dir === 'desc' ? '↓' : '⇅') : '⇅';
    const arrowCls = (sortState.tab === 'dlls' && sortState.column === hd.key && sortState.dir !== 'none')
      ? ' class="sort-arrow ' + sortState.dir + '"' : ' class="sort-arrow"';
    return `<div class="th sortable-th" onclick="sortTable('dlls','${hd.key}',${hd.numeric})">${esc(hd.label)} <span id="sort-dlls-${hd.key}"${arrowCls}>${arrow}</span></div>`;
  }).join('');
  setTimeout(() => addResizeHandles('dlls-header', 'dlls'), 0);
}

function applyDllFilters() {
  const d = activeData(); if (!d || !d.DLLs) return;
  const lq = dllFilters.search.toLowerCase();

  let rows = d.DLLs.slice().map(e => Object.assign({}, e, {
    _signed:   e.Signature ? e.Signature.IsSigned : null,
    _signerCo: e.Signature ? (e.Signature.SignerCompany || '') : '',
  }));

  if (lq) rows = rows.filter(e =>
    str(e.ProcessName).includes(lq) ||
    str(e.ModuleName).includes(lq)  ||
    str(e.ModulePath).includes(lq)  ||
    str(e.Company).includes(lq)     ||
    str(e.ProcessId).includes(lq)   ||
    str(e.FileHash).includes(lq)    ||
    str(e._signerCo).includes(lq)   ||
    (e.Signature ? str(e.Signature.Status).includes(lq) : false)
  );
  if (dllFilters.unsignedOnly) rows = rows.filter(e => !e._signed);
  if (dllFilters.privateOnly)  rows = rows.filter(e => e.IsPrivatePath === true);
  if (sortState.tab === 'dlls' && sortState.column && sortState.dir !== 'none') {
    const numericDllCols = new Set(['ProcessId']);
    rows = applySortToRows(rows, sortState.column, numericDllCols.has(sortState.column));
  } else {
    rows.sort((a, b) => {
      const av = a[dllSort.col]; const bv = b[dllSort.col];
      if (typeof av === 'number' && typeof bv === 'number') return (av - bv) * dllSort.dir;
      return String(av||'').localeCompare(String(bv||'')) * dllSort.dir;
    });
  }
  dllData = rows;

  const cnt = el('dlls-count');
  if (cnt) cnt.textContent = rows.length + ' entries';

  const COLS = '140px 55px 160px 220px 90px 140px 145px 55px 40px 120px';
  state.expandedRows['dlls'] = null;

  if (state.vsInstances['dlls']) {
    state.vsInstances['dlls'].update(rows);
  } else {
    state.vsInstances['dlls'] = createVS('dlls-vs', COLS, rows, renderDllRow, onDllRowClick, 'dlls');
  }
}

function renderDllRow(e, i) {
  const sha     = e.FileHash || (e.SHA256Error ? e.SHA256Error : '');
  const shaTitle = e.FileHash || e.SHA256Error || '';
  const shaCls  = !e.FileHash && e.SHA256Error ? 'td amber' : 'td mono dim';
  const privCls = e.IsPrivatePath ? 'amber' : 'dim';
  const sig     = e.Signature || null;
  const signerCo = e._signerCo || (sig ? (sig.SignerCompany || '') : '');
  const pathStr = e.ModulePath ? esc(e.ModulePath) : (e.reason ? '[' + esc(e.reason) + ']' : '');
  return `
    <div class="td link" onclick="event.stopPropagation();dllGotoProcess(${e.ProcessId})">${esc(e.ProcessName||'')}</div>
    <div class="td dim">${e.ProcessId != null ? e.ProcessId : ''}</div>
    <div class="td mono">${esc(e.ModuleName||'')}</div>
    <div class="td dim mono" title="${esc(e.ModulePath||'')}">${pathStr}</div>
    <div class="td dim">${esc(e.FileVersion||'')}</div>
    <div class="td dim">${esc(e.Company||'')}</div>
    <div class="${shaCls}" title="${esc(shaTitle)}">${esc(sha)}</div>
    <div class="td ${privCls}">${e.IsPrivatePath===true?'yes':''}</div>
    <div class="td" title="${sig && /^PS2_/.test(sig.Status||'') ? 'PS2: unvalidated (cert presence only)' : (sig ? (sig.Status||'') : '')}">${renderSignedIcon(sig)}${sig && /^PS2_/.test(sig.Status||'') ? '<span style="font-size:8px;color:var(--amber)" title="PS2 — signature not validated">&#9679;</span>' : ''}</div>
    <div class="td dim">${esc(signerCo)}</div>`;
}

function onDllRowClick(i, e, rowEl) {
  if (e.IsPrivatePath) rowEl.classList.add('row-private');

  const vs   = state.vsInstances['dlls'];
  const prev = state.expandedRows['dlls'];
  if (prev === i) {
    state.expandedRows['dlls'] = null;
    if (vs) vs.collapse();
    return;
  }
  state.expandedRows['dlls'] = i;

  const d = activeData();
  // Show all sibling DLLs (unfiltered) for forensic completeness
  const allSameProc = (d.DLLs||[]).filter(x => x.ProcessId == e.ProcessId && x !== e);
  const INITIAL_SHOW = 30;
  const shown = allSameProc.slice(0, INITIAL_SHOW);
  const more  = allSameProc.length - shown.length;
  const sameProcRows = items => items.map(x => `<tr><td class="mono">${esc(x.ModuleName||'')}</td><td class="mono">${esc(x.ModulePath||'')}</td></tr>`).join('');
  const expandId = '_dllExpand_' + i;
  const sameProcHTML = shown.length ? `
    <h4 style="margin-top:8px">Other DLLs loaded by this process (${allSameProc.length})</h4>
    <table class="expand-tbl"><tr><th>DLL Name</th><th>Path</th></tr>` +
    sameProcRows(shown) +
    `<tbody id="${expandId}"></tbody></table>` +
    (more > 0 ? `<a id="${expandId}_link" style="cursor:pointer;font-size:11px;color:var(--link)">${more} more &mdash; show all</a>` : '') : '';

  const privBadge = e.IsPrivatePath
    ? `<span style="background:rgba(255,180,0,0.3);padding:1px 6px;border-radius:3px;color:var(--amber)">PRIVATE PATH</span>`
    : `<span style="color:var(--muted)">no</span>`;
  const sig2 = e.Signature || null;
  const shaDisplay = e.FileHash
    ? `<span class="mono">${esc(e.FileHash)}</span>`
    : (e.SHA256Error ? `<span style="color:var(--amber)">${esc(e.SHA256Error)}</span>` : '—');

  const expand = document.createElement('div');
  expand.innerHTML = `
    <div class="kv-grid">
      <span class="k">Process</span>      <span class="v"><a onclick="dllGotoProcess(${e.ProcessId})">${esc(e.ProcessName||'')} [${e.ProcessId}]</a></span>
      <span class="k">DLL Name</span>     <span class="v mono">${esc(e.ModuleName||'')}</span>
      <span class="k">Full Path</span>    <span class="v mono">${esc(e.ModulePath||'—')}</span>
      <span class="k">FileVersion</span>  <span class="v">${esc(e.FileVersion||'—')}</span>
      <span class="k">Company</span>      <span class="v">${esc(e.Company||'—')}</span>
      <span class="k">SHA256</span>       <span class="v">${shaDisplay}</span>
      <span class="k">Private Path</span> <span class="v">${privBadge}</span>
      <span class="k">Signed</span>       <span class="v">${renderSignedIcon(sig2)}</span>
      ${sig2 ? `<span class="k">Sig Status</span>   <span class="v${/^PS2_/.test(sig2.Status||'')?' style="color:var(--amber)"':''}">${esc(sig2.Status||'—')}${/^PS2_/.test(sig2.Status||'')?' (unvalidated)':''}</span>
      <span class="k">IsOSBinary</span>   <span class="v" style="color:${sig2.IsOSBinary===true?'var(--green)':sig2.IsOSBinary===false?'var(--red)':'var(--muted)'}">${sig2.IsOSBinary===true?'Yes':sig2.IsOSBinary===false?'No':'—'}</span>
      <span class="k">SignatureType</span><span class="v">${esc(sig2.SignatureType||'—')}</span>
      <span class="k">SignerSubject</span> <span class="v">${esc(sig2.SignerSubject||'—')}</span>
      <span class="k">SignerCompany</span> <span class="v">${esc(sig2.SignerCompany||'—')}</span>
      <span class="k">Issuer</span>       <span class="v">${esc(sig2.Issuer||'—')}</span>
      <span class="k">Thumbprint</span>   <span class="v mono">${esc(sig2.Thumbprint||'—')}</span>
      <span class="k">NotAfter</span>     <span class="v">${esc(sig2.NotAfter||'—')}</span>
      <span class="k">TimeStamper</span>  <span class="v">${esc(sig2.TimeStamper||'—')}</span>` : ''}
      ${e.source ? `<span class="k">Source</span><span class="v">${esc(e.source)}</span>` : ''}
      ${e.reason ? `<span class="k">Reason</span><span class="v" style="color:var(--red)">${esc(e.reason)}</span>` : ''}
    </div>
    ${sameProcHTML}`;

  if (vs) vs.expand(i, expand);

  // Attach show-all handler via DOM (avoids inline HTML injection)
  if (more > 0) {
    const link = document.getElementById(expandId + '_link');
    if (link) {
      const extraRows = allSameProc.slice(INITIAL_SHOW);
      link.addEventListener('click', function() {
        this.style.display = 'none';
        const tbody = document.getElementById(expandId);
        if (tbody) tbody.innerHTML = sameProcRows(extraRows);
      });
    }
  }
}

function dllSortBy(col) {
  if (dllSort.col === col) dllSort.dir *= -1; else { dllSort.col = col; dllSort.dir = 1; }
  buildDllHeader('140px 55px 160px 220px 90px 140px 145px 55px 40px 120px');
  applyDllFilters();
}

function dllGotoProcess(pid) { navigateToRow('processes', 'ProcessId', pid); }
