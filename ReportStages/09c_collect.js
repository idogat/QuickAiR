// ╔══════════════════════════════════════╗
// ║  QuickAiR — 09c_collect.js           ║
// ║  Collect tab — target entry (manual ║
// ║  + CSV), plugin selection, output   ║
// ║  path config, quickair-collect://   ║
// ║  URI generation                     ║
// ╠══════════════════════════════════════╣
// ║  Reads    : nothing                  ║
// ║  Writes   : _colTargets              ║
// ║  Functions: renderCollect,           ║
// ║    colAddTarget, colRemoveTarget,    ║
// ║    colClearTargets, colImportCSV,    ║
// ║    colCollect, colToggleSection,     ║
// ║    colUpdateOutputPath              ║
// ║  Depends  : 03_core.js              ║
// ║  Version  : 1.01                     ║
// ╚══════════════════════════════════════╝

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
    '.col-tooltip{display:none;position:absolute;bottom:calc(100% + 6px);left:0;background:var(--bg);color:var(--fg);border:1px solid var(--border);border-radius:4px;padding:8px 10px;font-size:11px;white-space:pre-line;width:260px;z-index:100;box-shadow:0 2px 8px rgba(0,0,0,0.3)}',
    '.col-tooltip-wrap:hover .col-tooltip{display:block}',
    '.col-empty{color:var(--muted);font-style:italic;padding:8px 0;font-size:12px}'
  ].join('');
  document.head.appendChild(s);
})();

var _colTargets = [];
var _colDefaultOutput = '.\\DFIROutput\\';
var _colPlugins = ['Processes', 'Network', 'DLLs', 'Users'];

function renderCollect() {
  var panel = el('panel-collect');
  if (!panel) return;

  var bannerHtml = renderSetupBanner('collect');

  var targetRows = '';
  if (_colTargets.length === 0) {
    targetRows = '<tr><td colspan="3" class="col-empty">No targets added yet.</td></tr>';
  } else {
    for (var i = 0; i < _colTargets.length; i++) {
      targetRows += '<tr>' +
        '<td>' + esc(_colTargets[i].hostname) + '</td>' +
        '<td><input type="text" id="col-op-' + i + '" value="' + esc(_colTargets[i].outputPath) + '" onchange="colUpdateOutputPath(' + i + ',this.value)"></td>' +
        '<td><button class="col-remove-btn" onclick="colRemoveTarget(' + i + ')" title="Remove">&times;</button></td>' +
        '</tr>';
    }
  }

  var pluginChecks = '';
  for (var p = 0; p < _colPlugins.length; p++) {
    pluginChecks += '<li><input type="checkbox" id="col-plug-' + p + '" checked> ' + esc(_colPlugins[p]) + '</li>';
  }

  var collectDisabled = _colTargets.length === 0 ? ' disabled' : '';

  panel.innerHTML = bannerHtml +
    // ── Section 1: Add Targets ──
    '<div class="col-section">' +
      '<div class="col-section-hdr" onclick="colToggleSection(\'col-sec1-body\',\'col-sec1-arrow\')">' +
        '<span class="col-sec-arrow" id="col-sec1-arrow">&#9660;</span>Add Targets' +
        '<span class="col-count">(' + _colTargets.length + ' target' + (_colTargets.length !== 1 ? 's' : '') + ')</span>' +
      '</div>' +
      '<div class="col-section-body" id="col-sec1-body">' +
        '<div class="col-input-row">' +
          '<input type="text" id="col-hostname" placeholder="Hostname or IP" onkeydown="if(event.key===\'Enter\')colAddTarget()">' +
          '<button class="col-btn" onclick="colAddTarget()">+ Add</button>' +
          '<span style="margin-left:12px">' +
            '<div class="col-tooltip-wrap">' +
              '<button class="col-btn" onclick="document.getElementById(\'col-csv-input\').click()">Import CSV</button>' +
              '<div class="col-tooltip">CSV format:\nSimple: one hostname or IP per line\nAdvanced: Hostname,OutputPath columns\nLines starting with # are ignored</div>' +
            '</div>' +
          '</span>' +
          '<input type="file" id="col-csv-input" accept=".csv,.txt" style="display:none" onchange="colImportCSV(this.files)">' +
        '</div>' +
        '<div id="col-import-msg"></div>' +
        '<table class="col-target-tbl">' +
          '<thead><tr><th>Hostname / IP</th><th>Output Path</th><th></th></tr></thead>' +
          '<tbody>' + targetRows + '</tbody>' +
        '</table>' +
        (_colTargets.length > 0 ? '<div style="margin-top:6px"><button class="col-btn col-btn-danger" onclick="colClearTargets()">Clear All</button></div>' : '') +
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
  if (/\s/.test(val)) {
    if (msgEl) msgEl.innerHTML = '<div class="col-msg col-msg-warn">Invalid: hostname cannot contain spaces.</div>';
    return;
  }
  // Deduplicate
  for (var i = 0; i < _colTargets.length; i++) {
    if (_colTargets[i].hostname.toLowerCase() === val.toLowerCase()) {
      if (msgEl) msgEl.innerHTML = '<div class="col-msg col-msg-warn">"' + esc(val) + '" is already in the list.</div>';
      return;
    }
  }
  _colTargets.push({ hostname: val, outputPath: _colDefaultOutput });
  inp.value = '';
  if (msgEl) msgEl.innerHTML = '';
  renderCollect();
  var ri = el('col-hostname');
  if (ri) ri.focus();
}

function colRemoveTarget(idx) {
  _colTargets.splice(idx, 1);
  renderCollect();
}

function colClearTargets() {
  _colTargets = [];
  renderCollect();
}

function colUpdateOutputPath(idx, val) {
  if (_colTargets[idx]) _colTargets[idx].outputPath = val;
}

function colImportCSV(files) {
  if (!files || !files.length) return;
  var reader = new FileReader();
  reader.onload = function(e) {
    var text = e.target.result;
    var lines = text.split(/\r?\n/);
    var added = 0;
    var invalid = [];
    var dupes = 0;

    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim();
      if (!line || line.charAt(0) === '#') continue;

      var hostname = '';
      var outPath = _colDefaultOutput;

      // Check for CSV with comma
      var commaIdx = line.indexOf(',');
      if (commaIdx > 0) {
        hostname = line.substring(0, commaIdx).trim();
        var rest = line.substring(commaIdx + 1).trim();
        if (rest) outPath = rest;
      } else {
        hostname = line;
      }

      // Skip header row
      if (hostname.toLowerCase() === 'hostname') continue;

      // Validate
      if (/\s/.test(hostname) || !hostname) {
        invalid.push(line);
        continue;
      }

      // Deduplicate
      var exists = false;
      for (var j = 0; j < _colTargets.length; j++) {
        if (_colTargets[j].hostname.toLowerCase() === hostname.toLowerCase()) {
          exists = true;
          dupes++;
          break;
        }
      }
      if (!exists) {
        _colTargets.push({ hostname: hostname, outputPath: outPath });
        added++;
      }
    }

    var msgParts = [];
    if (added > 0) msgParts.push(added + ' target' + (added !== 1 ? 's' : '') + ' imported');
    if (dupes > 0) msgParts.push(dupes + ' duplicate' + (dupes !== 1 ? 's' : '') + ' skipped');

    renderCollect();

    var msgEl = el('col-import-msg');
    if (msgEl) {
      var html = '';
      if (msgParts.length > 0) html += '<div class="col-msg col-msg-success">' + msgParts.join(', ') + '.</div>';
      if (invalid.length > 0) html += '<div class="col-msg col-msg-warn">Invalid entries (' + invalid.length + '): ' + invalid.map(function(l) { return esc(l); }).join(', ') + '</div>';
      msgEl.innerHTML = html;
    }

    // Reset file input so same file can be re-imported
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
    var msgEl = el('col-import-msg');
    if (msgEl) msgEl.innerHTML = '<div class="col-msg col-msg-warn">Select at least one plugin before collecting.</div>';
    return;
  }

  var globalOut = (el('col-global-output') || {}).value || _colDefaultOutput;

  var targets = _colTargets.map(function(t) {
    return {
      hostname: t.hostname,
      outputPath: t.outputPath || globalOut,
      plugins: selectedPlugins
    };
  });

  var encoded = encodeURIComponent(btoa(JSON.stringify(targets)));
  var maxC = parseInt((el('col-max-concurrent') || {}).value, 10) || 5;
  if (maxC < 1) maxC = 1; if (maxC > 20) maxC = 20;
  var uri = 'quickair-collect://collect?targets=' + encoded + '&maxConcurrent=' + maxC;

  // URI log removed — contains sensitive target data
  var ifr = document.createElement('iframe');
  ifr.style.display = 'none';
  ifr.src = uri;
  document.body.appendChild(ifr);
  setTimeout(function(){ document.body.removeChild(ifr); }, 2000);

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
