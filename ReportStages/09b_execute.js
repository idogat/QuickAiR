// ── EXECUTE TAB ───────────────────────────────────────────────────────────────
(function injectExecuteCSS() {
  var s = document.createElement('style');
  s.textContent = [
    '#panel-execute{padding:12px 16px}',
    '.exec-section{margin-bottom:24px}',
    '.exec-section-title{font-size:13px;font-weight:bold;color:var(--accent);margin:0 0 8px 0;padding-bottom:6px;border-bottom:1px solid var(--border)}',
    '.exec-host-tbl{width:100%;border-collapse:collapse;font-size:12px}',
    '.exec-host-tbl th{text-align:left;padding:4px 10px;color:var(--muted);font-weight:normal;border-bottom:1px solid var(--border)}',
    '.exec-host-tbl td{padding:5px 10px;border-bottom:1px solid var(--border);vertical-align:top}',
    '.exec-host-tbl tr:hover td{background:var(--row-hov)}',
    '.exec-status-complete{color:var(--green);font-weight:bold}',
    '.exec-status-partial{color:var(--amber);font-weight:bold}',
    '.exec-status-failed{color:var(--red);font-weight:bold}',
    '.exec-status-nodata{color:var(--muted)}',
    '.exec-winrm-reach{color:var(--green)}',
    '.exec-winrm-unreach{color:var(--red)}',
    '.exec-winrm-unknown{color:var(--muted)}',
    '.exec-winrm-notice{color:var(--amber);font-size:11px;margin-top:3px}',
    '.exec-host-btn{font-size:11px;padding:2px 8px}',
    '.exec-no-hosts{color:var(--muted);font-style:italic;padding:8px 0}',
    '.exec-launcher{background:var(--surface);border:1px solid var(--border);border-radius:4px;padding:14px 16px;max-width:720px}',
    '.exec-field{display:grid;grid-template-columns:140px 1fr;align-items:center;gap:6px;margin-bottom:10px}',
    '.exec-field label{color:var(--muted);font-size:12px;text-align:right;padding-right:8px}',
    '.exec-field input,.exec-field select{width:100%}',
    '.exec-field-wrap{display:flex;gap:6px;align-items:center}',
    '.exec-field-wrap input{flex:1}',
    '.exec-actions{display:flex;gap:8px;margin-top:12px}',
    '.exec-copy-btn{background:var(--accent);border-color:var(--accent);color:#0d1117}',
    '.exec-copy-btn:hover{opacity:.85}',
    '.exec-host-notice{margin-top:4px;margin-left:148px;font-size:11px}',
    '.exec-host-notice.amber{color:var(--amber)}',
    '.exec-host-notice.red-note{color:var(--red)}',
    '.exec-cmd-outer{margin-top:14px;max-width:720px}',
    '.exec-cmd{background:var(--bg);border:1px solid var(--border);border-radius:4px;padding:12px;font-family:"Consolas","Courier New",monospace;font-size:12px;white-space:pre-wrap;word-break:break-all;user-select:all;cursor:text;color:var(--green);margin-bottom:8px}',
    '.exec-cmd-note{color:var(--muted);font-size:11px;margin-bottom:6px}',
    '.fleet-err-banner{background:rgba(210,140,0,.1);border:1px solid var(--amber);border-radius:4px;padding:7px 12px;margin-bottom:6px;font-size:12px;color:var(--amber);display:flex;align-items:center;gap:10px}',
    '.fleet-err-banner a{color:var(--accent);cursor:pointer;text-decoration:underline;white-space:nowrap}',
    '.tab-badge{display:inline-block;background:var(--amber);color:#0d1117;font-size:10px;font-weight:bold;border-radius:8px;padding:1px 5px;margin-left:4px;vertical-align:middle;line-height:14px}',
    '.tab-badge.red{background:var(--red);color:#fff}'
  ].join('');
  document.head.appendChild(s);
})();

var _execTabRemoteDestModified = false;

var _execTabToolDefaults = {
  Memory: 'C:\\Windows\\Temp\\winpmem.exe',
  Disk:   'C:\\Windows\\Temp\\DumpIt.exe',
  Custom: ''
};

function _getCollectionStatus(hostname) {
  var d = state.hosts[hostname];
  if (!d || !d.manifest) return { status: 'nodata', label: 'No data', cls: 'exec-status-nodata' };
  var m = d.manifest;
  var errors = m.collection_errors || [];
  if (m.collection_failed === true) return { status: 'failed', label: 'Failed', cls: 'exec-status-failed' };
  if (errors.length > 0) return { status: 'partial', label: 'Partial (' + errors.length + ' errors)', cls: 'exec-status-partial' };
  return { status: 'complete', label: 'Complete', cls: 'exec-status-complete' };
}

function _getWinRMStatus(hostname) {
  var d = state.hosts[hostname];
  if (!d || !d.manifest) return { status: 'unknown', label: 'Unknown', cls: 'exec-winrm-unknown' };
  var m = d.manifest;
  if (m.winrm_available === true)  return { status: 'reachable',   label: 'Reachable',   cls: 'exec-winrm-reach'   };
  if (m.winrm_available === false) return { status: 'unreachable', label: 'Unreachable', cls: 'exec-winrm-unreach' };
  return { status: 'unknown', label: 'Unknown', cls: 'exec-winrm-unknown' };
}

function _getExecuteBadgeInfo() {
  var hosts = Object.keys(state.hosts);
  var partial = 0, failed = 0;
  hosts.forEach(function(h) {
    var cs = _getCollectionStatus(h);
    if (cs.status === 'failed')       failed++;
    else if (cs.status === 'partial') partial++;
  });
  return { count: partial + failed, failed: failed, partial: partial };
}

function updateExecuteBadge() {
  var btn = el('tab-execute');
  if (!btn) return;
  var existing = btn.querySelector('.tab-badge');
  if (existing) existing.remove();
  var info = _getExecuteBadgeInfo();
  if (info.count > 0) {
    var badge = document.createElement('span');
    badge.className = 'tab-badge' + (info.failed > 0 ? ' red' : '');
    badge.textContent = info.count;
    btn.appendChild(badge);
  }
}

function renderExecute() {
  var panel = el('panel-execute');
  if (!panel) return;
  var hosts = Object.keys(state.hosts);

  // ── Section 1: Host Status ────────────────────────────────────────────────
  var sec1HTML;
  if (hosts.length === 0) {
    sec1HTML = '<div class="exec-no-hosts">Load a JSON file to see host status. You can still use the manual launcher below.</div>';
  } else {
    var rows = hosts.map(function(h) {
      var d  = state.hosts[h];
      var m  = (d && d.manifest) || {};
      var cs = _getCollectionStatus(h);
      var ws = _getWinRMStatus(h);
      var winrmNotice = (ws.status === 'unreachable' || ws.status === 'unknown')
        ? '<div class="exec-winrm-notice">WinRM unavailable during collection. Execution may still be possible with different credentials or method.</div>'
        : '';
      return '<tr>' +
        '<td><strong>' + esc(h) + '</strong></td>' +
        '<td class="dim">' + esc(m.target_os_caption || '') + '</td>' +
        '<td class="' + cs.cls + '">' + esc(cs.label) + '</td>' +
        '<td><span class="' + ws.cls + '">' + esc(ws.label) + '</span>' + winrmNotice + '</td>' +
        '<td><button class="exec-host-btn" onclick="execTabCollectFromRow(\'' + esc(h) + '\',\'Memory\')">Collect Memory</button></td>' +
        '<td><button class="exec-host-btn" onclick="execTabCollectFromRow(\'' + esc(h) + '\',\'Disk\')">Collect Disk</button></td>' +
        '</tr>';
    }).join('');
    sec1HTML = '<table class="exec-host-tbl">' +
      '<thead><tr><th>Hostname</th><th>OS</th><th>Collection Status</th><th>WinRM</th><th>Memory</th><th>Disk</th></tr></thead>' +
      '<tbody>' + rows + '</tbody>' +
      '</table>';
  }

  // ── Section 2: Launcher ───────────────────────────────────────────────────
  var hostOpts = hosts.map(function(h) {
    return '<option value="' + esc(h) + '">' + esc(h) + '</option>';
  }).join('');
  var hostDropdown = hosts.length > 0
    ? '<select id="et-host-select" onchange="execTabHostDropdownChange()" style="width:200px">' +
      '<option value="">-- Select loaded host --</option>' + hostOpts + '</select>'
    : '';

  panel.innerHTML =
    '<div class="exec-section">' +
      '<div class="exec-section-title">&#9654; Host Status</div>' +
      '<div id="exec-host-status-wrap">' + sec1HTML + '</div>' +
    '</div>' +
    '<div class="exec-section" id="exec-launcher-section">' +
      '<div class="exec-section-title">&#9654; Launcher</div>' +
      '<div class="exec-launcher">' +
        '<div class="exec-field">' +
          '<label>Target Host</label>' +
          '<div class="exec-field-wrap">' +
            '<input type="text" id="et-host" placeholder="hostname or IP">' +
            hostDropdown +
          '</div>' +
        '</div>' +
        '<div id="et-host-notice"></div>' +
        '<div class="exec-field">' +
          '<label>Tool Type</label>' +
          '<select id="et-tool-type" onchange="execTabToolTypeChange()">' +
            '<option value="Memory">Memory</option>' +
            '<option value="Disk">Disk</option>' +
            '<option value="Custom">Custom</option>' +
          '</select>' +
        '</div>' +
        '<div class="exec-field">' +
          '<label>Local Binary</label>' +
          '<input type="text" id="et-local-bin" placeholder="C:\\Tools\\winpmem.exe">' +
        '</div>' +
        '<div class="exec-field">' +
          '<label>Remote Dest</label>' +
          '<input type="text" id="et-remote-dest" placeholder="C:\\Windows\\Temp\\winpmem.exe" oninput="_execTabRemoteDestModified=true">' +
        '</div>' +
        '<div class="exec-field">' +
          '<label>Arguments</label>' +
          '<input type="text" id="et-args" placeholder="-o C:\\Windows\\Temp\\mem.raw">' +
        '</div>' +
        '<div class="exec-field">' +
          '<label>Method</label>' +
          '<select id="et-method">' +
            '<option value="Auto">Auto</option>' +
            '<option value="WinRM">WinRM</option>' +
            '<option value="WMI">WMI</option>' +
          '</select>' +
        '</div>' +
        '<div class="exec-field">' +
          '<label>Alive Check (s)</label>' +
          '<input type="number" id="et-alive" value="10" min="1" max="3600" style="width:80px">' +
        '</div>' +
        '<div class="exec-actions">' +
          '<button class="exec-copy-btn" id="et-copy-btn" onclick="execTabCopy()">Copy Command</button>' +
          '<button onclick="execTabLaunch()">Launch &#8594;</button>' +
        '</div>' +
        '<div id="et-cmd-wrap" style="display:none">' +
          '<div class="exec-cmd-outer">' +
            '<div class="exec-cmd-note">Copy and paste into PowerShell:</div>' +
            '<div class="exec-cmd" id="et-cmd-display" title="Click to select all" onclick="window.getSelection().selectAllChildren(this)"></div>' +
            '<div class="exec-cmd-note" style="color:var(--amber)">&#9432; Executor.ps1 must be in same folder as Collector.ps1</div>' +
            '<button class="exec-copy-btn" onclick="execTabCopyCmd()" style="margin-top:6px">Copy to Clipboard</button>' +
          '</div>' +
        '</div>' +
      '</div>' +
    '</div>';

  // Set initial remote dest for default tool type (Memory)
  var rdEl = el('et-remote-dest');
  if (rdEl) rdEl.value = _execTabToolDefaults['Memory'];
  _execTabRemoteDestModified = false;
}

function execTabToolTypeChange() {
  if (_execTabRemoteDestModified) return;
  var tt = el('et-tool-type');
  var rd = el('et-remote-dest');
  if (tt && rd) rd.value = _execTabToolDefaults[tt.value] || '';
}

function execTabHostDropdownChange() {
  var sel = el('et-host-select');
  if (!sel) return;
  var h = sel.value;
  var hostEl = el('et-host');
  if (hostEl) hostEl.value = h;
  _updateExecHostNotice(h);
}

function _updateExecHostNotice(hostname) {
  var notice = el('et-host-notice');
  if (!notice) return;
  if (!hostname || !state.hosts[hostname]) { notice.innerHTML = ''; return; }
  var cs = _getCollectionStatus(hostname);
  var ws = _getWinRMStatus(hostname);
  var html = '';
  if (cs.status === 'partial' || cs.status === 'failed') {
    html += '<div class="exec-host-notice amber">&#9888; Collection was ' + esc(cs.label.toLowerCase()) + ' on this host.</div>';
  }
  if (ws.status === 'unreachable') {
    html += '<div class="exec-host-notice red-note">WinRM was unreachable during collection. Try WMI method or verify credentials.</div>';
  }
  notice.innerHTML = html;
}

function _buildExecTabCommand() {
  var host   = (el('et-host')        || {}).value || '';
  var lbin   = (el('et-local-bin')   || {}).value || '';
  var rdest  = (el('et-remote-dest') || {}).value || '';
  var args   = (el('et-args')        || {}).value || '';
  var method = (el('et-method')      || {}).value || 'Auto';
  var alive  = (el('et-alive')       || {}).value || '10';
  return '.\\Executor.ps1 `\n  -Target "' + host + '" `\n  -LocalBinaryPath "' + lbin + '" `\n  -RemoteDestPath "' + rdest + '" `\n  -Arguments "' + args + '" `\n  -Method ' + method + ' `\n  -AliveCheck ' + alive + ' `\n  -Credential (Get-Credential)';
}

function _execTabClipboard(text) {
  if (navigator.clipboard) {
    navigator.clipboard.writeText(text).catch(function() { _execTabClipboardFallback(text); });
  } else {
    _execTabClipboardFallback(text);
  }
}

function _execTabClipboardFallback(text) {
  var ta = document.createElement('textarea');
  ta.value = text;
  document.body.appendChild(ta);
  ta.select();
  document.execCommand('copy');
  document.body.removeChild(ta);
}

function execTabCopy() {
  _execTabClipboard(_buildExecTabCommand());
  var btn = el('et-copy-btn');
  if (btn) {
    btn.textContent = 'Copied!';
    setTimeout(function() { if (btn) btn.textContent = 'Copy Command'; }, 2000);
  }
}

function execTabLaunch() {
  var cmd  = _buildExecTabCommand();
  var wrap = el('et-cmd-wrap');
  var disp = el('et-cmd-display');
  if (disp) disp.textContent = cmd;
  if (wrap) wrap.style.display = '';
}

function execTabCopyCmd() {
  _execTabClipboard(_buildExecTabCommand());
}

function execTabCollectFromRow(hostname, toolType) {
  var hostEl = el('et-host');
  var ttEl   = el('et-tool-type');
  var rdEl   = el('et-remote-dest');
  var lbEl   = el('et-local-bin');
  var selEl  = el('et-host-select');
  if (hostEl) hostEl.value = hostname;
  if (selEl)  { selEl.value = hostname; }
  if (ttEl)   ttEl.value   = toolType;
  _execTabRemoteDestModified = false;
  if (rdEl)   rdEl.value   = _execTabToolDefaults[toolType] || '';
  _updateExecHostNotice(hostname);
  var launcher = el('exec-launcher-section');
  if (launcher) launcher.scrollIntoView({ behavior: 'smooth', block: 'start' });
  setTimeout(function() { if (lbEl) lbEl.focus(); }, 300);
}

function renderFleetExecBanners() {
  var wrap = el('fleet-exec-banners');
  if (!wrap) return;
  var hosts = Object.keys(state.hosts);
  var banners = hosts.filter(function(h) {
    var cs = _getCollectionStatus(h);
    return cs.status === 'partial' || cs.status === 'failed';
  }).map(function(h) {
    var cs  = _getCollectionStatus(h);
    var cnt = (((state.hosts[h] || {}).manifest || {}).collection_errors || []).length;
    return '<div class="fleet-err-banner">' +
      '&#9888; <strong>' + esc(h) + '</strong> &mdash; collection ' + (cs.status === 'failed' ? 'failed' : 'incomplete') + '.' +
      (cnt > 0 ? ' ' + cnt + ' error' + (cnt === 1 ? '' : 's') + ' recorded.' : '') +
      ' Use the EXECUTE tab to run memory or disk collection directly.' +
      ' &nbsp;<a onclick="switchTab(\'execute\')">Go to Execute tab</a>' +
      '</div>';
  }).join('');
  wrap.innerHTML = banners;
}
