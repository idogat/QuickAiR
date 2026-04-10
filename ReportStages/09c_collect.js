// ╔══════════════════════════════════════╗
// ║  QuickAiR — 09c_collect.js           ║
// ║  Collect tab — shared target list,  ║
// ║  plugin selection, output path      ║
// ║  config, quickair-collect:// URI    ║
// ║  generation                          ║
// ╠══════════════════════════════════════╣
// ║  Reads    : _sharedTargets, state    ║
// ║  Writes   : nothing (shared targets ║
// ║             managed by 03_core.js)   ║
// ║  Functions: renderCollect,           ║
// ║    colAddTarget, colRemoveTarget,    ║
// ║    colClearTargets, colImportCSV,    ║
// ║    colCollect, colToggleSection      ║
// ║  Depends  : 03_core.js              ║
// ║  Version  : 2.01                     ║
// ╚══════════════════════════════════════╝

var _colRemovedHosts = {};

// ── COLLECT TAB ─────────────────────────────────────────────────────────────────
(function injectCollectCSS() {
  var s = document.createElement('style');
  s.textContent = [
    '#panel-collect{padding:12px 16px}',
    '.col-section{margin-bottom:24px}',
    '.col-section-hdr{font-size:13px;font-weight:bold;color:var(--fg);margin:0;padding:6px 0;border-bottom:1px solid var(--border);cursor:pointer;user-select:none;display:flex;align-items:center;gap:6px}',
    '.col-section-hdr:hover{color:var(--accent)}',
    '.col-sec-arrow{color:var(--accent);font-size:11px;width:10px;display:inline-block}',
    '.col-section-body{overflow:hidden;transition:max-height 0.3s ease;max-height:4000px;padding-top:8px}',
    '.col-section-body.collapsed{max-height:0;padding-top:0}',
    '.col-input-row{display:flex;gap:8px;align-items:center;margin-bottom:8px}',
    '.col-input-row input[type="text"]{flex:1;max-width:320px;padding:4px 8px;font-size:12px;background:var(--bg);color:var(--fg);border:1px solid var(--border);border-radius:3px}',
    '.col-btn{font-size:11px;padding:3px 10px;cursor:pointer;background:var(--btn-bg,#21262d);color:var(--fg);border:1px solid var(--border);border-radius:3px}',
    '.col-btn:hover{border-color:var(--accent);color:var(--accent)}',
    '.col-btn:disabled{opacity:0.4;cursor:not-allowed}',
    '.col-btn-primary{background:var(--accent);color:#fff;border-color:var(--accent);font-weight:bold;padding:5px 16px;font-size:12px}',
    '.col-btn-primary:hover{opacity:0.9;color:#fff!important}',
    '.col-btn-primary:disabled{opacity:0.4;cursor:not-allowed}',
    '.col-btn-danger{color:var(--red);border-color:var(--red)}',
    '.col-btn-danger:hover{background:var(--red);color:#fff}',
    '.col-target-tbl{width:100%;border-collapse:collapse;font-size:12px;margin-top:8px}',
    '.col-target-tbl th{text-align:left;padding:4px 10px;color:var(--muted);font-weight:normal;border-bottom:1px solid var(--border)}',
    '.col-target-tbl td{padding:5px 10px;border-bottom:1px solid var(--border);vertical-align:middle}',
    '.col-target-tbl tr:hover td{background:var(--row-hov)}',
    '.col-target-tbl input[type="text"]{width:100%;padding:2px 6px;font-size:12px;background:var(--bg);color:var(--fg);border:1px solid var(--border);border-radius:3px;box-sizing:border-box}',
    '.col-remove-btn{cursor:pointer;color:var(--red);font-size:14px;border:none;background:none;padding:2px 6px}',
    '.col-remove-btn:hover{color:#fff;background:var(--red);border-radius:3px}',
    '.col-msg{font-size:12px;padding:6px 10px;margin:8px 0;border-radius:3px}',
    '.col-msg-info{color:var(--accent);background:rgba(88,166,255,0.08);border:1px solid rgba(88,166,255,0.2)}',
    '.col-msg-success{color:var(--green);background:rgba(63,185,80,0.08);border:1px solid rgba(63,185,80,0.2)}',
    '.col-msg-warn{color:var(--amber);background:rgba(210,153,34,0.08);border:1px solid rgba(210,153,34,0.2)}',
    '.col-plugin-list{list-style:none;padding:0;margin:4px 0}',
    '.col-plugin-list li{padding:3px 0;font-size:12px;display:flex;align-items:center;gap:6px}',
    '.col-plugin-list input[type="checkbox"]{margin:0}',
    '.col-settings-row{display:flex;align-items:center;gap:10px;margin-bottom:10px;font-size:12px}',
    '.col-settings-row label{color:var(--muted);min-width:110px}',
    '.col-settings-row input[type="text"]{padding:4px 8px;font-size:12px;background:var(--bg);color:var(--fg);border:1px solid var(--border);border-radius:3px;width:280px}',
    '.col-method{color:var(--muted);font-style:italic}',
    '.col-count{font-size:11px;color:var(--muted);margin-left:8px}',
    '.col-tooltip-wrap{position:relative;display:inline-block}',
    '.col-tooltip{display:none;position:absolute;top:calc(100% + 6px);left:0;background:var(--bg);color:var(--fg);border:1px solid var(--border);border-radius:4px;padding:8px 10px;font-size:11px;white-space:pre-line;width:260px;z-index:100;box-shadow:0 2px 8px rgba(0,0,0,0.3)}',
    '.col-tooltip-wrap:hover .col-tooltip{display:block}',
    '.col-empty{color:var(--muted);font-style:italic;padding:8px 0;font-size:12px}',
    '.col-user-input{width:120px;padding:2px 6px;font-size:11px;background:var(--bg);color:var(--fg);border:1px solid var(--border);border-radius:3px;box-sizing:border-box}'
  ].join('');
  document.head.appendChild(s);
})();

var _colDefaultOutput = '.\\DFIROutput\\';
var _colPlugins = ['Processes', 'Network', 'DLLs', 'Users'];

function renderCollect() {
  var panel = el('panel-collect');
  if (!panel) return;

  sharedLoadTargets();

  var bannerHtml = renderSetupBanner('collect');

  // Build unified target list: shared manual targets + collected hosts
  var allTargets = [];
  _sharedTargets.forEach(function(t) {
    allTargets.push({ hostname: t.hostname, username: t.username || '', source: 'manual' });
  });
  Object.keys(state.hosts || {}).forEach(function(h) {
    if (!_colRemovedHosts[h]) allTargets.push({ hostname: h, username: sharedGetUsername(h), source: 'json' });
  });

  var targetRows = '';
  if (allTargets.length === 0) {
    targetRows = '<tr><td colspan="5" class="col-empty">No targets added yet. Add targets here or on the Execute tab.</td></tr>';
  } else {
    for (var i = 0; i < allTargets.length; i++) {
      var t = allTargets[i];
      var srcBadge = t.source === 'json'
        ? '<span class="exec-src-badge exec-src-json">JSON</span>'
        : '<span class="exec-src-badge exec-src-manual">Manual</span>';
      targetRows += '<tr>' +
        '<td>' + esc(t.hostname) + '</td>' +
        '<td>' + srcBadge + '</td>' +
        '<td><input type="text" class="col-user-input" value="' + esc(t.username) + '" placeholder="DOMAIN\\user" onchange="sharedSetUsername(\'' + escJs(t.hostname) + '\',this.value)"></td>' +
        '<td><button class="col-remove-btn" onclick="colRemoveTarget(\'' + escJs(t.hostname) + '\',\'' + t.source + '\')" title="Remove">&times;</button></td>' +
        '</tr>';
    }
  }

  var pluginChecks = '';
  for (var p = 0; p < _colPlugins.length; p++) {
    pluginChecks += '<li><input type="checkbox" id="col-plug-' + p + '" checked> ' + esc(_colPlugins[p]) + '</li>';
  }

  var collectDisabled = allTargets.length === 0 ? ' disabled' : '';

  panel.innerHTML = bannerHtml +
    // ── Section 1: Targets ──
    '<div class="col-section">' +
      '<div class="col-section-hdr" onclick="colToggleSection(\'col-sec1-body\',\'col-sec1-arrow\')">' +
        '<span class="col-sec-arrow" id="col-sec1-arrow">&#9660;</span>Targets' +
        '<span class="col-count">(' + allTargets.length + ' target' + (allTargets.length !== 1 ? 's' : '') + ')</span>' +
      '</div>' +
      '<div class="col-section-body" id="col-sec1-body">' +
        '<div class="col-input-row">' +
          '<input type="text" id="col-hostname" placeholder="Hostname or IP" onkeydown="if(event.key===\'Enter\')colAddTarget()">' +
          '<button class="col-btn" onclick="colAddTarget()">+ Add</button>' +
          '<span style="margin-left:12px">' +
            '<div class="col-tooltip-wrap">' +
              '<label class="col-btn" for="col-csv-input" style="cursor:pointer">Import CSV</label>' +
              '<div class="col-tooltip">Supported formats:\nSimple: one hostname or IP per line\nAdvanced: Hostname,OS,Notes,Username\nLines starting with # are ignored</div>' +
            '</div>' +
          '</span>' +
          '<input type="file" id="col-csv-input" accept=".csv,.txt" style="display:none" onchange="colImportCSV(this.files)">' +
        '</div>' +
        '<div id="col-import-msg"></div>' +
        '<table class="col-target-tbl">' +
          '<thead><tr><th>Hostname / IP</th><th>Source</th><th>Username</th><th></th></tr></thead>' +
          '<tbody>' + targetRows + '</tbody>' +
        '</table>' +
        (allTargets.length > 0 ? '<div style="margin-top:6px"><button class="col-btn col-btn-danger" onclick="colClearTargets()">Clear Manual Targets</button></div>' : '') +
      '</div>' +
    '</div>' +

    // ── Section 2: Collection Settings ──
    '<div class="col-section">' +
      '<div class="col-section-hdr" onclick="colToggleSection(\'col-sec2-body\',\'col-sec2-arrow\')">' +
        '<span class="col-sec-arrow" id="col-sec2-arrow">&#9660;</span>Collection Settings' +
      '</div>' +
      '<div class="col-section-body" id="col-sec2-body">' +
        '<div class="col-settings-row">' +
          '<label>Output Path:</label>' +
          '<input type="text" id="col-global-output" value="' + esc(_colDefaultOutput) + '" onchange="_colDefaultOutput=this.value">' +
        '</div>' +
        '<div class="col-settings-row" style="align-items:flex-start">' +
          '<label>Plugins:</label>' +
          '<ul class="col-plugin-list">' + pluginChecks + '</ul>' +
        '</div>' +
        '<div class="col-settings-row">' +
          '<label>Method:</label>' +
          '<span class="col-method">WinRM</span>' +
        '</div>' +
        '<div class="col-settings-row">' +
          '<label>Max Concurrent:</label>' +
          '<input type="number" id="col-max-concurrent" value="5" min="1" max="20" style="width:60px;padding:4px 8px;font-size:12px;background:var(--bg);color:var(--fg);border:1px solid var(--border);border-radius:3px">' +
        '</div>' +
        '<div style="margin-top:16px">' +
          '<button class="col-btn col-btn-primary"' + collectDisabled + ' onclick="colCollect()">Collect &#8594;</button>' +
        '</div>' +
        '<div id="col-collect-msg"></div>' +
      '</div>' +
    '</div>';
}

function colAddTarget() {
  var inp = el('col-hostname');
  if (!inp) return;
  var val = inp.value.trim();
  if (!val) return;
  var msgEl = el('col-import-msg');
  if (/[\s<>"';&|]/.test(val)) {
    if (msgEl) msgEl.innerHTML = '<div class="col-msg col-msg-warn">Invalid format \u2014 no spaces or special characters allowed.</div>';
    return;
  }
  if (sharedIsHostInList(val) || _sharedCheckCollected(val)) {
    if (msgEl) msgEl.innerHTML = '<div class="col-msg col-msg-warn">"' + esc(val) + '" is already in the list.</div>';
    return;
  }
  sharedAddTarget(val);
  inp.value = '';
  if (msgEl) msgEl.innerHTML = '';
  renderCollect();
  var ri = el('col-hostname');
  if (ri) ri.focus();
}

function colRemoveTarget(hostname, source) {
  if (source === 'manual') {
    sharedRemoveTarget(hostname);
  } else {
    _colRemovedHosts[hostname] = true;
  }
  renderCollect();
}

function colClearTargets() {
  _sharedTargets = [];
  sharedSaveTargets();
  renderCollect();
}

function colImportCSV(files) {
  if (!files || !files.length) return;
  var reader = new FileReader();
  reader.onload = function(e) {
    var result = sharedImportCSV(e.target.result);

    renderCollect();

    var msgEl = el('col-import-msg');
    if (msgEl) {
      var parts = [];
      if (result.added > 0) parts.push(result.added + ' target' + (result.added !== 1 ? 's' : '') + ' imported');
      if (result.dupes > 0) parts.push(result.dupes + ' duplicate' + (result.dupes !== 1 ? 's' : '') + ' skipped');
      var html = '';
      if (parts.length > 0) html += '<div class="col-msg col-msg-success">' + parts.join(', ') + '.</div>';
      if (result.invalid.length > 0) html += '<div class="col-msg col-msg-warn">Invalid entries (' + result.invalid.length + '): lines ' +
        result.invalid.map(function(e) { return e.line; }).join(', ') + '</div>';
      msgEl.innerHTML = html;
    }

    var fi = el('col-csv-input');
    if (fi) fi.value = '';
  };
  reader.readAsText(files[0]);
}

function colCollect() {
  var selectedPlugins = [];
  for (var p = 0; p < _colPlugins.length; p++) {
    var cb = el('col-plug-' + p);
    if (cb && cb.checked) selectedPlugins.push(_colPlugins[p]);
  }

  if (selectedPlugins.length === 0) {
    var msgEl = el('col-collect-msg');
    if (msgEl) msgEl.innerHTML = '<div class="col-msg col-msg-warn">Select at least one plugin before collecting.</div>';
    return;
  }

  var globalOut = (el('col-global-output') || {}).value || _colDefaultOutput;

  // Build targets from both shared + collected hosts
  var allHostnames = [];
  _sharedTargets.forEach(function(t) { allHostnames.push(t.hostname); });
  Object.keys(state.hosts || {}).forEach(function(h) {
    if (allHostnames.indexOf(h) === -1) allHostnames.push(h);
  });

  var targets = allHostnames.map(function(h) {
    return {
      hostname: h,
      outputPath: globalOut,
      plugins: selectedPlugins,
      username: sharedGetUsername(h)
    };
  });

  var jsonStr = JSON.stringify(targets);
  var encoded = encodeURIComponent(btoa(unescape(encodeURIComponent(jsonStr))));
  var maxC = parseInt((el('col-max-concurrent') || {}).value, 10) || 5;
  if (maxC < 1) maxC = 1; if (maxC > 20) maxC = 20;
  var uri = 'quickair-collect://collect?targets=' + encoded + '&maxConcurrent=' + maxC;

  if (uri.length > 8000) {
    var msgEl = el('col-collect-msg');
    if (msgEl) msgEl.innerHTML = '<div class="col-msg col-msg-warn" style="margin-top:10px">' +
      'URI too long (' + uri.length + ' chars). Reduce the number of targets or shorten the output path.' +
      '</div>';
    return;
  }

  window.location.href = uri;

  var msgEl = el('col-collect-msg');
  if (msgEl) {
    msgEl.innerHTML = '<div class="col-msg col-msg-success" style="margin-top:10px">' +
      'Collection started \u2014 QuickAiRCollect.ps1 should open shortly.' +
      '</div>';
  }
}

function colToggleSection(bodyId, arrowId) {
  var body = el(bodyId);
  if (!body) return;
  var nowCollapsed = body.classList.toggle('collapsed');
  var arrow = el(arrowId);
  if (arrow) arrow.innerHTML = nowCollapsed ? '&#9654;' : '&#9660;';
}
