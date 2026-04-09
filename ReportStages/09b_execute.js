// ╔══════════════════════════════════════╗
// ║  QuickAiR — 09b_execute.js            ║
// ║  Execute tab, host status panel      ║
// ║  with memory/disk checkboxes, queue  ║
// ║  preview dialog, tool dropdown from  ║
// ║  tools.json, quickair:// URI gen.     ║
// ║  Uses shared target list from core.  ║
// ╠══════════════════════════════════════╣
// ║  Reads    : _sharedTargets,           ║
// ║             tools.json, state.hosts   ║
// ║  Writes   : _bulkSel, _toolsManifest ║
// ║  Functions: renderExecute, execBulk-  ║
// ║    AddToQueue, execBulkMemCheck,      ║
// ║    execBulkDiskCheck, execBulkToggle- ║
// ║    Mem, execBulkToggleDisk,           ║
// ║    execAddManualTarget,               ║
// ║    execImportManualCSV,               ║
// ║    execRemoveHost,                    ║
// ║    updateExecuteBadge,                ║
// ║    renderFleetExecBanners,            ║
// ║    execToggleSection                  ║
// ║  Depends  : 03_core.js               ║
// ║  Version  : 4.01                      ║
// ╚══════════════════════════════════════╝

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
    '.fleet-err-banner{background:rgba(210,140,0,.1);border:1px solid var(--amber);border-radius:4px;padding:7px 12px;margin-bottom:6px;font-size:12px;color:var(--amber);display:flex;align-items:center;gap:10px}',
    '.fleet-err-banner a{color:var(--accent);cursor:pointer;text-decoration:underline;white-space:nowrap}',
    '.tab-badge{display:inline-block;background:var(--amber);color:#0d1117;font-size:10px;font-weight:bold;border-radius:8px;padding:1px 5px;margin-left:4px;vertical-align:middle;line-height:14px}',
    '.tab-badge.red{background:var(--red);color:#fff}',
    '.qm-bin-wrap{display:flex;flex-direction:column;gap:4px}',
    '.exec-setup-banner{background:rgba(100,120,150,.08);border:1px solid var(--border);border-radius:4px;padding:7px 14px;margin-bottom:10px;font-size:12px;color:var(--muted);display:flex;align-items:center;gap:8px}',
    '.exec-src-badge{display:inline-block;font-size:10px;font-weight:bold;padding:1px 6px;border-radius:3px;letter-spacing:.3px}',
    '.exec-src-json{background:rgba(88,166,255,.15);color:var(--accent)}',
    '.exec-src-manual{background:rgba(210,153,34,.15);color:var(--amber)}',
    '.exec-add-section{margin-bottom:12px;border:1px solid var(--border);border-radius:4px;overflow:hidden}',
    '.exec-add-hdr{font-size:12px;color:var(--muted);padding:6px 10px;cursor:pointer;user-select:none;display:flex;align-items:center;gap:6px;background:var(--surface)}',
    '.exec-add-hdr:hover{color:var(--accent)}',
    '.exec-add-body{overflow:hidden;transition:max-height 0.3s ease;max-height:400px;padding:8px 10px}',
    '.exec-add-body.collapsed{max-height:0;padding:0 10px}',
    '.exec-input-row{display:flex;gap:8px;align-items:center;margin-bottom:6px}',
    '.exec-input-row input[type="text"]{flex:1;max-width:280px;padding:4px 8px;font-size:12px}',
    '.exec-add-btn{font-size:11px;padding:3px 10px;cursor:pointer;background:var(--surface);color:var(--fg);border:1px solid var(--border);border-radius:3px}',
    '.exec-add-btn:hover{border-color:var(--accent);color:var(--accent)}',
    '.exec-msg{font-size:12px;padding:5px 10px;margin:6px 0;border-radius:3px}',
    '.exec-msg-warn{color:var(--amber);background:rgba(210,153,34,.08);border:1px solid rgba(210,153,34,.2)}',
    '.exec-msg-success{color:var(--green);background:rgba(63,185,80,.08);border:1px solid rgba(63,185,80,.2)}',
    '.exec-remove-btn{cursor:pointer;color:var(--red);font-size:14px;border:none;background:none;padding:2px 6px}',
    '.exec-remove-btn:hover{color:#fff;background:var(--red);border-radius:3px}',
    '.exec-tooltip-wrap{position:relative;display:inline-block}',
    '.exec-tooltip{display:none;position:absolute;bottom:calc(100% + 6px);left:0;background:var(--bg);color:var(--fg);border:1px solid var(--border);border-radius:4px;padding:8px 10px;font-size:11px;white-space:pre-line;width:260px;z-index:100;box-shadow:0 2px 8px rgba(0,0,0,.3)}',
    '.exec-tooltip-wrap:hover .exec-tooltip{display:block}',
    '.exec-status-notcollected{color:var(--muted);font-style:italic}',
    '.exec-user-input{width:120px;padding:2px 6px;font-size:11px;background:var(--bg);color:var(--fg);border:1px solid var(--border);border-radius:3px;box-sizing:border-box}'
  ].join('');
  document.head.appendChild(s);
})();

var _bulkSel = {};          // { hostname: { mem, disk } }
var _toolsManifest       = null;   // cached tools.json data
var _toolsManifestLoaded = false;  // true once fetch attempt completed
var _qmRemoteDestModified = false; // legacy — kept for _execTabRemoteDestModified compat
var _execRemovedHosts = {}; // collected hosts removed from table by user

function _loadToolsManifest(callback) {
  if (!_toolsManifestLoaded) {
    _toolsManifest = (typeof _embeddedToolsManifest !== 'undefined') ? _embeddedToolsManifest : null;
    _toolsManifestLoaded = true;
  }
  callback(_toolsManifest);
}

function _getCollectionStatus(hostname) {
  var d = state.hosts[hostname];
  if (!d || !d.manifest) return { status: 'nodata', label: 'No data', cls: 'exec-status-nodata', errors: [], warnings: [] };
  var m = d.manifest;
  var all = m.collection_errors || [];
  var warnings = all.filter(function(e) { return e && e.severity === 'warning'; });
  var errors   = all.filter(function(e) { return !e || e.severity !== 'warning'; });
  if (m.collection_failed === true) return { status: 'failed', label: 'Failed', cls: 'exec-status-failed', errors: errors, warnings: warnings };
  if (errors.length > 0) return { status: 'partial', label: 'Partial (' + errors.length + ' errors)', cls: 'exec-status-partial', errors: errors, warnings: warnings };
  if (warnings.length > 0) return { status: 'complete', label: 'Complete (' + warnings.length + ' warnings)', cls: 'exec-status-complete', errors: errors, warnings: warnings };
  return { status: 'complete', label: 'Complete', cls: 'exec-status-complete', errors: [], warnings: [] };
}

function _getWinRMStatus(hostname) {
  var d = state.hosts[hostname];
  if (!d || !d.manifest) return { status: 'unknown', label: 'Unknown', cls: 'exec-winrm-unknown' };
  var m = d.manifest;
  if (m.winrm_reachable === true)  return { status: 'reachable',   label: 'Reachable',   cls: 'exec-winrm-reach'   };
  if (m.winrm_reachable === false) return { status: 'unreachable', label: 'Unreachable', cls: 'exec-winrm-unreach' };
  // Infer from collection data: null + no real errors + processes present → reachable
  var realErrors = (m.collection_errors || []).filter(function(e) { return !e || e.severity !== 'warning'; });
  var procCount = (d.Processes && d.Processes.length) ? d.Processes.length : 0;
  if (realErrors.length === 0 && procCount > 0) return { status: 'reachable', label: 'Reachable', cls: 'exec-winrm-reach' };
  return { status: 'unknown', label: 'Unknown', cls: 'exec-winrm-unknown' };
}

function _getWmiStatus(hostname) {
  var d = state.hosts[hostname];
  if (!d || !d.manifest) return { status: 'unknown', label: 'Unknown', cls: 'exec-winrm-unknown' };
  var m = d.manifest;
  if (m.wmi_reachable === true)  return { status: 'reachable',   label: 'Reachable',   cls: 'exec-winrm-reach' };
  if (m.wmi_reachable === false) return { status: 'unreachable', label: 'Unreachable', cls: 'exec-winrm-unreach' };
  return { status: 'unknown', label: 'Unknown', cls: 'exec-winrm-unknown' };
}

function _getSmbStatus(hostname) {
  var d = state.hosts[hostname];
  if (!d || !d.manifest) return { status: 'unknown', label: 'Unknown', cls: 'exec-winrm-unknown' };
  var m = d.manifest;
  if (m.smb_reachable === true) {
    var share = m.smb_share_name || 'C$';
    return { status: 'reachable', label: share, cls: 'exec-winrm-reach' };
  }
  if (m.smb_reachable === false) return { status: 'unreachable', label: 'Unreachable', cls: 'exec-winrm-unreach' };
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

  sharedLoadTargets();

  // ── Build unified host list ───────────────────────────────────────────────
  var collectedHosts = Object.keys(state.hosts).filter(function(h) { return !_execRemovedHosts[h]; });
  var manualHostnames = _sharedTargets.map(function(t) { return t.hostname; });
  var allHosts = collectedHosts.concat(manualHostnames);

  // Initialise bulk-selection state for all hosts
  allHosts.forEach(function(h) {
    if (!_bulkSel[h]) _bulkSel[h] = { mem: false, disk: false };
  });
  // Clean up stale _bulkSel entries
  Object.keys(_bulkSel).forEach(function(h) {
    if (allHosts.indexOf(h) === -1) delete _bulkSel[h];
  });

  // ── Add Targets section (collapsible, collapsed by default) ───────────────
  var addSectionHTML =
    '<div class="exec-add-section">' +
      '<div class="exec-add-hdr" onclick="execToggleSection(\'exec-add-body\',\'exec-add-arrow\')">' +
        '<span class="exec-sec-arrow" id="exec-add-arrow">&#9654;</span>' +
        '<span>&#10133; Add Targets Manually</span>' +
      '</div>' +
      '<div class="exec-add-body collapsed" id="exec-add-body">' +
        '<div class="exec-input-row">' +
          '<input type="text" id="exec-manual-input" placeholder="Hostname or IP" onkeydown="if(event.key===\'Enter\')execAddManualTarget()">' +
          '<button class="exec-add-btn" onclick="execAddManualTarget()">+ Add</button>' +
          '<span style="margin-left:12px">' +
            '<div class="exec-tooltip-wrap">' +
              '<button class="exec-add-btn" onclick="document.getElementById(\'exec-csv-input\').click()">Import CSV</button>' +
              '<div class="exec-tooltip">Supported formats:\nSimple: one hostname or IP per line\nAdvanced: Hostname,OS,Notes,Username\nLines starting with # are ignored</div>' +
            '</div>' +
          '</span>' +
          '<input type="file" id="exec-csv-input" accept=".csv,.txt" style="display:none" onchange="execImportManualCSV(this.files)">' +
        '</div>' +
        '<div id="exec-manual-msg"></div>' +
      '</div>' +
    '</div>';

  // ── Section 1: Host Table ─────────────────────────────────────────────────
  var sec1HTML;
  if (allHosts.length === 0) {
    sec1HTML = addSectionHTML +
      '<div class="exec-no-hosts">No hosts loaded. Load a JSON file or add targets manually.</div>';
  } else {
    var rows = '';
    // Collected host rows
    collectedHosts.forEach(function(h) {
      var d  = state.hosts[h];
      var m  = (d && d.manifest) || {};
      var ws   = _getWinRMStatus(h);
      var wmis = _getWmiStatus(h);
      var smbs = _getSmbStatus(h);
      var cs   = _getCollectionStatus(h);
      var bs   = _bulkSel[h];
      var winrmNotice = (ws.status === 'unreachable')
        ? '<div class="exec-winrm-notice">WinRM unreachable during collection. Execution may still be possible with different credentials or method.</div>'
        : (ws.status === 'unknown' ? '<div class="exec-winrm-notice">WinRM status unknown.</div>' : '');
      var jsonUser = sharedGetUsername(h);
      rows += '<tr id="exec-row-' + cssId(h) + '">' +
        '<td><strong>' + esc(h) + '</strong></td>' +
        '<td><span class="exec-src-badge exec-src-json">JSON</span></td>' +
        '<td class="dim">' + esc(m.target_os_caption || '') + '</td>' +
        '<td><span class="' + cs.cls + '">' + esc(cs.label) + '</span></td>' +
        '<td><span class="' + ws.cls + '">' + esc(ws.label) + '</span>' + winrmNotice + '</td>' +
        '<td><span class="' + wmis.cls + '">' + esc(wmis.label) + '</span></td>' +
        '<td><span class="' + smbs.cls + '">' + esc(smbs.label) + '</span></td>' +
        '<td><input type="text" class="exec-user-input" id="exc-user-' + cssId(h) + '" value="' + esc(jsonUser) + '" placeholder="DOMAIN\\user" onchange="sharedSetUsername(\'' + escJs(h) + '\',this.value)"></td>' +
        '<td class="exec-type-col"><input type="checkbox" id="exc-mem-' + cssId(h) + '"' + (bs.mem ? ' checked' : '') + ' onchange="execBulkMemCheck(\'' + escJs(h) + '\')"></td>' +
        '<td class="exec-type-col"><input type="checkbox" id="exc-dsk-' + cssId(h) + '"' + (bs.disk ? ' checked' : '') + ' onchange="execBulkDiskCheck(\'' + escJs(h) + '\')"></td>' +
        '<td><button class="exec-remove-btn" onclick="execRemoveHost(\'' + escJs(h) + '\',false)" title="Remove">&times;</button></td>' +
        '</tr>';
    });
    // Manual host rows
    _sharedTargets.forEach(function(t) {
      var h = t.hostname;
      var bs = _bulkSel[h];
      rows += '<tr id="exec-row-' + cssId(h) + '">' +
        '<td><strong>' + esc(h) + '</strong></td>' +
        '<td><span class="exec-src-badge exec-src-manual">Manual</span></td>' +
        '<td class="dim">' + esc(t.os || '\u2014') + '</td>' +
        '<td><span class="exec-status-notcollected">Not collected</span></td>' +
        '<td><span class="exec-winrm-unknown">Unknown</span></td>' +
        '<td><span class="exec-winrm-unknown">Unknown</span></td>' +
        '<td><span class="exec-winrm-unknown">Unknown</span></td>' +
        '<td><input type="text" class="exec-user-input" id="exc-user-' + cssId(h) + '" value="' + esc(t.username || '') + '" placeholder="DOMAIN\\user" onchange="sharedSetUsername(\'' + escJs(h) + '\',this.value)"></td>' +
        '<td class="exec-type-col"><input type="checkbox" id="exc-mem-' + cssId(h) + '"' + (bs.mem ? ' checked' : '') + ' onchange="execBulkMemCheck(\'' + escJs(h) + '\')"></td>' +
        '<td class="exec-type-col"><input type="checkbox" id="exc-dsk-' + cssId(h) + '"' + (bs.disk ? ' checked' : '') + ' onchange="execBulkDiskCheck(\'' + escJs(h) + '\')"></td>' +
        '<td><button class="exec-remove-btn" onclick="execRemoveHost(\'' + escJs(h) + '\',true)" title="Remove">&times;</button></td>' +
        '</tr>';
    });
    sec1HTML = addSectionHTML +
      '<table class="exec-host-tbl">' +
      '<thead><tr>' +
        '<th>Hostname</th><th>Source</th><th>OS</th><th>Collection</th><th>WinRM</th><th>WMI</th><th>SMB Share</th><th>Username</th>' +
        '<th class="exec-type-col exec-th-toggle" onclick="execBulkToggleMem()" title="Toggle Memory on selected rows">Memory</th>' +
        '<th class="exec-type-col exec-th-toggle" onclick="execBulkToggleDisk()" title="Toggle Disk on selected rows">Disk</th>' +
        '<th></th>' +
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

  var bannerHtml = renderSetupBanner('execute');

  panel.innerHTML = bannerHtml +
    '<div class="exec-section">' +
      '<div class="exec-section-hdr" onclick="execToggleSection(\'exec-sec1-body\',\'exec-sec1-arrow\')">' +
        '<span class="exec-sec-arrow" id="exec-sec1-arrow">&#9660;</span>Select Hosts' +
      '</div>' +
      '<div class="exec-section-body" id="exec-sec1-body">' + sec1HTML + '</div>' +
    '</div>';

  _execEnsureQueueModal();
  _execUpdateSelCounter();
  _loadToolsManifest(function(manifest) {
    var banner = el('exec-setup-banner');
    if (banner && manifest) banner.style.display = '';
  });
}

// ── BULK SELECTION HANDLERS ───────────────────────────────────────────────────


function execBulkMemCheck(hostname) {
  var cb = el('exc-mem-' + cssId(hostname));
  if (!cb || !_bulkSel[hostname]) return;
  _bulkSel[hostname].mem = cb.checked;
  _execUpdateSelCounter();
}

function execBulkDiskCheck(hostname) {
  var cb = el('exc-dsk-' + cssId(hostname));
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
    var cb = el('exc-mem-' + cssId(h));
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
    var cb = el('exc-dsk-' + cssId(h));
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
      '<td class="qm-cell-host">' + esc(j.target) + (!state.hosts[j.target] ? ' <span class="exec-src-badge exec-src-manual">Manual</span>' : '') + '</td>' +
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
      aliveCheck: parseInt((el('qm-alive-' + idx) || {}).value || '30', 10) || 30,
      username:   sharedGetUsername(j.target)
    };
  });
  var jsonStr = JSON.stringify(payload);
  var encoded = encodeURIComponent(btoa(unescape(encodeURIComponent(jsonStr))));
  var uri = 'quickair://batch?jobs=' + encoded;
  if (uri.length > 8000) {
    var body = el('qm-body');
    if (body) { var t = document.createElement('div'); t.style.cssText = 'background:#d32f2f;color:#fff;padding:8px 16px;margin:8px 0;border-radius:4px;font-size:13px;'; t.textContent = 'URI too long (' + uri.length + ' chars). Reduce batch size and try again.'; body.insertBefore(t, body.firstChild); }
    return;
  }
  var ifr = document.createElement('iframe');
  ifr.style.display = 'none';
  ifr.src = uri;
  document.body.appendChild(ifr);
  setTimeout(function(){ document.body.removeChild(ifr); }, 2000);
  // Show success
  var body = el('qm-body');
  if (body) {
    var ok = document.createElement('div');
    ok.className = 'qm-success';
    ok.innerHTML = '<strong>quickair:// URI sent to Windows.</strong><br>QuickAiRLaunch.ps1 should open shortly.';
    body.insertBefore(ok, body.firstChild);
  }
  var actions = el('qm-actions');
  if (actions) actions.innerHTML = '<button onclick="_closeQueueModal()">Close</button>';
}

// ── MANUAL TARGET ENTRY (delegates to shared target list in 03_core.js) ─────

function execAddManualTarget() {
  var inp = el('exec-manual-input');
  if (!inp) return;
  var val = inp.value.trim();
  var msgEl = el('exec-manual-msg');
  if (!val) return;
  if (/[\s<>"';&|]/.test(val)) {
    if (msgEl) msgEl.innerHTML = '<div class="exec-msg exec-msg-warn">Invalid format \u2014 no spaces or special characters allowed.</div>';
    return;
  }
  if (sharedIsHostInList(val) || _sharedCheckCollected(val)) {
    if (msgEl) msgEl.innerHTML = '<div class="exec-msg exec-msg-warn">Already in list.</div>';
    return;
  }
  sharedAddTarget(val);
  inp.value = '';
  if (msgEl) msgEl.innerHTML = '';
  renderExecute();
  _execExpandAddSection();
  var ri = el('exec-manual-input');
  if (ri) ri.focus();
}

function execImportManualCSV(files) {
  if (!files || !files.length) return;
  var reader = new FileReader();
  reader.onload = function(e) {
    var result = sharedImportCSV(e.target.result);
    renderExecute();
    _execExpandAddSection();

    var msgEl = el('exec-manual-msg');
    if (msgEl) {
      var parts = [];
      if (result.added > 0) parts.push(result.added + ' target' + (result.added !== 1 ? 's' : '') + ' added');
      if (result.dupes > 0) parts.push(result.dupes + ' skipped (duplicate' + (result.dupes !== 1 ? 's' : '') + ')');
      var html = '';
      if (parts.length > 0) html += '<div class="exec-msg exec-msg-success">' + parts.join(', ') + '.</div>';
      if (result.invalid.length > 0) html += '<div class="exec-msg exec-msg-warn">Parse error on line' + (result.invalid.length !== 1 ? 's' : '') + ' ' +
        result.invalid.map(function(e) { return e.line; }).join(', ') + '.</div>';
      msgEl.innerHTML = html;
    }
    var fi = el('exec-csv-input');
    if (fi) fi.value = '';
  };
  reader.readAsText(files[0]);
}

function _execExpandAddSection() {
  var addBody = el('exec-add-body');
  if (addBody && addBody.classList.contains('collapsed')) {
    addBody.classList.remove('collapsed');
    var arrow = el('exec-add-arrow');
    if (arrow) arrow.innerHTML = '&#9660;';
  }
}

function execRemoveHost(hostname, isManual) {
  if (isManual) {
    sharedRemoveTarget(hostname);
  } else {
    _execRemovedHosts[hostname] = true;
  }
  delete _bulkSel[hostname];
  renderExecute();
}

function execToggleSection(bodyId, arrowId) {
  var body = el(bodyId);
  if (!body) return;
  var nowCollapsed = body.classList.toggle('collapsed');
  var arrow = arrowId ? el(arrowId) : null;
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
    var errCount = (cs.errors || []).length;
    var tooltip = (cs.errors || []).map(function(e) {
      return (e && e.artifact ? e.artifact + ': ' : '') + (e && e.message ? e.message : String(e));
    }).join('\n');
    var tipAttr = tooltip ? ' title="' + esc(tooltip) + '" style="cursor:help"' : '';
    return '<div class="fleet-err-banner">' +
      '&#9888; <strong>' + esc(h) + '</strong> &mdash; collection ' + (cs.status === 'failed' ? 'failed' : 'incomplete') + '.' +
      (errCount > 0 ? ' <span' + tipAttr + '>' + errCount + ' error' + (errCount === 1 ? '' : 's') + ' recorded.</span>' : '') +
      ' Use the EXECUTE tab to run memory or disk collection directly.' +
      ' &nbsp;<a onclick="switchTab(\'execute\')">Go to Execute tab</a>' +
      '</div>';
  }).join('');
  wrap.innerHTML = banners;
}
