// ── DLLs TAB ──────────────────────────────────────────────────────────────────

// Inject row-private style
(function() {
  const s = document.createElement('style');
  s.textContent = '.row-private { background: rgba(255,180,0,0.15); }';
  document.head.appendChild(s);
})();

let dllFilters = { search: '' };
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
      <input type="text" id="dlls-search" placeholder="Process, DLL name, path, company&hellip;" style="width:280px"
             oninput="dllFilters.search=this.value;applyDllFilters()">
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
    str(e.ProcessId).includes(lq)
  );
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
    state.vsInstances['dlls'] = createVS('dlls-vs', COLS, rows, renderDllRow, onDllRowClick);
  }
}

function renderDllRow(e, i) {
  const sha     = e.FileHash ? (e.FileHash.slice(0, 16) + '...') : (e.SHA256Error ? e.SHA256Error : '');
  const shaTitle = e.FileHash || e.SHA256Error || '';
  const shaCls  = !e.FileHash && e.SHA256Error ? 'td amber' : 'td mono dim';
  const privCls = e.IsPrivatePath ? 'amber' : 'dim';
  const sig     = e.Signature || null;
  const signerCo = e._signerCo || (sig ? (sig.SignerCompany || '') : '');
  const pathTrunc = e.ModulePath ? trunc(e.ModulePath, 32) : (e.reason ? '[' + esc(e.reason) + ']' : '');
  const nameTrunc = trunc(e.ModuleName || '', 22);
  return `
    <div class="td link" onclick="event.stopPropagation();dllGotoProcess(${e.ProcessId})">${esc(trunc(e.ProcessName||'',18))}</div>
    <div class="td dim">${e.ProcessId != null ? e.ProcessId : ''}</div>
    <div class="td mono">${esc(nameTrunc)}</div>
    <div class="td dim mono" title="${esc(e.ModulePath||'')}">${esc(pathTrunc)}</div>
    <div class="td dim">${esc(trunc(e.FileVersion||'',12))}</div>
    <div class="td dim">${esc(trunc(e.Company||'',18))}</div>
    <div class="${shaCls}" title="${esc(shaTitle)}">${esc(sha)}</div>
    <div class="td ${privCls}">${e.IsPrivatePath===true?'yes':''}</div>
    <div class="td">${renderSignedIcon(sig)}</div>
    <div class="td dim">${esc(trunc(signerCo,16))}</div>`;
}

function onDllRowClick(i, e, rowEl) {
  // Apply private row color to the vrow element itself
  if (e.IsPrivatePath) rowEl.classList.add('row-private');

  const vsWrap = el('dlls-vs');
  const prev   = state.expandedRows['dlls'];
  const prevEl = vsWrap ? vsWrap.querySelector('.expand-row') : null;
  if (prevEl) prevEl.remove();
  if (prev === i) { state.expandedRows['dlls'] = null; return; }
  state.expandedRows['dlls'] = i;

  const d = activeData();

  // Other DLLs from same process
  const sameProc = (d.DLLs||[]).filter(x => x.ProcessId == e.ProcessId && x !== e).slice(0, 30);
  const sameProcHTML = sameProc.length ? `
    <h4 style="margin-top:8px">Other DLLs loaded by this process (${sameProc.length}${sameProc.length===30?' shown, more may exist':''})</h4>
    <table class="expand-tbl"><tr><th>DLL Name</th><th>Path</th><th>Signed</th></tr>` +
    sameProc.map(x=>`<tr><td class="mono">${esc(x.ModuleName||'')}</td><td class="mono">${esc(x.ModulePath||'')}</td><td>${x.Signature?(x.Signature.IsSigned===true?'yes':x.Signature.IsSigned===false?'no':''):''}</td></tr>`).join('') +
    '</table>' : '';

  const privBadge = e.IsPrivatePath
    ? `<span style="background:rgba(255,180,0,0.3);padding:1px 6px;border-radius:3px;color:var(--amber)">PRIVATE PATH</span>`
    : `<span style="color:var(--muted)">no</span>`;
  const sig2 = e.Signature || null;
  const signBadge = renderSignedIcon(sig2);
  const shaDisplay = e.FileHash
    ? `<span class="mono">${esc(e.FileHash)}</span>`
    : (e.SHA256Error ? `<span style="color:var(--amber)">${esc(e.SHA256Error)}</span>` : '—');

  const expand = document.createElement('div');
  expand.className = 'expand-row';
  expand.innerHTML = `
    <div class="kv-grid">
      <span class="k">Process</span>      <span class="v"><a onclick="dllGotoProcess(${e.ProcessId})">${esc(e.ProcessName||'')} [${e.ProcessId}]</a></span>
      <span class="k">DLL Name</span>     <span class="v mono">${esc(e.ModuleName||'')}</span>
      <span class="k">Full Path</span>    <span class="v mono">${esc(e.ModulePath||'—')}</span>
      <span class="k">FileVersion</span>  <span class="v">${esc(e.FileVersion||'—')}</span>
      <span class="k">Company</span>      <span class="v">${esc(e.Company||'—')}</span>
      <span class="k">SHA256</span>       <span class="v">${shaDisplay}</span>
      <span class="k">Private Path</span> <span class="v">${privBadge}</span>
      <span class="k">Signed</span>       <span class="v">${signBadge}</span>
      ${sig2 ? `<span class="k">Sig Status</span>   <span class="v">${esc(sig2.Status||'—')}</span>
      <span class="k">SignerSubject</span> <span class="v">${esc(sig2.SignerSubject||'—')}</span>
      <span class="k">SignerCompany</span> <span class="v">${esc(sig2.SignerCompany||'—')}</span>
      <span class="k">Thumbprint</span>   <span class="v mono">${esc(sig2.Thumbprint||'—')}</span>
      <span class="k">NotAfter</span>     <span class="v">${esc(sig2.NotAfter||'—')}</span>
      <span class="k">TimeStamper</span>  <span class="v">${esc(sig2.TimeStamper||'—')}</span>` : ''}
      ${e.reason ? `<span class="k">Reason</span><span class="v" style="color:var(--red)">${esc(e.reason)}</span>` : ''}
    </div>
    ${sameProcHTML}`;

  const viewport = rowEl.closest('.vscroll-viewport');
  if (viewport) {
    const inner = viewport.querySelector('.vscroll-inner');
    expand.style.position = 'absolute';
    expand.style.top      = (parseInt(rowEl.style.top) + ROW_H) + 'px';
    expand.style.left     = '0';
    expand.style.width    = '100%';
    inner.appendChild(expand);
  }
}

function dllSortBy(col) {
  if (dllSort.col === col) dllSort.dir *= -1; else { dllSort.col = col; dllSort.dir = 1; }
  buildDllHeader('140px 55px 160px 220px 90px 140px 145px 55px 40px 120px');
  applyDllFilters();
}

function dllGotoProcess(pid) { navigateToRow('processes', 'ProcessId', pid); }
