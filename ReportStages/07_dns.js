// ╔══════════════════════════════════════╗
// ║  QuickAiR — 07_dns.js                 ║
// ║  DNS tab render, virtual scroll,     ║
// ║  correlation summary, fallback       ║
// ║  banner, cross-reference clicks      ║
// ║  to Processes tab                    ║
// ╠══════════════════════════════════════╣
// ║  Reads    : activeHost.dns_cache,      ║
// ║             activeHost.network_tcp,   ║
// ║             activeHost.network_udp    ║
// ║  Writes   : dnsFilters, dnsSort       ║
// ║  Functions: renderDns,                ║
// ║    applyDnsFilters, renderDnsRow,     ║
// ║    onDnsRowClick                      ║
// ║  Depends  : 03_core.js               ║
// ║  Version  : 3.40                      ║
// ╚══════════════════════════════════════╝

// ── DNS TAB ───────────────────────────────────────────────────────────────────
let dnsFilters = { search: '' };
let dnsSort    = { col: 'Entry', dir: 1 };
let dnsData    = [];

function renderDns() {
  const panel = el('panel-dns');
  const d     = activeData();
  if (!d) { panel.innerHTML = '<div class="solo-notice">No file loaded.</div>'; return; }

  const src = (d.manifest || {}).dns_source || 'cim';
  const bannerHTML = src !== 'cim'
    ? `<div class="banner warn">DNS collected via <strong>${esc(src)}</strong> — TTL values may be approximate</div>`
    : '';

  const COLS = '280px 140px 60px 60px 180px 80px';

  panel.innerHTML = `
    ${bannerHTML}
    <div id="dns-corr-summary"></div>
    <div class="filter-bar">
      <input type="text" id="dns-search" placeholder="Search hostname, IP, type&hellip;" style="width:260px"
             oninput="dnsFilters.search=this.value;applyDnsFilters()">
      <span id="dns-count" style="color:var(--muted);font-size:11px;margin-left:8px"></span>
    </div>
    <div class="tbl-wrap">
      <div class="tbl-header" style="grid-template-columns:${COLS}" id="dns-header"></div>
      <div id="dns-vs"></div>
    </div>`;

  state.vsInstances['dns'] = null;
  buildDnsHeader(COLS);
  applyDnsFilters();
}

function buildDnsHeader(COLS) {
  const headers = [
    {key:'Entry',          label:'Entry (Hostname)'  },
    {key:'Data',           label:'Resolved IP'       },
    {key:'Type',           label:'Type'              },
    {key:'TTL',            label:'TTL'               },
    {key:'_matchedProcess',label:'Matched Process'   },
    {key:'_matchedPid',    label:'PID'               },
  ];
  const h = el('dns-header');
  if (!h) return;
  h.innerHTML = headers.map(hd => {
    const numeric = /TTL$|Pid$/.test(hd.key);
    const arrow = (sortState.tab === 'dns' && sortState.column === hd.key)
      ? (sortState.dir === 'asc' ? '↑' : sortState.dir === 'desc' ? '↓' : '⇅') : '⇅';
    const arrowCls = (sortState.tab === 'dns' && sortState.column === hd.key && sortState.dir !== 'none')
      ? ' class="sort-arrow ' + sortState.dir + '"' : ' class="sort-arrow"';
    return `<div class="th sortable-th" onclick="sortTable('dns','${hd.key}',${numeric})">${esc(hd.label)} <span id="sort-dns-${hd.key}"${arrowCls}>${arrow}</span></div>`;
  }).join('');
  setTimeout(() => addResizeHandles('dns-header', 'dns'), 0);
}

function applyDnsFilters() {
  const d  = activeData(); if (!d) return;
  const lq = dnsFilters.search.toLowerCase();

  // Build IP -> (process name, pid) map from network_tcp + network_udp
  const ipToProcMap = {};
  (d.network_tcp||[]).concat(d.network_udp||[]).forEach(c => {
    if (c.RemoteAddress && !ipToProcMap[c.RemoteAddress]) {
      ipToProcMap[c.RemoteAddress] = { name: getProcName(c.OwningProcess,d), pid: c.OwningProcess };
    }
  });

  let rows = (d.dns_cache||[]).map(e => {
    const match = e.Data ? ipToProcMap[e.Data] : null;
    return Object.assign({}, e, {
      _matchedProcess: match ? match.name : '',
      _matchedPid:     match ? match.pid  : '',
      _isMatched:      !!match,
    });
  });

  if (lq) rows = rows.filter(e =>
    str(e.Entry).includes(lq) || str(e.Data).includes(lq) ||
    str(e.Type).includes(lq)  || str(e._matchedProcess).includes(lq)
  );
  if (sortState.tab === 'dns' && sortState.column && sortState.dir !== 'none') {
    const numericDnsCols = new Set(['TTL','_matchedPid']);
    rows = applySortToRows(rows, sortState.column, numericDnsCols.has(sortState.column));
  } else {
    rows.sort((a,b) => {
      const av = a[dnsSort.col]; const bv = b[dnsSort.col];
      if (typeof av === 'number') return (av-bv)*dnsSort.dir;
      return String(av||'').localeCompare(String(bv||''))*dnsSort.dir;
    });
  }
  dnsData = rows;

  const cnt = el('dns-count');
  if (cnt) cnt.textContent = rows.length + ' entries';

  // Correlation summary
  const totalDns   = (d.dns_cache||[]).length;
  const matched    = rows.filter(e=>e._isMatched).length;
  const corrSumEl  = el('dns-corr-summary');
  if (corrSumEl) {
    corrSumEl.innerHTML = `<span>${matched}</span> of <span>${totalDns}</span> DNS entries match active connections`;
  }

  const COLS = '280px 140px 60px 60px 180px 80px';
  state.expandedRows['dns'] = null;

  if (state.vsInstances['dns']) {
    state.vsInstances['dns'].update(rows);
  } else {
    state.vsInstances['dns'] = createVS('dns-vs', COLS, rows, renderDnsRow, onDnsRowClick, 'dns');
  }
}

function renderDnsRow(e, i) {
  const rowCls = e._isMatched ? 'highlighted' : '';
  const matchLink = e._matchedPid
    ? `<a onclick="event.stopPropagation();gotoProcessPid(${e._matchedPid})">${esc(e._matchedProcess)}</a>`
    : '';
  // Row class must be set after creation; we use a data attribute trick instead
  return `
    <div class="td">${esc(e.Entry)}</div>
    <div class="td mono">${esc(e.Data||'')}</div>
    <div class="td dim">${esc(e.Type||'')}</div>
    <div class="td dim">${e.TTL||''}</div>
    <div class="td accent">${matchLink}</div>
    <div class="td dim">${esc(e._matchedPid||'')}</div>`;
}

function onDnsRowClick(i, e, rowEl) {
  if (e._matchedPid) {
    gotoProcessPid(e._matchedPid);
  }
  // highlight row
  rowEl.classList.toggle('selected');
}

function dnsSortBy(col) {
  if (dnsSort.col === col) dnsSort.dir *= -1; else { dnsSort.col = col; dnsSort.dir = 1; }
  buildDnsHeader('280px 140px 60px 60px 180px 80px');
  applyDnsFilters();
}

