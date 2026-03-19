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
var _bulkSel = {};          // { hostname: { sel, mem, disk } }
var _detectedMemTool  = '';
var _detectedDiskTool = '';

(function _detectTools() {
  var base     = 'C:\\DFIRLab\\tools\\';
  var memNames  = ['winpmem.exe', 'DumpIt.exe', 'Magnet.exe', 'RAMMap.exe'];
  var diskNames = ['DumpIt.exe', 'FTK.exe', 'dd.exe', 'dcfldd.exe'];
  // Best-effort: no filesystem access from browser — use first known tool name
  _detectedMemTool  = base + memNames[0];
  _detectedDiskTool = base + diskNames[0];
})();

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
  if (m.winrm_reachable === true)  return { status: 'reachable',   label: 'Reachable',   cls: 'exec-winrm-reach'   };
  if (m.winrm_reachable === false) return { status: 'unreachable', label: 'Unreachable', cls: 'exec-winrm-unreach' };
  // Infer from collection data: null + no errors + processes present → reachable
  var errors = m.collection_errors || [];
  var procCount = (d.Processes && d.Processes.length) ? d.Processes.length : 0;
  if (errors.length === 0 && procCount > 0) return { status: 'reachable', label: 'Reachable', cls: 'exec-winrm-reach' };
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
    // Initialise bulk-selection state for any new hosts
    hosts.forEach(function(h) {
      if (!_bulkSel[h]) _bulkSel[h] = { sel: false, mem: false, disk: false };
    });
    var rows = hosts.map(function(h) {
      var d  = state.hosts[h];
      var m  = (d && d.manifest) || {};
      var cs = _getCollectionStatus(h);
      var ws = _getWinRMStatus(h);
      var bs = _bulkSel[h];
      var winrmNotice = (ws.status === 'unreachable')
        ? '<div class="exec-winrm-notice">WinRM unreachable during collection. Execution may still be possible with different credentials or method.</div>'
        : (ws.status === 'unknown' ? '<div class="exec-winrm-notice">WinRM status unknown.</div>' : '');
      var rowCls = bs.sel ? ' class="exec-sel-row"' : '';
      return '<tr' + rowCls + ' id="exec-row-' + esc(h) + '">' +
        '<td class="exec-cb-col"><input type="checkbox" id="exc-sel-' + esc(h) + '"' + (bs.sel ? ' checked' : '') + ' onchange="execBulkHostCheck(\'' + esc(h) + '\')"></td>' +
        '<td><strong>' + esc(h) + '</strong></td>' +
        '<td class="dim">' + esc(m.target_os_caption || '') + '</td>' +
        '<td class="' + cs.cls + '">' + esc(cs.label) + '</td>' +
        '<td><span class="' + ws.cls + '">' + esc(ws.label) + '</span>' + winrmNotice + '</td>' +
        '<td class="exec-type-col"><input type="checkbox" id="exc-mem-' + esc(h) + '"' + (bs.mem ? ' checked' : '') + ' onchange="execBulkMemCheck(\'' + esc(h) + '\')"></td>' +
        '<td class="exec-type-col"><input type="checkbox" id="exc-dsk-' + esc(h) + '"' + (bs.disk ? ' checked' : '') + ' onchange="execBulkDiskCheck(\'' + esc(h) + '\')"></td>' +
        '</tr>';
    }).join('');
    sec1HTML = '<table class="exec-host-tbl">' +
      '<thead><tr>' +
        '<th class="exec-cb-col"><input type="checkbox" id="exc-sel-all" onchange="execBulkSelectAll(this)" title="Select all"></th>' +
        '<th>Hostname</th><th>OS</th><th>Collection Status</th><th>WinRM</th>' +
        '<th class="exec-type-col exec-th-toggle" onclick="execBulkToggleMem()" title="Toggle Memory on selected rows">Memory</th>' +
        '<th class="exec-type-col exec-th-toggle" onclick="execBulkToggleDisk()" title="Toggle Disk on selected rows">Disk</th>' +
      '</tr></thead>' +
      '<tbody>' + rows + '</tbody>' +
      '</table>' +
      '<div class="exec-bulk-bar">' +
        '<div class="exec-bulk-left">' +
          '<span id="exec-sel-counter" class="exec-sel-counter" style="display:none"></span>' +
        '</div>' +
        '<button class="exec-add-queue-btn" id="exec-add-queue-btn" onclick="execBulkAddToQueue()" disabled>Add to Queue &#8594;</button>' +
      '</div>';
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
            '<div class="exec-cmd-note">Run this command from the Quicker folder</div>' +
            '<button class="exec-copy-btn" onclick="execTabCopyCmd()" style="margin-top:6px">Copy to Clipboard</button>' +
          '</div>' +
        '</div>' +
      '</div>' +
    '</div>';

  // Set initial remote dest for default tool type (Memory)
  var rdEl = el('et-remote-dest');
  if (rdEl) rdEl.value = _execTabToolDefaults['Memory'];
  _execTabRemoteDestModified = false;
  _execEnsureQueueModal();
  _execUpdateSelCounter();
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
  // Strip any surrounding quotes before re-quoting paths
  function sq(v) { return v.replace(/^["']|["']$/g, ''); }
  return '.\\Executor.ps1 `\n  -Target "' + sq(host) + '" `\n  -LocalBinaryPath "' + sq(lbin) + '" `\n  -RemoteDestPath "' + sq(rdest) + '" `\n  -Arguments "' + sq(args) + '" `\n  -Method ' + method + ' `\n  -AliveCheck ' + alive + ' `\n  -Credential (Get-Credential)';
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

// ── BULK SELECTION HANDLERS ───────────────────────────────────────────────────

function execBulkSelectAll(cb) {
  var checked = cb.checked;
  Object.keys(_bulkSel).forEach(function(h) {
    _bulkSel[h].sel = checked;
    var rowCb = el('exc-sel-' + h);
    if (rowCb) rowCb.checked = checked;
    var row = el('exec-row-' + h);
    if (row) {
      if (checked) row.classList.add('exec-sel-row');
      else row.classList.remove('exec-sel-row');
    }
  });
  _execUpdateSelCounter();
}

function execBulkHostCheck(hostname) {
  var cb = el('exc-sel-' + hostname);
  if (!cb || !_bulkSel[hostname]) return;
  _bulkSel[hostname].sel = cb.checked;
  var row = el('exec-row-' + hostname);
  if (row) {
    if (cb.checked) row.classList.add('exec-sel-row');
    else row.classList.remove('exec-sel-row');
  }
  _execUpdateSelCounter();
}

function execBulkMemCheck(hostname) {
  var cb = el('exc-mem-' + hostname);
  if (!cb || !_bulkSel[hostname]) return;
  _bulkSel[hostname].mem = cb.checked;
  _execUpdateSelCounter();
}

function execBulkDiskCheck(hostname) {
  var cb = el('exc-dsk-' + hostname);
  if (!cb || !_bulkSel[hostname]) return;
  _bulkSel[hostname].disk = cb.checked;
  _execUpdateSelCounter();
}

function execBulkToggleMem() {
  var selected = Object.keys(_bulkSel).filter(function(h) { return _bulkSel[h].sel; });
  if (selected.length === 0) return;
  var allOn = selected.every(function(h) { return _bulkSel[h].mem; });
  selected.forEach(function(h) {
    _bulkSel[h].mem = !allOn;
    var cb = el('exc-mem-' + h);
    if (cb) cb.checked = !allOn;
  });
  _execUpdateSelCounter();
}

function execBulkToggleDisk() {
  var selected = Object.keys(_bulkSel).filter(function(h) { return _bulkSel[h].sel; });
  if (selected.length === 0) return;
  var allOn = selected.every(function(h) { return _bulkSel[h].disk; });
  selected.forEach(function(h) {
    _bulkSel[h].disk = !allOn;
    var cb = el('exc-dsk-' + h);
    if (cb) cb.checked = !allOn;
  });
  _execUpdateSelCounter();
}

function _execUpdateSelCounter() {
  var selHosts = 0, memJobs = 0, diskJobs = 0;
  Object.keys(_bulkSel).forEach(function(h) {
    var bs = _bulkSel[h];
    if (bs.sel) {
      selHosts++;
      if (bs.mem) memJobs++;
      if (bs.disk) diskJobs++;
    }
  });
  var counter = el('exec-sel-counter');
  if (counter) {
    if (selHosts > 0) {
      counter.style.display = '';
      counter.textContent = selHosts + ' host' + (selHosts === 1 ? '' : 's') + ' selected \u2014 ' +
        memJobs + ' memory job' + (memJobs === 1 ? '' : 's') + ', ' +
        diskJobs + ' disk job' + (diskJobs === 1 ? '' : 's');
    } else {
      counter.style.display = 'none';
    }
  }
  var qBtn = el('exec-add-queue-btn');
  if (qBtn) qBtn.disabled = (memJobs + diskJobs === 0);
  // Update Select All indeterminate state
  var selAll = el('exc-sel-all');
  if (selAll) {
    var hosts = Object.keys(_bulkSel);
    var nSel = hosts.filter(function(h) { return _bulkSel[h].sel; }).length;
    if (nSel === 0) {
      selAll.checked = false; selAll.indeterminate = false;
    } else if (nSel === hosts.length) {
      selAll.checked = true;  selAll.indeterminate = false;
    } else {
      selAll.checked = false; selAll.indeterminate = true;
    }
  }
}

// ── QUEUE PREVIEW MODAL ───────────────────────────────────────────────────────

function _execEnsureQueueModal() {
  if (document.getElementById('queue-modal')) return;
  var backdrop = document.createElement('div');
  backdrop.id = 'queue-modal-backdrop';
  backdrop.addEventListener('click', function(e) {
    if (e.target === backdrop) _closeQueueModal();
  });
  document.body.appendChild(backdrop);
  var modal = document.createElement('div');
  modal.id = 'queue-modal';
  modal.innerHTML =
    '<div class="qm-header">' +
      '<span class="qm-title" id="qm-title">Queue Preview</span>' +
      '<button class="qm-close" onclick="_closeQueueModal()">\u00d7</button>' +
    '</div>' +
    '<div class="qm-body" id="qm-body"></div>' +
    '<div class="qm-actions" id="qm-actions"></div>';
  document.body.appendChild(modal);
}

function execBulkAddToQueue() {
  _execEnsureQueueModal();
  var jobs = [];
  Object.keys(_bulkSel).sort().forEach(function(h) {
    var bs = _bulkSel[h];
    if (!bs.sel) return;
    if (bs.mem)  jobs.push({ target: h, tool: 'memory' });
    if (bs.disk) jobs.push({ target: h, tool: 'disk'   });
  });
  if (jobs.length === 0) return;
  var hasMemJobs  = jobs.some(function(j) { return j.tool === 'memory'; });
  var hasDiskJobs = jobs.some(function(j) { return j.tool === 'disk';   });
  // Title
  var titleEl = el('qm-title');
  if (titleEl) titleEl.textContent = 'Queue Preview \u2014 ' + jobs.length + ' job' + (jobs.length === 1 ? '' : 's');
  // Job list rows
  var jobRows = jobs.map(function(j) {
    return '<tr>' +
      '<td>' + esc(j.target) + '</td>' +
      '<td>' + (j.tool === 'memory' ? 'Memory' : 'Disk') + '</td>' +
      '<td style="color:var(--green)">Ready</td>' +
      '</tr>';
  }).join('');
  var memField = hasMemJobs
    ? '<div class="qm-field"><label>Memory Binary</label>' +
      '<input type="text" id="qm-mem-bin" value="' + esc(_detectedMemTool) + '" placeholder="C:\\DFIRLab\\tools\\winpmem.exe"></div>'
    : '';
  var diskField = hasDiskJobs
    ? '<div class="qm-field"><label>Disk Binary</label>' +
      '<input type="text" id="qm-disk-bin" value="' + esc(_detectedDiskTool) + '" placeholder="C:\\DFIRLab\\tools\\DumpIt.exe"></div>'
    : '';
  var firstBinName = hasMemJobs
    ? _detectedMemTool.split('\\').pop()
    : _detectedDiskTool.split('\\').pop();
  var remoteDestDefault = 'C:\\Windows\\Temp\\' + (firstBinName || 'tool.exe');
  var body = el('qm-body');
  if (body) body.innerHTML =
    '<div class="qm-job-list">' +
      '<table class="qm-job-tbl">' +
        '<thead><tr><th>Host</th><th>Collection Type</th><th>Status</th></tr></thead>' +
        '<tbody>' + jobRows + '</tbody>' +
      '</table>' +
    '</div>' +
    '<div class="qm-section-title">Shared Settings</div>' +
    memField + diskField +
    '<div class="qm-field"><label>Remote Destination</label>' +
      '<input type="text" id="qm-remote-dest" value="' + esc(remoteDestDefault) + '" placeholder="C:\\Windows\\Temp\\tool.exe"></div>' +
    '<div class="qm-field"><label>Arguments</label>' +
      '<input type="text" id="qm-args" placeholder="optional arguments"></div>' +
    '<div class="qm-field"><label>Method</label>' +
      '<select id="qm-method"><option value="Auto">Auto</option><option value="WinRM">WinRM</option><option value="WMI">WMI</option></select></div>' +
    '<div class="qm-field"><label>Alive Check (s)</label>' +
      '<input type="number" id="qm-alive" value="10" min="1" max="3600" style="width:80px"></div>';
  var actions = el('qm-actions');
  if (actions) actions.innerHTML =
    '<button onclick="_closeQueueModal()">Cancel</button>' +
    '<button class="qm-btn-launch" onclick="_queueModalLaunch()">Launch All &#8594;</button>';
  window._queueJobs = jobs;
  var bk = el('queue-modal-backdrop');
  var md = el('queue-modal');
  if (bk) bk.classList.add('show');
  if (md) md.classList.add('show');
}

function _closeQueueModal() {
  var bk = el('queue-modal-backdrop');
  var md = el('queue-modal');
  if (bk) bk.classList.remove('show');
  if (md) md.classList.remove('show');
}

function _queueModalLaunch() {
  var jobs      = window._queueJobs || [];
  var memBin    = (el('qm-mem-bin')      || {}).value || '';
  var diskBin   = (el('qm-disk-bin')     || {}).value || '';
  var remoteDest= (el('qm-remote-dest')  || {}).value || '';
  var args      = (el('qm-args')         || {}).value || '';
  var method    = (el('qm-method')       || {}).value || 'Auto';
  var alive     = parseInt((el('qm-alive') || {}).value || '10', 10) || 10;
  var payload = jobs.map(function(j) {
    return {
      target:     j.target,
      tool:       j.tool,
      binary:     j.tool === 'memory' ? memBin : diskBin,
      remoteDest: remoteDest,
      arguments:  args,
      method:     method,
      aliveCheck: alive
    };
  });
  var encoded = encodeURIComponent(btoa(JSON.stringify(payload)));
  var uri = 'quicker://batch?jobs=' + encoded;
  console.log('[Quicker] Batch URI:', uri);
  window.location.href = uri;
  // Show success
  var body = el('qm-body');
  if (body) {
    var ok = document.createElement('div');
    ok.className = 'qm-success';
    ok.innerHTML = '<strong>Jobs sent to Quicker Launcher</strong><br>QuickerLaunch.ps1 should open shortly.';
    body.insertBefore(ok, body.firstChild);
  }
  var actions = el('qm-actions');
  if (actions) actions.innerHTML = '<button onclick="_closeQueueModal()">Close</button>';
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
