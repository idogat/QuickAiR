// ── NETWORK TAB ───────────────────────────────────────────────────────────────
let netFilters = { search: '', state: '', iface: '' };
let netSort    = { col: 'State', dir: 1 };
let netData    = [];

function renderNetwork() {
  const panel = el('panel-network');
  const d     = activeData();
  if (!d) { panel.innerHTML = '<div class="solo-notice">No file loaded.</div>'; return; }

  // Build dropdown options from data
  const states = [...new Set((d.network_tcp||[]).map(c=>c.State).filter(Boolean))].sort();
  const ifaces = [...new Set((d.network_tcp||[]).map(c=>c.InterfaceAlias).filter(Boolean))].sort();

  const stateOpts = `<option value="">All States</option>` + states.map(s=>`<option value="${esc(s)}">${esc(s)}</option>`).join('');
  const ifaceOpts = `<option value="">All Interfaces</option>` + ifaces.map(i=>`<option value="${esc(i)}">${esc(i)}</option>`).join('');

  const COLS = '140px 60px 130px 60px 140px 60px 160px 160px 140px 100px 55px';

  panel.innerHTML = `
    <div class="filter-bar">
      <input type="text" id="net-search" placeholder="IP, port, process, DNS, interface&hellip;" style="width:280px"
             oninput="netFilters.search=this.value;applyNetFilters()">
      <select onchange="netFilters.state=this.value;applyNetFilters()">${stateOpts}</select>
      <select onchange="netFilters.iface=this.value;applyNetFilters()">${ifaceOpts}</select>
      <span id="net-count" style="color:var(--muted);font-size:11px;margin-left:8px"></span>
    </div>
    <div class="tbl-wrap">
      <div class="tbl-header" style="grid-template-columns:${COLS}" id="net-header"></div>
      <div id="net-vs"></div>
    </div>
    <div id="ip-summary">
      <h3>Remote IP Summary</h3>
      <table id="ip-summary-tbl"><thead><tr>
        <th>IP</th><th>Reverse DNS</th><th>DNS Match</th><th>Connections</th><th>Processes</th>
      </tr></thead><tbody id="ip-summary-body"></tbody></table>
    </div>`;

  state.vsInstances['net'] = null;
  buildNetHeader(COLS);
  applyNetFilters();
}

function buildNetHeader(COLS) {
  const headers = [
    {key:'_procName',     label:'Process',    numeric:false },
    {key:'OwningProcess', label:'PID',        numeric:true  },
    {key:'LocalAddress',  label:'Local Addr', numeric:false },
    {key:'LocalPort',     label:'L.Port',     numeric:true  },
    {key:'RemoteAddress', label:'Remote Addr',numeric:false },
    {key:'RemotePort',    label:'R.Port',     numeric:true  },
    {key:'DnsMatch',      label:'DNS Match',  numeric:false },
    {key:'ReverseDns',    label:'Reverse DNS',numeric:false },
    {key:'InterfaceAlias',label:'Interface',  numeric:false },
    {key:'State',         label:'State',      numeric:false },
    {key:'IsPrivateIP',   label:'Private',    numeric:false },
  ];
  const h = el('net-header');
  if (!h) return;
  h.innerHTML = headers.map(hd => {
    const arrow = (sortState.tab === 'network' && sortState.column === hd.key)
      ? (sortState.dir === 'asc' ? '↑' : sortState.dir === 'desc' ? '↓' : '⇅') : '⇅';
    const arrowCls = (sortState.tab === 'network' && sortState.column === hd.key && sortState.dir !== 'none')
      ? ' class="sort-arrow ' + sortState.dir + '"' : ' class="sort-arrow"';
    return `<div class="th sortable-th" onclick="sortTable('network','${hd.key}',${hd.numeric})">${esc(hd.label)} <span id="sort-network-${hd.key}"${arrowCls}>${arrow}</span></div>`;
  }).join('');
  setTimeout(() => addResizeHandles('net-header', 'network'), 0);
}

function applyNetFilters() {
  const d = activeData(); if (!d) return;
  const lq = netFilters.search.toLowerCase();

  // Build pid->name map
  const nameMap = {};
  (d.processes||[]).forEach(p => nameMap[p.ProcessId] = p.Name);

  let rows = (d.network_tcp||[]).map(c => Object.assign({}, c, {
    _procName: nameMap[c.OwningProcess] || String(c.OwningProcess)
  }));

  if (lq) rows = rows.filter(c =>
    str(c.RemoteAddress).includes(lq) || str(c.RemotePort).includes(lq) ||
    str(c.LocalAddress).includes(lq)  || str(c.LocalPort).includes(lq) ||
    str(c.State).includes(lq)         || str(c.DnsMatch).includes(lq) ||
    str(c.ReverseDns).includes(lq)    || str(c.InterfaceAlias).includes(lq) ||
    str(c._procName).includes(lq)     || str(c.OwningProcess).includes(lq)
  );
  if (netFilters.state) rows = rows.filter(c => c.State === netFilters.state);
  if (netFilters.iface) rows = rows.filter(c => c.InterfaceAlias === netFilters.iface);

  if (sortState.tab === 'network' && sortState.column && sortState.dir !== 'none') {
    const numericNetCols = new Set(['OwningProcess','LocalPort','RemotePort']);
    rows = applySortToRows(rows, sortState.column, numericNetCols.has(sortState.column));
  } else {
    rows.sort((a,b) => {
      const av = a[netSort.col]; const bv = b[netSort.col];
      if (typeof av === 'number') return (av-bv)*netSort.dir;
      return String(av||'').localeCompare(String(bv||''))*netSort.dir;
    });
  }
  netData = rows;

  const cnt = el('net-count');
  if (cnt) cnt.textContent = rows.length + ' connections';

  const COLS = '140px 60px 130px 60px 140px 60px 160px 160px 140px 100px 55px';
  state.expandedRows['net'] = null;

  if (state.vsInstances['net']) {
    state.vsInstances['net'].update(rows);
  } else {
    state.vsInstances['net'] = createVS('net-vs', COLS, rows, renderNetRow, onNetRowClick, 'network');
  }

  buildIpSummary(d, rows);
}

function renderNetRow(c, i) {
  const stCls     = c.State==='ESTABLISHED'?'green': c.State==='LISTEN'?'accent':'dim';
  const ifAlias   = c.InterfaceAlias || '';
  const ifColor   = ifaceColor(ifAlias, getAdapterAliases());
  return `
    <div class="td link" onclick="event.stopPropagation();gotoProcessPid(${c.OwningProcess})">${esc(c._procName)}</div>
    <div class="td dim">${c.OwningProcess}</div>
    <div class="td mono dim">${esc(c.LocalAddress)}</div>
    <div class="td dim">${c.LocalPort}</div>
    <div class="td mono">${esc(c.RemoteAddress)}</div>
    <div class="td">${c.RemotePort}</div>
    <div class="td accent">${esc(c.DnsMatch||'')}</div>
    <div class="td dim">${esc(c.ReverseDns||'')}</div>
    <div class="td"><span style="color:${ifColor};font-weight:bold">${esc(ifAlias)}</span></div>
    <div class="td ${stCls}">${esc(c.State)}</div>
    <div class="td dim">${c.IsPrivateIP?'yes':''}</div>`;
}

function onNetRowClick(i, c, rowEl) {
  const vs   = state.vsInstances['net'];
  const prev = state.expandedRows['net'];
  if (prev === i) {
    state.expandedRows['net'] = null;
    if (vs) vs.collapse();
    return;
  }
  state.expandedRows['net'] = i;

  const d = activeData();
  const proc = (d.processes||[]).find(p => p.ProcessId == c.OwningProcess);
  const sameProc = (d.network_tcp||[]).filter(x => x.OwningProcess == c.OwningProcess).slice(0,20);
  const sameIP   = c.RemoteAddress && c.RemoteAddress !== '0.0.0.0'
    ? (d.network_tcp||[]).filter(x => x.RemoteAddress === c.RemoteAddress && x.OwningProcess !== c.OwningProcess).slice(0,20)
    : [];

  const sameProcHTML = sameProc.length > 1 ? `
    <h4 style="margin-top:8px">All connections from this process (${sameProc.length})</h4>
    <table class="expand-tbl"><tr><th>Remote</th><th>Port</th><th>State</th><th>DNS</th></tr>` +
    sameProc.map(x=>`<tr><td class="mono">${esc(x.RemoteAddress)}</td><td>${x.RemotePort}</td><td>${esc(x.State)}</td><td>${esc(x.DnsMatch||'')}</td></tr>`).join('') +
    '</table>' : '';

  const sameIPHTML = sameIP.length ? `
    <h4 style="margin-top:8px">Other connections to ${esc(c.RemoteAddress)} (${sameIP.length})</h4>
    <table class="expand-tbl"><tr><th>Process</th><th>PID</th><th>L.Port</th><th>State</th></tr>` +
    sameIP.map(x=>`<tr><td>${esc(getProcName(x.OwningProcess,d))}</td><td>${x.OwningProcess}</td><td>${x.LocalPort}</td><td>${esc(x.State)}</td></tr>`).join('') +
    '</table>' : '';

  const expand = document.createElement('div');
  expand.innerHTML = `
    <div class="kv-grid">
      <span class="k">Process</span>       <span class="v"><a onclick="gotoProcessPid(${c.OwningProcess})">${esc(c._procName)} [${c.OwningProcess}]</a></span>
      <span class="k">Executable</span>    <span class="v">${esc(proc ? (proc.ExecutablePath||'—') : '—')}</span>
      <span class="k">CommandLine</span>   <span class="v">${esc(proc ? (proc.CommandLine||'—') : '—')}</span>
      <span class="k">Local</span>         <span class="v">${esc(c.LocalAddress)}:${c.LocalPort}</span>
      <span class="k">Remote</span>        <span class="v">${esc(c.RemoteAddress)}:${c.RemotePort}</span>
      <span class="k">State</span>         <span class="v">${esc(c.State)}</span>
      <span class="k">Interface</span>     <span class="v">${esc(c.InterfaceAlias||'')}</span>
      <span class="k">DNS Match</span>     <span class="v">${esc(c.DnsMatch||'—')}</span>
      <span class="k">Reverse DNS</span>   <span class="v">${esc(c.ReverseDns||'—')}</span>
      <span class="k">Private IP</span>    <span class="v">${c.IsPrivateIP?'Yes':'No'}</span>
    </div>
    ${sameProcHTML}${sameIPHTML}`;

  if (vs) vs.expand(i, expand);
}

function buildIpSummary(d, filteredConns) {
  const tbody = el('ip-summary-body');
  if (!tbody) return;

  const dnsIPs = new Set((d.dns_cache||[]).map(e=>e.Data).filter(Boolean));
  const ipMap  = {};
  filteredConns.forEach(c => {
    if (!c.RemoteAddress || c.RemoteAddress==='0.0.0.0' || c.RemoteAddress==='::') return;
    if (!ipMap[c.RemoteAddress]) {
      ipMap[c.RemoteAddress] = { ip: c.RemoteAddress, revDns: c.ReverseDns||'', dnsMatch: c.DnsMatch||'', count:0, procs:new Set() };
    }
    ipMap[c.RemoteAddress].count++;
    ipMap[c.RemoteAddress].procs.add(getProcName(c.OwningProcess,d));
    if (!ipMap[c.RemoteAddress].revDns && c.ReverseDns)  ipMap[c.RemoteAddress].revDns  = c.ReverseDns;
    if (!ipMap[c.RemoteAddress].dnsMatch && c.DnsMatch)  ipMap[c.RemoteAddress].dnsMatch = c.DnsMatch;
  });

  const sorted = Object.values(ipMap).sort((a,b)=>b.count-a.count).slice(0,100);
  tbody.innerHTML = sorted.map(r => {
    const inDns = dnsIPs.has(r.ip);
    return `<tr>
      <td class="mono ${inDns?'ip-in-dns':''}">${esc(r.ip)}</td>
      <td>${esc(r.revDns)}</td>
      <td>${esc(r.dnsMatch)}</td>
      <td>${r.count}</td>
      <td>${esc([...r.procs].slice(0,5).join(', '))}</td>
    </tr>`;
  }).join('');
}

function netSortBy(col) {
  if (netSort.col === col) netSort.dir *= -1; else { netSort.col = col; netSort.dir = 1; }
  buildNetHeader('140px 60px 130px 60px 140px 60px 160px 160px 140px 100px 55px');
  applyNetFilters();
}

function highlightNetworkIp(ip) {
  const idx = netData.findIndex(c => c.RemoteAddress === ip);
  if (idx < 0) return;
  const vs = state.vsInstances['net'];
  if (vs) vs.scrollToIndex(idx);
}

function highlightNetworkPid(pid) {
  netFilters.search = String(pid);
  const inp = el('net-search');
  if (inp) inp.value = String(pid);
  applyNetFilters();
}

