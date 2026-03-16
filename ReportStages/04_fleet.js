// ── FLEET TAB ─────────────────────────────────────────────────────────────────
let fleetSort = { col: 'hostname', dir: 1 };

function renderFleet() {
  const panel = el('panel-fleet');
  const hosts = Object.keys(state.hosts);

  if (hosts.length === 0) {
    panel.innerHTML = '<div class="solo-notice">No files loaded. Click <strong>Load JSON</strong> to begin.</div>';
    return;
  }
  if (hosts.length === 1) {
    const h0 = hosts[0];
    const m  = state.hosts[h0].manifest || {};
    const errCount = (m.collection_errors||[]).length;
    const errBadge = errCount > 0 ? ` <span style="color:var(--amber)">${errCount} errors</span>` : ' <span style="color:var(--green)">0 errors</span>';
    panel.innerHTML = `<div class="solo-notice">
      Single host loaded: <strong>${esc(h0)}</strong> &nbsp;|&nbsp;
      ${esc(m.target_os_caption||'')} &nbsp;|&nbsp; PS ${esc(m.target_ps_version||'?')} &nbsp;|&nbsp;
      ${esc(m.collection_time_utc||'')} &nbsp;|&nbsp;${errBadge}
      <br><br>Switch to <a onclick="switchTab('processes')">PROCESSES</a>, <a onclick="switchTab('network')">NETWORK</a>, or <a onclick="switchTab('dns')">DNS</a> to investigate.
    </div>
    <div id="manifest-panel"></div>`;
    renderManifestPanel(h0);
    return;
  }

  const COLS = '180px 200px 60px 50px 110px 80px 100px 100px 80px 60px 120px';
  const headers = [
    { key:'hostname',           label:'Hostname'         },
    { key:'target_os_caption',  label:'OS'               },
    { key:'target_ps_version',  label:'PS'               },
    { key:'nic_count',          label:'NICs'             },
    { key:'network_source',     label:'Net Method'       },
    { key:'proc_count',         label:'Processes'        },
    { key:'active_count',       label:'Active Conns'     },
    { key:'unique_ips',         label:'Remote IPs'       },
    { key:'dns_count',          label:'DNS'              },
    { key:'errors_count',       label:'Errors'           },
    { key:'collection_time_utc',label:'Collected (UTC)'  },
  ];

  function buildRows() {
    const rows = hosts.map(h => {
      const d  = state.hosts[h];
      const m  = d.manifest || {};
      const ac = (d.network_tcp||[]).filter(c=>c.State==='ESTABLISHED').length;
      const ips = new Set((d.network_tcp||[]).filter(c=>c.RemoteAddress&&c.RemoteAddress!=='0.0.0.0').map(c=>c.RemoteAddress));
      const collection_errors = m.collection_errors || [];
      const adapters = m.network_adapters || [];
      return {
        hostname:            h,
        target_os_caption:   m.target_os_caption  || '',
        target_ps_version:   m.target_ps_version  || '',
        nic_count:           adapters.length,
        _adapter_names:      adapters.map(a => a.InterfaceAlias || a.AdapterName || '').filter(Boolean),
        network_source:      m.Network_source ? (m.Network_source.network || JSON.stringify(m.Network_source)) : (m.network_source || ''),
        proc_count:          (d.processes||[]).length,
        active_count:        ac,
        unique_ips:          ips.size,
        dns_count:           (d.dns_cache||[]).length,
        errors_count:        collection_errors.length,
        collection_time_utc: m.collection_time_utc || '',
      };
    });
    if (sortState.tab === 'fleet' && sortState.column && sortState.dir !== 'none') {
      const numericFleetCols = new Set(['nic_count','proc_count','active_count','unique_ips','dns_count','errors_count']);
      rows = applySortToRows(rows, sortState.column, numericFleetCols.has(sortState.column));
    } else {
      rows.sort((a,b) => {
        const av = a[fleetSort.col]; const bv = b[fleetSort.col];
        if (typeof av === 'number') return (av - bv) * fleetSort.dir;
        return String(av).localeCompare(String(bv)) * fleetSort.dir;
      });
    }
    return rows;
  }

  function headerHTML() {
    return headers.map(h => {
      const numeric = /count$|_count$|ps_version$/.test(h.key);
      const arrow = (sortState.tab === 'fleet' && sortState.column === h.key)
        ? (sortState.dir === 'asc' ? '↑' : sortState.dir === 'desc' ? '↓' : '⇅') : '⇅';
      const arrowCls = (sortState.tab === 'fleet' && sortState.column === h.key && sortState.dir !== 'none')
        ? ' class="sort-arrow ' + sortState.dir + '"' : ' class="sort-arrow"';
      return `<div class="th sortable-th" onclick="sortTable('fleet','${h.key}',${numeric})">${esc(h.label)} <span id="sort-fleet-${h.key}"${arrowCls}>${arrow}</span></div>`;
    }).join('');
  }

  panel.innerHTML = `
    <div id="fleet-table" class="tbl-wrap">
      <div class="tbl-header" style="grid-template-columns:${COLS}" id="fleet-header"></div>
      <div id="fleet-vs"></div>
    </div>
    <div id="manifest-panel" style="margin-top:12px"></div>`;

  el('fleet-header').innerHTML = headerHTML();
  setTimeout(() => addResizeHandles('fleet-header', 'fleet'), 0);

  const rows = buildRows();
  state.vsInstances['fleet'] = createVS('fleet-vs', COLS, rows,
    (row) => {
      const nicTip = row._adapter_names.length ? row._adapter_names.join('\n') : '';
      const nicColor = row.nic_count >= 2 ? 'accent' : 'dim';
      return `
      <div class="td">${esc(row.hostname)}</div>
      <div class="td dim">${esc(row.target_os_caption||'')}</div>
      <div class="td">${esc(row.target_ps_version)}</div>
      <div class="td ${nicColor}" title="${esc(nicTip)}">${row.nic_count || ''}</div>
      <div class="td dim">${esc(row.network_source)}</div>
      <div class="td">${row.proc_count}</div>
      <div class="td green">${row.active_count}</div>
      <div class="td">${row.unique_ips}</div>
      <div class="td">${row.dns_count}</div>
      <div class="td ${row.errors_count > 0 ? 'amber' : 'dim'}">${row.errors_count}</div>
      <div class="td dim">${esc(row.collection_time_utc)}</div>`;
    },
    (i, row) => {
      switchHost(row.hostname);
      renderManifestPanel(row.hostname);
    },
    'fleet'
  );
}

function renderManifestPanel(hostname) {
  const mp = el('manifest-panel');
  if (!mp) return;
  const d = state.hosts[hostname];
  if (!d) { mp.innerHTML = ''; return; }
  const m = d.manifest || {};
  const collection_errors = m.collection_errors || [];
  const errHTML = collection_errors.length === 0
    ? '<span style="color:var(--green)">None</span>'
    : collection_errors.map(e => `<div class="mp-err-item">[${esc(e.artifact||'?')}] ${esc(e.message||'')}</div>`).join('');

  const adapters = m.network_adapters || [];
  let adapterTableHTML = '';
  if (adapters.length > 0) {
    const rows = adapters.map((a, i) => {
      const ips  = Array.isArray(a.IPAddresses) ? a.IPAddresses.join(', ') : (a.IPAddresses || '');
      const dns  = Array.isArray(a.DNSServers)  ? a.DNSServers.join(', ')  : (a.DNSServers  || '');
      return `<tr>
        <td><strong>${esc(a.InterfaceAlias || a.AdapterName || '')}</strong></td>
        <td class="mono">${esc(ips)}</td>
        <td class="mono">${esc(a.MACAddress || '')}</td>
        <td>${esc(a.DefaultGateway || '')}</td>
        <td>${esc(dns)}</td>
        <td>${a.DHCPEnabled ? 'Yes' : 'No'}</td>
      </tr>`;
    }).join('');
    adapterTableHTML = `<div class="mp-wrap" style="margin-top:8px">
      <div class="mp-title"><span>Network Adapters (${adapters.length})</span></div>
      <div class="mp-body" style="padding:8px 16px">
        <table class="expand-tbl" style="width:100%">
          <tr><th>Adapter Name</th><th>IP Addresses</th><th>MAC</th><th>Gateway</th><th>DNS Servers</th><th>DHCP</th></tr>
          ${rows}
        </table>
      </div>
    </div>`;
  }

  mp.innerHTML = `<div class="mp-wrap">
    <div class="mp-title">
      <span>Manifest &mdash; ${esc(hostname)}</span>
      <span style="color:var(--muted);font-size:10px">analyzer_version: ${esc(ANALYZER_VERSION)}</span>
    </div>
    <div class="mp-body">
      <div class="mp-grid">
        <span class="k">collector_version</span>       <span class="v">${esc(m.collector_version||'')}</span>
        <span class="k">analyzer_version</span>        <span class="v">${esc(ANALYZER_VERSION)}</span>
        <span class="k">target_ps_version</span>       <span class="v">${esc(m.target_ps_version||'')}</span>
        <span class="k">target_os_version</span>       <span class="v">${esc(m.target_os_version||'')} (${esc(m.target_os_caption||'')})</span>
        <span class="k">target_timezone_offset_minutes</span><span class="v">${m.target_timezone_offset_minutes != null ? m.target_timezone_offset_minutes : ''}</span>
        <span class="k">Network_source</span>          <span class="v">${esc(m.Network_source ? (m.Network_source.network || JSON.stringify(m.Network_source)) : (m.network_source || ''))}</span>
        <span class="k">dns_source</span>              <span class="v">${esc(m.Network_source ? (m.Network_source.dns || '') : (m.dns_source || ''))}</span>
        <span class="k">collection_time_utc</span>     <span class="v">${esc(m.collection_time_utc||'')}</span>
        <span class="k">sha256</span>                  <span class="v" style="font-size:10px;color:var(--muted)">${esc(m.sha256||'')}</span>
      </div>
      <div class="mp-errors" style="margin-top:8px">
        <span class="k">collection_errors (${collection_errors.length})</span>
        <div style="margin-top:4px">${errHTML}</div>
      </div>
    </div>
  </div>
  ${adapterTableHTML}`;
}

function fleetSortBy(col) {
  if (fleetSort.col === col) { fleetSort.dir *= -1; } else { fleetSort.col = col; fleetSort.dir = 1; }
  renderFleet();
}

