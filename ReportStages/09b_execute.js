// ── EXECUTE TAB ─────────────────────────────────────────────── v1.2 (per-row)─
(function injectExecuteCSS() {
  var s = document.createElement('style');
  s.textContent = [
    '#panel-execute{padding:12px 16px}',
    '.exec-section{margin-bottom:24px}',
    '.exec-section-hdr{font-size:13px;font-weight:bold;color:var(--fg);margin:0 0 0 0;padding:6px 0;border-bottom:1px solid var(--border);cursor:pointer;user-select:none;display:flex;align-items:center;gap:6px}',
    '.exec-section-hdr:hover{color:var(--accent)}',
    '.exec-sec-arrow{color:var(--accent);font-size:11px;width:10px;display:inline-block}',
    '.exec-section-body{overflow:hidden;transition:max-height 0.3s ease;max-height:4000px;padding-top:8px}',
    '.exec-section-body.collapsed{max-height:0;padding-top:0}',
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
    '.tab-badge.red{background:var(--red);color:#fff}',
    '.qm-bin-wrap{display:flex;flex-direction:column;gap:4px}',
    '.exec-setup-banner{background:rgba(100,120,150,.08);border:1px solid var(--border);border-radius:4px;padding:7px 14px;margin-bottom:10px;font-size:12px;color:var(--muted);display:flex;align-items:center;gap:8px}'
  ].join('');
  document.head.appendChild(s);
})();

var _execTabRemoteDestModified = false;
var _bulkSel = {};          // { hostname: { mem, disk } }
var _toolsManifest       = null;   // cached tools.json data
var _toolsManifestLoaded = false;  // true once fetch attempt completed
var _qmRemoteDestModified = false; // legacy — kept for _execTabRemoteDestModified compat

function _loadToolsManifest(callback) {
  if (!_toolsManifestLoaded) {
    _toolsManifest = (typeof _embeddedToolsManifest !== 'undefined') ? _embeddedToolsManifest : null;
    _toolsManifestLoaded = true;
  }
  callback(_toolsManifest);
}

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
      if (!_bulkSel[h]) _bulkSel[h] = { mem: false, disk: false };
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
      return '<tr id="exec-row-' + esc(h) + '">' +
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
    '<div id="exec-setup-banner" style="display:none" class="exec-setup-banner">&#8505; To use launcher: run <strong>Register-QuickerProtocol.ps1</strong> once as Administrator.</div>' +
    '<div class="exec-section">' +
      '<div class="exec-section-hdr" onclick="execToggleSection(\'exec-sec1-body\')">' +
        '<span class="exec-sec-arrow" id="exec-sec1-arrow">&#9660;</span>Select Hosts' +
      '</div>' +
      '<div class="exec-section-body" id="exec-sec1-body">' + sec1HTML + '</div>' +
    '</div>' +
    '<div class="exec-section" id="exec-launcher-section">' +
      '<div class="exec-section-hdr" onclick="execToggleSection(\'exec-sec2-body\')">' +
        '<span class="exec-sec-arrow" id="exec-sec2-arrow">&#9660;</span>Launch with Command' +
      '</div>' +
      '<div class="exec-section-body" id="exec-sec2-body"><div class="exec-launcher">' +
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
            '<option value="SMB+WMI">SMB+WMI</option>' +
            '<option value="WMI">WMI</option>' +
          '</select>' +
        '</div>' +
        '<div class="exec-field">' +
          '<label>SMB Share</label>' +
          '<input type="text" id="et-smb-share" placeholder="optional — default: \\\\target\\C$">' +
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
      '</div>' +   // close exec-launcher
      '</div>' +   // close exec-section-body
    '</div>';

  // Set initial remote dest for default tool type (Memory)
  var rdEl = el('et-remote-dest');
  if (rdEl) rdEl.value = _execTabToolDefaults['Memory'];
  _execTabRemoteDestModified = false;
  _execEnsureQueueModal();
  _execUpdateSelCounter();
  _loadToolsManifest(function(manifest) {
    var banner = el('exec-setup-banner');
    if (banner && manifest) banner.style.display = '';
  });
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
    html += '<div class="exec-host-notice red-note">WinRM was unreachable during collection. Try SMB+WMI method or verify credentials.</div>';
  }
  notice.innerHTML = html;
}

function _buildExecTabCommand() {
  var host   = (el('et-host')        || {}).value || '';
  var lbin   = (el('et-local-bin')   || {}).value || '';
  var rdest  = (el('et-remote-dest') || {}).value || '';
  var args   = (el('et-args')        || {}).value || '';
  var method = (el('et-method')      || {}).value || 'Auto';
  var smb    = (el('et-smb-share')   || {}).value || '';
  var alive  = (el('et-alive')       || {}).value || '10';
  // Strip any surrounding quotes before re-quoting paths
  function sq(v) { return v.replace(/^["']|["']$/g, ''); }
  var cmd = '.\\Executor.ps1 `\n  -Target "' + sq(host) + '" `\n  -LocalBinaryPath "' + sq(lbin) + '" `\n  -RemoteDestPath "' + sq(rdest) + '" `\n  -Arguments "' + sq(args) + '" `\n  -Method ' + method;
  if (smb) cmd += ' `\n  -RemoteShare "' + sq(smb) + '"';
  cmd += ' `\n  -AliveCheck ' + alive + ' `\n  -Credential (Get-Credential)';
  return cmd;
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
  var launcher = el('exec-sec2-body');
  if (launcher) {
    // Ensure section is expanded before scrolling
    if (launcher.classList.contains('collapsed')) execToggleSection('exec-sec2-body');
    launcher.scrollIntoView({ behavior: 'smooth', block: 'start' });
  }
  setTimeout(function() { if (lbEl) lbEl.focus(); }, 300);
}

// ── BULK SELECTION HANDLERS ───────────────────────────────────────────────────


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
  var hosts = Object.keys(_bulkSel);
  if (hosts.length === 0) return;
  var allOn = hosts.every(function(h) { return _bulkSel[h].mem; });
  hosts.forEach(function(h) {
    _bulkSel[h].mem = !allOn;
    var cb = el('exc-mem-' + h);
    if (cb) cb.checked = !allOn;
  });
  _execUpdateSelCounter();
}

function execBulkToggleDisk() {
  var hosts = Object.keys(_bulkSel);
  if (hosts.length === 0) return;
  var allOn = hosts.every(function(h) { return _bulkSel[h].disk; });
  hosts.forEach(function(h) {
    _bulkSel[h].disk = !allOn;
    var cb = el('exc-dsk-' + h);
    if (cb) cb.checked = !allOn;
  });
  _execUpdateSelCounter();
}

function _execUpdateSelCounter() {
  var memJobs = 0, diskJobs = 0;
  Object.keys(_bulkSel).forEach(function(h) {
    var bs = _bulkSel[h];
    if (bs.mem)  memJobs++;
    if (bs.disk) diskJobs++;
  });
  var counter = el('exec-sel-counter');
  if (counter) {
    if (memJobs + diskJobs > 0) {
      counter.style.display = '';
      counter.textContent = memJobs + ' memory job' + (memJobs === 1 ? '' : 's') + ', ' +
        diskJobs + ' disk job' + (diskJobs === 1 ? '' : 's');
    } else {
      counter.style.display = 'none';
    }
  }
  var qBtn = el('exec-add-queue-btn');
  if (qBtn) qBtn.disabled = (memJobs + diskJobs === 0);
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
    if (bs.mem)  jobs.push({ target: h, tool: 'memory' });
    if (bs.disk) jobs.push({ target: h, tool: 'disk'   });
  });
  if (jobs.length === 0) return;

  // Title
  var titleEl = el('qm-title');
  if (titleEl) titleEl.textContent = 'Queue Preview \u2014 ' + jobs.length + ' job' + (jobs.length === 1 ? '' : 's');

  // Show modal immediately, body will be filled once manifest loads
  window._queueJobs = jobs;
  _qmRemoteDestModified = false;
  var bk = el('queue-modal-backdrop');
  var md = el('queue-modal');
  if (bk) bk.classList.add('show');
  if (md) md.classList.add('show');

  var body = el('qm-body');
  if (body) body.innerHTML = '<div style="color:var(--muted);padding:8px 0;font-size:12px">Loading tools\u2026</div>';

  var hasMemJobs  = jobs.some(function(j) { return j.tool === 'memory'; });
  var hasDiskJobs = jobs.some(function(j) { return j.tool === 'disk';   });

  _loadToolsManifest(function(manifest) {
    _execBuildQueueModalBody(jobs, hasMemJobs, hasDiskJobs, manifest);
  });
}

// Builds the category display label shown in dropdown options
function _toolCatLabel(cat) {
  var map = { 'memory': 'Memory', 'disk': 'Disk', 'memory+disk': 'Memory+Disk', 'custom': 'Custom' };
  return map[cat] || 'Custom';
}

// Builds a binary field (dropdown or text input) for the given type ('mem' or 'disk')
// preselect: optional path string to pre-select in the dropdown
function _buildBinField(type, label, manifest, preselect) {
  var relevant = [];
  if (manifest && manifest.tools) {
    manifest.tools.forEach(function(t) {
      var cat = t.category || 'custom';
      if (type === 'mem'  && (cat === 'memory' || cat === 'memory+disk' || cat === 'custom')) relevant.push(t);
      if (type === 'disk' && (cat === 'disk'   || cat === 'memory+disk' || cat === 'custom')) relevant.push(t);
    });
  }
  if (relevant.length > 0) {
    var hasPreselect = false;
    if (preselect) {
      var norm = preselect.replace(/\//g, '\\').toLowerCase();
      relevant.forEach(function(t) { if (t.path.toLowerCase() === norm) hasPreselect = true; });
    }
    var opts = hasPreselect ? '' : '<option value="" disabled selected>-- Select tool --</option>';
    opts += relevant.map(function(t) {
      var sel = (hasPreselect && t.path.toLowerCase() === preselect.replace(/\//g, '\\').toLowerCase()) ? ' selected' : '';
      return '<option value="' + esc(t.path) + '"' + sel + '>' + esc(t.filename) + ' (' + _toolCatLabel(t.category) + ')</option>';
    }).join('');
    opts += '<option value="__browse__">Browse\u2026</option>';
    return '<div class="qm-field"><label>' + label + '</label>' +
      '<div class="qm-bin-wrap">' +
        '<select id="qm-' + type + '-bin" onchange="_qmBinChange(\'' + type + '\')">' + opts + '</select>' +
        '<input type="text" id="qm-' + type + '-bin-custom" style="display:none" placeholder="Enter path manually">' +
      '</div>' +
    '</div>';
  }
  // Fallback: plain text input (pre-fill with default if provided)
  var val = preselect ? ' value="' + esc(preselect) + '"' : '';
  return '<div class="qm-field"><label>' + label + '</label>' +
    '<input type="text" id="qm-' + type + '-bin"' + val + ' placeholder="Run Get-ToolsManifest.ps1 to populate tool list"></div>';
}

// Returns the effective binary path for the given type ('mem' or 'disk')
function _qmGetBinValue(type) {
  var sel = el('qm-' + type + '-bin');
  if (!sel) return '';
  if (sel.tagName === 'SELECT') {
    if (sel.value === '__browse__') {
      var custom = el('qm-' + type + '-bin-custom');
      return custom ? custom.value : '';
    }
    return sel.value;
  }
  return sel.value;
}

// Called when a binary dropdown changes — updates remote dest for matching rows
function _qmBinChange(type) {
  var sel    = el('qm-' + type + '-bin');
  var custom = el('qm-' + type + '-bin-custom');
  if (!sel) return;
  if (sel.value === '__browse__') {
    if (custom) { custom.style.display = ''; custom.focus(); }
    return;
  }
  if (custom) custom.style.display = 'none';
  // Update remote dest for all rows of this tool type (unless manually edited)
  var toolMatch = (type === 'mem') ? 'memory' : 'disk';
  var fname = sel.value.split('\\').pop();
  if (!fname) return;
  var jobs = window._queueJobs || [];
  jobs.forEach(function(j, idx) {
    if (j.tool === toolMatch && !_qmRowRdModified[idx]) {
      var rdEl = el('qm-rd-' + idx);
      if (rdEl) rdEl.value = 'C:\\Windows\\Temp\\' + fname;
    }
  });
}

// Per-row tracking: which remote-dest inputs were manually edited
var _qmRowRdModified = {};

function _qmToggleSmb(idx) {
  var meth = (el('qm-method-' + idx) || {}).value;
  var cell = el('qm-smb-cell-' + idx);
  if (cell) cell.style.display = (meth === 'WinRM' || meth === 'WMI') ? 'none' : '';
}

function _qmApplyInitialSmbVisibility(jobs) {
  for (var i = 0; i < jobs.length; i++) _qmToggleSmb(i);
}

function _execBuildQueueModalBody(jobs, hasMemJobs, hasDiskJobs, manifest) {
  var defaults = (typeof _toolDefaults !== 'undefined') ? _toolDefaults : null;
  var memDef  = defaults && defaults.memory ? defaults.memory : null;
  var diskDef = defaults && defaults.disk   ? defaults.disk   : null;
  _qmRowRdModified = {};

  // Binary fields
  var memField = '';
  if (hasMemJobs) {
    var memPreselect = (memDef && memDef.binary) ? memDef.binary : null;
    memField = _buildBinField('mem', 'Memory Binary', manifest, memPreselect);
  }
  var diskField = '';
  if (hasDiskJobs) {
    var diskPreselect = (diskDef && diskDef.binary) ? diskDef.binary : null;
    diskField = _buildBinField('disk', 'Disk Binary', manifest, diskPreselect);
  }

  // Compute per-tool defaults
  var memRdDefault   = (memDef  && memDef.remoteDest)  ? memDef.remoteDest  : 'C:\\Windows\\Temp\\tool.exe';
  var diskRdDefault  = (diskDef && diskDef.remoteDest)  ? diskDef.remoteDest  : 'C:\\Windows\\Temp\\tool.exe';
  var memArgsDefault  = (memDef  && memDef.arguments)  ? memDef.arguments  : '';
  var diskArgsDefault = (diskDef && diskDef.arguments)  ? diskDef.arguments  : '';
  var memMethodDef    = (memDef  && memDef.method)     ? memDef.method     : 'Auto';
  var diskMethodDef   = (diskDef && diskDef.method)     ? diskDef.method     : 'Auto';
  var memAliveDef     = (memDef  && memDef.aliveCheck)  ? memDef.aliveCheck  : 30;
  var diskAliveDef    = (diskDef && diskDef.aliveCheck)  ? diskDef.aliveCheck  : 30;

  // If no defaults, try manifest for remoteDest
  if (!memDef && manifest && manifest.tools) {
    manifest.tools.forEach(function(t) {
      var cat = t.category || 'custom';
      if (memRdDefault === 'C:\\Windows\\Temp\\tool.exe' && (cat === 'memory' || cat === 'memory+disk'))
        memRdDefault = 'C:\\Windows\\Temp\\' + t.filename;
    });
  }
  if (!diskDef && manifest && manifest.tools) {
    manifest.tools.forEach(function(t) {
      var cat = t.category || 'custom';
      if (diskRdDefault === 'C:\\Windows\\Temp\\tool.exe' && (cat === 'disk' || cat === 'memory+disk'))
        diskRdDefault = 'C:\\Windows\\Temp\\' + t.filename;
    });
  }

  // Build per-row editable table
  function methodOpts(selected) {
    return ['Auto', 'WinRM', 'SMB+WMI', 'WMI'].map(function(m) {
      return '<option value="' + m + '"' + (m === selected ? ' selected' : '') + '>' + m + '</option>';
    }).join('');
  }

  var settingsRows = jobs.map(function(j, idx) {
    var isMem = (j.tool === 'memory');
    var rd    = isMem ? memRdDefault   : diskRdDefault;
    var args  = isMem ? memArgsDefault : diskArgsDefault;
    var meth  = isMem ? memMethodDef   : diskMethodDef;
    var alive = isMem ? memAliveDef    : diskAliveDef;
    return '<tr>' +
      '<td class="qm-cell-host">' + esc(j.target) + '</td>' +
      '<td class="qm-cell-type">' + (isMem ? 'Memory' : 'Disk') + '</td>' +
      '<td><input id="qm-rd-' + idx + '" value="' + esc(rd) + '" ' +
        'oninput="_qmRowRdModified[' + idx + ']=true" placeholder="C:\\Windows\\Temp\\tool.exe"></td>' +
      '<td><input id="qm-args-' + idx + '" value="' + esc(args) + '" placeholder="optional"></td>' +
      '<td><select id="qm-method-' + idx + '" onchange="_qmToggleSmb(' + idx + ')">' + methodOpts(meth) + '</select></td>' +
      '<td class="qm-smb-cell" id="qm-smb-cell-' + idx + '"><input id="qm-smb-' + idx + '" value="" placeholder="\\\\target\\ShareName (auto-detect if empty)" style="width:160px"></td>' +
      '<td><input type="number" id="qm-alive-' + idx + '" value="' + alive + '" min="1" max="3600" style="width:60px"></td>' +
      '</tr>';
  }).join('');

  var body = el('qm-body');
  if (body) body.innerHTML =
    '<div class="qm-section-title">Tool Binaries</div>' +
    memField + diskField +
    '<div class="qm-section-title">Job Settings</div>' +
    '<div class="qm-settings-wrap">' +
      '<table class="qm-settings-tbl">' +
        '<thead><tr>' +
          '<th>Host</th><th>Type</th><th>Remote Destination</th>' +
          '<th>Arguments</th><th>Method</th><th>Custom Share</th><th>Alive</th>' +
        '</tr></thead>' +
        '<tbody>' + settingsRows + '</tbody>' +
      '</table>' +
    '</div>';

  var actions = el('qm-actions');
  if (actions) actions.innerHTML =
    '<button onclick="_closeQueueModal()">Cancel</button>' +
    '<button class="qm-btn-launch" onclick="_queueModalLaunch()">Launch All &#8594;</button>';

  // Set initial visibility of Custom Share cells based on method
  _qmApplyInitialSmbVisibility(jobs);
}

function _closeQueueModal() {
  var bk = el('queue-modal-backdrop');
  var md = el('queue-modal');
  if (bk) bk.classList.remove('show');
  if (md) md.classList.remove('show');
}

function _queueModalLaunch() {
  var jobs      = window._queueJobs || [];
  var memBin    = _qmGetBinValue('mem');
  var diskBin   = _qmGetBinValue('disk');
  var payload = jobs.map(function(j, idx) {
    return {
      target:     j.target,
      type:       j.tool === 'memory' ? 'Memory' : 'Disk',
      binary:     j.tool === 'memory' ? memBin : diskBin,
      remoteDest: (el('qm-rd-' + idx) || {}).value || '',
      arguments:  (el('qm-args-' + idx) || {}).value || '',
      method:     (el('qm-method-' + idx) || {}).value || 'Auto',
      remoteShare: (el('qm-smb-' + idx) || {}).value || '',
      aliveCheck: parseInt((el('qm-alive-' + idx) || {}).value || '30', 10) || 30
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
    ok.innerHTML = '<strong>quicker:// URI sent to Windows.</strong><br>If QuickerLaunch.ps1 does not open: Run <code>Register-QuickerProtocol.ps1</code> as Administrator first.';
    body.insertBefore(ok, body.firstChild);
  }
  var actions = el('qm-actions');
  if (actions) actions.innerHTML = '<button onclick="_closeQueueModal()">Close</button>';
}

function execToggleSection(bodyId) {
  var body = el(bodyId);
  if (!body) return;
  var nowCollapsed = body.classList.toggle('collapsed');
  var arrowId = bodyId === 'exec-sec1-body' ? 'exec-sec1-arrow' : 'exec-sec2-arrow';
  var arrow = el(arrowId);
  if (arrow) arrow.innerHTML = nowCollapsed ? '&#9654;' : '&#9660;';
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
