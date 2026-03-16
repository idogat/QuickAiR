// ── DLLs TAB ──────────────────────────────────────────────────────────────────

// Inject row-private style
(function() {
  const s = document.createElement('style');
  s.textContent = '.row-private { background: rgba(255,180,0,0.15); }';
  document.head.appendChild(s);
})();

let dllFilters = { search: '', privateOnly: false, nonSystem: false, hasFileHash: false };
let dllSort    = { col: 'ProcessName', dir: 1 };
let dllData    = [];

const DLL_SYS32  = 'C:\\Windows\\System32\\';
const DLL_SYSWOW = 'C:\\Windows\\SysWOW64\\';

function isDllSystem(path) {
  if (!path) return false;
  const p = path.toUpperCase();
  return p.startsWith(DLL_SYS32.toUpperCase()) || p.startsWith(DLL_SYSWOW.toUpperCase());
}

function renderDlls() {
  const panel = el('panel-dlls');
  const d     = activeData();
  if (!d) { panel.innerHTML = '<div class="solo-notice">No file loaded.</div>'; return; }

  if (!d.DLLs || !d.DLLs.length) {
    panel.innerHTML = '<div class="solo-notice">No DLL data in this JSON.</div>';
    return;
  }

  const COLS = '140px 55px 160px 220px 90px 140px 145px 55px 55px';

  panel.innerHTML = `
    <div class="filter-bar" id="dlls-filter-bar">
      <input type="text" id="dlls-search" placeholder="Process, DLL name, path, company&hellip;" style="width:280px"
             oninput="dllFilters.search=this.value;applyDllFilters()">
      <label><input type="checkbox" id="dlls-private"   onchange="dllFilters.privateOnly=this.checked;applyDllFilters()"> Private only</label>
      <label><input type="checkbox" id="dlls-nonsystem" onchange="dllFilters.nonSystem=this.checked;applyDllFilters()"> Non-system only</label>
      <label><input type="checkbox" id="dlls-sha256"    onchange="dllFilters.hasFileHash=this.checked;applyDllFilters()"> Has FileHash</label>
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
    { key: 'ProcessName', label: 'Process'   },
    { key: 'ProcessId',   label: 'PID'       },
    { key: 'ModuleName',  label: 'DLL Name'  },
    { key: 'ModulePath',  label: 'Path'      },
    { key: 'FileVersion', label: 'Version'   },
    { key: 'Company',     label: 'Company'   },
    { key: 'FileHash',      label: 'FileHash'    },
    { key: 'IsPrivatePath',label: 'Private'  },
    { key: 'IsSigned',    label: 'Signed'    },
  ];
  const h = el('dlls-header');
  if (!h) return;
  h.style.gridTemplateColumns = COLS;
  h.innerHTML = headers.map(hd => {
    const cls = dllSort.col === hd.key ? (dllSort.dir===1?'th sort-asc':'th sort-desc') : 'th';
    return `<div class="${cls}" onclick="dllSortBy('${hd.key}')">${esc(hd.label)}</div>`;
  }).join('');
}

function applyDllFilters() {
  const d = activeData(); if (!d || !d.DLLs) return;
  const lq = dllFilters.search.toLowerCase();

  let rows = d.DLLs.slice();

  if (lq) rows = rows.filter(e =>
    str(e.ProcessName).includes(lq) ||
    str(e.ModuleName).includes(lq)  ||
    str(e.ModulePath).includes(lq)  ||
    str(e.Company).includes(lq)     ||
    str(e.ProcessId).includes(lq)
  );
  if (dllFilters.privateOnly) rows = rows.filter(e => e.IsPrivatePath === true);
  if (dllFilters.nonSystem)   rows = rows.filter(e => !isDllSystem(e.ModulePath));
  if (dllFilters.hasFileHash) rows = rows.filter(e => e.FileHash != null && e.FileHash !== '');

  rows.sort((a, b) => {
    const av = a[dllSort.col]; const bv = b[dllSort.col];
    if (typeof av === 'number' && typeof bv === 'number') return (av - bv) * dllSort.dir;
    return String(av||'').localeCompare(String(bv||'')) * dllSort.dir;
  });
  dllData = rows;

  const cnt = el('dlls-count');
  if (cnt) cnt.textContent = rows.length + ' entries';

  const COLS = '140px 55px 160px 220px 90px 140px 145px 55px 55px';
  state.expandedRows['dlls'] = null;

  if (state.vsInstances['dlls']) {
    state.vsInstances['dlls'].update(rows);
  } else {
    state.vsInstances['dlls'] = createVS('dlls-vs', COLS, rows, renderDllRow, onDllRowClick);
  }
}

function renderDllRow(e, i) {
  const sha = e.FileHash ? (e.FileHash.slice(0, 16) + '...') : '';
  const privCls  = e.IsPrivatePath ? 'amber' : 'dim';
  const signCls  = e.IsSigned === true ? 'green' : (e.IsSigned === false ? 'red' : 'dim');
  const signTxt  = e.IsSigned === true ? 'yes' : (e.IsSigned === false ? 'no' : '');
  const rowCls   = e.IsPrivatePath ? 'row-private' : '';
  const pathTrunc = e.ModulePath ? trunc(e.ModulePath, 32) : (e.reason ? '[' + esc(e.reason) + ']' : '');
  const nameTrunc = trunc(e.ModuleName || '', 22);
  // Note: row class injected via the vrow itself - we add it via a trick on the wrapper
  // We prefix the first td with a data attribute we can use to style the row
  return `
    <div class="td link" onclick="event.stopPropagation();dllGotoProcess(${e.ProcessId})">${esc(trunc(e.ProcessName||'',18))}</div>
    <div class="td dim">${e.ProcessId != null ? e.ProcessId : ''}</div>
    <div class="td mono">${esc(nameTrunc)}</div>
    <div class="td dim mono" title="${esc(e.ModulePath||'')}">${esc(pathTrunc)}</div>
    <div class="td dim">${esc(trunc(e.FileVersion||'',12))}</div>
    <div class="td dim">${esc(trunc(e.Company||'',18))}</div>
    <div class="td mono dim" title="${esc(e.FileHash||'')}">${esc(sha)}</div>
    <div class="td ${privCls}">${e.IsPrivatePath===true?'yes':''}</div>
    <div class="td ${signCls}">${signTxt}</div>`;
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
    sameProc.map(x=>`<tr><td class="mono">${esc(x.ModuleName||'')}</td><td class="mono">${esc(x.ModulePath||'')}</td><td>${x.IsSigned===true?'yes':x.IsSigned===false?'no':''}</td></tr>`).join('') +
    '</table>' : '';

  const privBadge = e.IsPrivatePath
    ? `<span style="background:rgba(255,180,0,0.3);padding:1px 6px;border-radius:3px;color:var(--amber)">PRIVATE PATH</span>`
    : `<span style="color:var(--muted)">no</span>`;
  const signBadge = e.IsSigned === true
    ? `<span style="color:var(--green)">SIGNED</span>`
    : e.IsSigned === false
      ? `<span style="color:var(--red)">NOT SIGNED</span>`
      : `<span style="color:var(--muted)">unknown</span>`;

  const expand = document.createElement('div');
  expand.className = 'expand-row';
  expand.innerHTML = `
    <div class="kv-grid">
      <span class="k">Process</span>      <span class="v"><a onclick="dllGotoProcess(${e.ProcessId})">${esc(e.ProcessName||'')} [${e.ProcessId}]</a></span>
      <span class="k">DLL Name</span>     <span class="v mono">${esc(e.ModuleName||'')}</span>
      <span class="k">Full Path</span>    <span class="v mono">${esc(e.ModulePath||'—')}</span>
      <span class="k">FileVersion</span>  <span class="v">${esc(e.FileVersion||'—')}</span>
      <span class="k">Company</span>      <span class="v">${esc(e.Company||'—')}</span>
      <span class="k">FileHash</span>       <span class="v mono">${esc(e.FileHash||'—')}</span>
      <span class="k">Private Path</span> <span class="v">${privBadge}</span>
      <span class="k">Signed</span>       <span class="v">${signBadge}</span>
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
  buildDllHeader('140px 55px 160px 220px 90px 140px 145px 55px 55px');
  applyDllFilters();
}

function dllGotoProcess(pid) {
  switchTab('processes');
  setTimeout(() => highlightProcessPid(pid), 100);
}
