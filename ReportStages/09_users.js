// ╔══════════════════════════════════════╗
// ║  Quicker — 09_users.js               ║
// ║  Users tab render, cross-host user   ║
// ║  correlation by SID, per-user        ║
// ║  expandable machine list, DC data    ║
// ║  enrichment, first-login confidence  ║
// ╠══════════════════════════════════════╣
// ║  Reads    : window.userIndex,         ║
// ║             activeHost.Users          ║
// ║  Writes   : usersData, usersSearch,   ║
// ║             usersTypeFilter,          ║
// ║             usersConfFilter           ║
// ║  Functions: renderUsers, renderUser-  ║
// ║    Row, onUserRowClick, buildUser-    ║
// ║    Expand, usersSortRows, usersApply- ║
// ║    Filters, fmtUTC, confBadge,       ║
// ║    acctTypeBadge, usersGetFirstLogon, ║
// ║    usersGetLastLogon, usersGetBest-   ║
// ║    Conf                               ║
// ║  Depends  : 03_core.js               ║
// ║  Version  : 3.39                      ║
// ╚══════════════════════════════════════╝

// ── USERS TAB ──────────────────────────────────────────────────────────────────
// Unified table — one row per unique SID, cross-host correlation via userIndex.

let usersSearch    = '';
let usersTypeFilter= 'All';
let usersConfFilter= 'All';
let usersNoDcFilter= false;
let usersData      = [];

// ── Constants ─────────────────────────────────────────────────────────────────
const CONF_ORDER = { HIGH: 0, MEDIUM: 1, LOW: 2, '?': 3, 'N/A': 4 };

const CONF_BADGE = {
  HIGH:   '<span style="color:var(--green)">&#10003; HIGH</span>',
  MEDIUM: '<span style="color:var(--amber)">~ MEDIUM</span>',
  LOW:    '<span style="color:var(--muted)">? LOW</span>',
  '?':    '<span style="color:var(--amber)">? ?</span>',
  'N/A':  '<span style="color:var(--muted)">&#8212;</span>',
};

const USER_TIPS = {
  FirstLogon:      'Earliest first logon across all machines. Source: best available of \u2014 profile folder CreationTime, NTUSER.DAT CreationTime, ProfileList registry key LastWrite time.',
  LastLogon:       'Most recent logon across all machines. Source: ProfileList LastUseTime value. Updated on each logoff.',
  WhenCreated:     'Source: Active Directory whenCreated attribute. Set when account was created on DC. Only available when DC JSON is loaded.',
  WhenCreatedDC:   'Source: AD whenCreated attribute. Accurate \u2014 set once at account creation.',
  LastLogonAD:     'Source: AD lastLogonTimestamp. Warning: replicates every 9\u201314 days. May be stale by up to 14 days.',
  PasswordLastSet: 'Source: AD pwdLastSet attribute.',
  IsLoaded:        'ProfileList State flag (1 = currently loaded)',
  SID:             'S-1-5-21-<machine>-* = local account\nS-1-5-21-<domain>-* = domain account',
  Confidence:      'Cross-check of three sources:\n1. Profile folder CreationTime\n2. NTUSER.DAT CreationTime\n3. ProfileList registry key LastWrite\nHIGH=all agree  MEDIUM=two agree  LOW=one source  ?=none agree',
};

const UCOLS = '160px 100px 130px 110px 130px 110px 100px';

// ── Helpers ───────────────────────────────────────────────────────────────────
function confBadge(c)  { return CONF_BADGE[c] || '<span>' + esc(c || '?') + '</span>'; }
function fmtUTC(s) {
  if (!s) return '<span style="color:var(--muted)">&#8212;</span>';
  try {
    const d = new Date(s);
    if (isNaN(d)) return '<span style="color:var(--muted)">&#8212;</span>';
    const pad = n => String(n).padStart(2, '0');
    return esc(d.getUTCFullYear() + '-' +
      pad(d.getUTCMonth() + 1) + '-' +
      pad(d.getUTCDate()) + ' ' +
      pad(d.getUTCHours()) + ':' +
      pad(d.getUTCMinutes()) + ':' +
      pad(d.getUTCSeconds()) + ' UTC');
  } catch(e) { return '<span style="color:var(--muted)">&#8212;</span>'; }
}

function acctTypeBadge(t) {
  const styles = {
    Local:   'background:var(--muted);color:var(--bg)',
    Domain:  'background:var(--accent);color:var(--bg)',
    System:  'background:var(--border);color:var(--text)',
    Service: 'background:var(--border);color:var(--text)',
  };
  const s = styles[t] || 'background:var(--border);color:var(--text)';
  return '<span style="' + s + ';padding:1px 5px;border-radius:3px;font-size:10px">' + esc(t || '?') + '</span>';
}

function usersGetFirstLogon(u) {
  let best = null;
  u.machines.forEach(m => {
    if (!m.FirstLogon || !m.FirstLogon.UTC) return;
    if (!best || m.FirstLogon.UTC < best.UTC) best = m.FirstLogon;
  });
  return best;
}

function usersGetLastLogon(u) {
  let best = null;
  u.machines.forEach(m => {
    if (!m.LastLogon) return;
    if (!best || m.LastLogon > best) best = m.LastLogon;
  });
  return best;
}

function usersGetBestConf(u) {
  let best = 'N/A';
  u.machines.forEach(m => {
    const c = m.FirstLogon ? (m.FirstLogon.Confidence || 'N/A') : 'N/A';
    if ((CONF_ORDER[c] ?? 99) < (CONF_ORDER[best] ?? 99)) best = c;
  });
  return best;
}

// ── Sort ──────────────────────────────────────────────────────────────────────
function usersSortRows(rows) {
  if (!sortState.tab || sortState.tab !== 'users' || sortState.dir === 'none') return rows;
  const dir = sortState.dir === 'asc' ? 1 : -1;
  const col = sortState.column;
  return rows.slice().sort((a, b) => {
    let av, bv;
    switch (col) {
      case 'username':   av = str(a.Username); bv = str(b.Username); break;
      case 'acctType':   av = str(a.AccountType); bv = str(b.AccountType); break;
      case 'domain':     av = str(a.Domain); bv = str(b.Domain); break;
      case 'dcCreated':
        av = a.domainInfo ? (a.domainInfo.WhenCreated || '') : '';
        bv = b.domainInfo ? (b.domainInfo.WhenCreated || '') : ''; break;
      case 'firstLogin': {
        const af = usersGetFirstLogon(a); const bf = usersGetFirstLogon(b);
        av = af ? af.UTC : ''; bv = bf ? bf.UTC : ''; break;
      }
      case 'lastLogin':  av = usersGetLastLogon(a) || ''; bv = usersGetLastLogon(b) || ''; break;
      case 'confidence': {
        const ao = CONF_ORDER[usersGetBestConf(a)] ?? 99;
        const bo = CONF_ORDER[usersGetBestConf(b)] ?? 99;
        return (ao - bo) * dir;
      }
      default: av = ''; bv = '';
    }
    if (av == null && bv == null) return 0;
    if (av == null) return dir;
    if (bv == null) return -dir;
    return String(av).localeCompare(String(bv)) * dir;
  });
}

// ── Filter + render ───────────────────────────────────────────────────────────
function usersApplyFilters() {
  const idx = window.userIndex || {};
  const lq  = usersSearch.toLowerCase();

  let rows = Object.values(idx).filter(u => {
    if (lq && !str(u.Username).toLowerCase().includes(lq) &&
              !str(u.Domain).toLowerCase().includes(lq) &&
              !str(u.SID).toLowerCase().includes(lq)) return false;
    if (usersTypeFilter !== 'All' && u.AccountType !== usersTypeFilter) return false;
    if (usersConfFilter !== 'All' && usersGetBestConf(u) !== usersConfFilter) return false;
    if (usersNoDcFilter) {
      if (u.AccountType !== 'Domain') return false;
      if (u.domainInfo) return false;
    }
    return true;
  });

  if (sortState.tab !== 'users' || sortState.dir === 'none') {
    rows.sort((a, b) => str(a.Username).localeCompare(str(b.Username)));
  } else {
    rows = usersSortRows(rows);
  }
  usersData = rows;

  const cnt = el('users-count');
  if (cnt) cnt.textContent = rows.length + ' users';

  if (state.vsInstances['users']) {
    state.vsInstances['users'].update(rows);
  } else {
    state.vsInstances['users'] = createVS('users-vs', UCOLS, rows, renderUserRow, onUserRowClick, 'users');
  }
}

// ── Main render ───────────────────────────────────────────────────────────────
function renderUsers() {
  const panel = el('panel-users');
  if (!panel) return;

  const hasAnyUsers = Object.values(state.hosts).some(h => h.Users);
  if (!hasAnyUsers) {
    panel.innerHTML = '<div class="solo-notice">Load a JSON file to see user data.</div>';
    return;
  }

  const hasUsersData = Object.values(state.hosts).some(h => h.Users && h.Users.users && h.Users.users.length > 0);
  if (!hasUsersData) {
    panel.innerHTML = '<div class="solo-notice">No user data in this JSON.</div>';
    return;
  }

  // DC banner: domain users present but no DC JSON loaded
  const idx = window.userIndex || {};
  const hasDomainUsers = Object.values(idx).some(u => u.AccountType === 'Domain');
  const hasDcLoaded    = Object.values(state.hosts).some(h => h.Users && h.Users.is_domain_controller);
  const showDcBanner   = hasDomainUsers && !hasDcLoaded;

  panel.innerHTML = (showDcBanner ? `
    <div style="background:rgba(255,180,0,0.1);border:1px solid var(--amber);border-radius:4px;padding:7px 12px;margin-bottom:8px;font-size:12px;color:var(--amber)">
      Load DC JSON to see account creation dates</div>` : '') + `
    <div class="filter-bar" style="margin-bottom:8px;display:flex;align-items:center;gap:8px;flex-wrap:wrap">
      <input type="text" id="users-search" value="${esc(usersSearch)}" placeholder="Search username, domain, SID\u2026" style="width:240px"
             oninput="usersSearch=this.value;usersApplyFilters()">
      <select id="users-type-filter" onchange="usersTypeFilter=this.value;usersApplyFilters()">
        <option value="All">All Types</option>
        <option value="Local">Local</option>
        <option value="Domain">Domain</option>
        <option value="System">System</option>
        <option value="Service">Service</option>
      </select>
      <select id="users-conf-filter" onchange="usersConfFilter=this.value;usersApplyFilters()">
        <option value="All">All Confidence</option>
        <option value="HIGH">HIGH</option>
        <option value="MEDIUM">MEDIUM</option>
        <option value="LOW">LOW</option>
        <option value="?">?</option>
      </select>
      <label style="font-size:12px;cursor:pointer">
        <input type="checkbox" id="users-nodc-filter" ${usersNoDcFilter?'checked':''} onchange="usersNoDcFilter=this.checked;usersApplyFilters()">
        No DC data
      </label>
      <span id="users-count" style="color:var(--muted);font-size:11px;margin-left:4px"></span>
    </div>
    <div class="tbl-wrap">
      <div class="tbl-header" style="grid-template-columns:${UCOLS}" id="users-header">
        <div class="th sortable-th" onclick="sortTable('users','username',false)">Username <span class="sort-arrow" id="sort-users-username">&#8645;</span></div>
        <div class="th sortable-th" onclick="sortTable('users','acctType',false)">Account Type <span class="sort-arrow" id="sort-users-acctType">&#8645;</span></div>
        <div class="th sortable-th" onclick="sortTable('users','domain',false)">Domain <span class="sort-arrow" id="sort-users-domain">&#8645;</span></div>
        <div class="th sortable-th" title="${esc(USER_TIPS.WhenCreated)}" onclick="sortTable('users','dcCreated',false)">Created (DC) <span class="sort-arrow" id="sort-users-dcCreated">&#8645;</span></div>
        <div class="th sortable-th" title="${esc(USER_TIPS.FirstLogon)}" onclick="sortTable('users','firstLogin',false)">First Login <span class="sort-arrow" id="sort-users-firstLogin">&#8645;</span></div>
        <div class="th sortable-th" title="${esc(USER_TIPS.LastLogon)}" onclick="sortTable('users','lastLogin',false)">Last Login <span class="sort-arrow" id="sort-users-lastLogin">&#8645;</span></div>
        <div class="th sortable-th" title="${esc(USER_TIPS.Confidence)}" onclick="sortTable('users','confidence',false)">Confidence <span class="sort-arrow" id="sort-users-confidence">&#8645;</span></div>
      </div>
      <div id="users-vs"></div>
    </div>`;

  // Restore filter dropdowns state
  const typeSel = el('users-type-filter');
  if (typeSel) typeSel.value = usersTypeFilter;
  const confSel = el('users-conf-filter');
  if (confSel) confSel.value = usersConfFilter;

  state.vsInstances['users'] = null;
  usersApplyFilters();
  setTimeout(() => addResizeHandles('users-header', 'users'), 0);
}

// ── Row render ────────────────────────────────────────────────────────────────
function renderUserRow(u) {
  const bestConf = usersGetBestConf(u);
  const fl       = usersGetFirstLogon(u);
  const lastLogon= usersGetLastLogon(u);
  const dcDate   = u.domainInfo ? fmtUTC(u.domainInfo.WhenCreated) : (
    u.AccountType === 'Local'
      ? '<span style="color:var(--muted)" title="Local accounts have no AD creation date">?</span>'
      : '<span style="color:var(--muted)">&#8212;</span>'
  );

  let firstLoginCell;
  if (fl) {
    firstLoginCell = fmtUTC(fl.UTC) + ' ' + confBadge(fl.Confidence);
  } else {
    firstLoginCell = '<span style="color:var(--muted)">&#8212;</span>';
  }

  return `
    <div class="td mono" title="${esc(USER_TIPS.SID)}\nSID: ${esc(u.SID)}">${esc(u.Username || u.SID)}</div>
    <div class="td">${acctTypeBadge(u.AccountType)}</div>
    <div class="td dim">${esc(u.Domain || '&#8212;')}</div>
    <div class="td dim" title="${esc(USER_TIPS.WhenCreated)}">${dcDate}</div>
    <div class="td dim" title="${esc(USER_TIPS.FirstLogon)}">${firstLoginCell}</div>
    <div class="td dim" title="${esc(USER_TIPS.LastLogon)}">${fmtUTC(lastLogon)}</div>
    <div class="td">${confBadge(bestConf)}</div>`;
}

// ── Row click ─────────────────────────────────────────────────────────────────
function onUserRowClick(i, u, rowEl) {
  const vs   = state.vsInstances['users'];
  const prev = state.expandedRows['users'];
  if (prev === i) { state.expandedRows['users'] = null; if (vs) vs.collapse(); return; }
  state.expandedRows['users'] = i;

  const expand = document.createElement('div');
  expand.innerHTML = buildUserExpand(u);
  if (vs) vs.expand(i, expand);
}

// ── Row expand ────────────────────────────────────────────────────────────────
function buildUserExpand(u) {
  let html = '<div style="padding:10px 14px">';

  // ── SECTION 1: IDENTITY ──
  html += `
    <h4 style="margin:0 0 6px">Identity</h4>
    <div class="kv-grid" style="margin-bottom:12px">
      <span class="k" title="${esc(USER_TIPS.SID)}">SID</span>
        <span class="v mono" style="font-size:11px;cursor:pointer" onclick="navigator.clipboard&&navigator.clipboard.writeText('${esc(u.SID)}')" title="Click to copy">${esc(u.SID)}</span>
      <span class="k">Account Type</span>
        <span class="v">${acctTypeBadge(u.AccountType)}</span>
      <span class="k">Domain</span>
        <span class="v">${esc(u.Domain || '&#8212;')}</span>`;

  if (u.SIDMetadata && u.SIDMetadata.WellKnown) {
    html += `
      <span class="k">Well-Known</span>
        <span class="v" style="color:var(--amber)">${esc(u.SIDMetadata.Description)}</span>`;
  }
  if (u.HasLocalAccount) {
    const disStr = u.LocalDisabled === true ? ' <span style="color:var(--amber)">(disabled)</span>' : '';
    html += `
      <span class="k">Local Account</span>
        <span class="v" style="color:var(--green)">&#10003; exists${disStr}</span>`;
  }
  html += '</div>';

  // ── SECTION 2: DOMAIN INFO ──
  if (u.domainInfo) {
    const di  = u.domainInfo;
    const src = di.Source || '?';
    const srcColor = src === 'Get-ADUser' ? 'var(--green)' : 'var(--accent)';
    html += `
      <h4 style="margin:0 0 6px">Domain Info
        <span style="background:rgba(0,0,0,.3);border:1px solid var(--border);padding:1px 6px;border-radius:3px;font-size:10px;color:${srcColor};margin-left:8px">${esc(src)}</span>
        <span style="color:var(--muted);font-size:11px;margin-left:6px">From DC: ${esc(di.dcHost)}</span>
      </h4>
      <div class="kv-grid" style="margin-bottom:12px">
        <span class="k" title="${esc(USER_TIPS.WhenCreatedDC)}">Created</span>
          <span class="v" title="${esc(USER_TIPS.WhenCreatedDC)}">${fmtUTC(di.WhenCreated)}</span>
        <span class="k" title="${esc(USER_TIPS.LastLogonAD)}">Last Logon (AD)</span>
          <span class="v" title="${esc(USER_TIPS.LastLogonAD)}">${fmtUTC(di.LastLogonAD)}</span>
        <span class="k" title="${esc(USER_TIPS.PasswordLastSet)}">Password Last Set</span>
          <span class="v" title="${esc(USER_TIPS.PasswordLastSet)}">${fmtUTC(di.PasswordLastSet)}</span>
        <span class="k">Enabled</span>
          <span class="v" style="color:${di.Enabled?'var(--green)':'var(--red)'}">${di.Enabled ? '&#10003;' : '&#10007;'}</span>
        <span class="k">Locked Out</span>
          <span class="v" style="color:${di.LockedOut?'var(--red)':'var(--muted)'}">${di.LockedOut ? 'YES' : '&#8212;'}</span>
        <span class="k">Bad Logon Count</span>
          <span class="v" style="color:${(di.BadLogonCount>0)?'var(--amber)':'var(--muted)'}">${di.BadLogonCount || 0}</span>
      </div>`;
  } else if (u.AccountType === 'Domain') {
    html += `
      <div style="background:rgba(255,180,0,.08);border:1px solid var(--amber);border-radius:4px;padding:7px 10px;margin-bottom:12px;font-size:12px;color:var(--amber)">
        No DC data &#8212; load DC JSON to see account creation date</div>`;
  } else if (u.AccountType === 'Local') {
    html += `
      <div style="background:var(--surface);border:1px solid var(--border);border-radius:4px;padding:7px 10px;margin-bottom:12px;font-size:12px;color:var(--muted)">
        Local account &#8212; no AD data available</div>`;
  }

  // ── SECTION 3: MACHINE APPEARANCES ──
  if (u.machines.length > 0) {
    html += `
      <h4 style="margin:0 0 6px">Machine Appearances (${u.machines.length})</h4>
      <table class="expand-tbl" style="margin-bottom:10px">
        <tr>
          <th>Machine</th>
          <th title="${esc(USER_TIPS.FirstLogon)}">First Login</th>
          <th title="${esc(USER_TIPS.Confidence)}">Confidence</th>
          <th title="${esc(USER_TIPS.LastLogon)}">Last Login</th>
          <th>Profile Path</th>
          <th title="${esc(USER_TIPS.IsLoaded)}">Loaded</th>
        </tr>`;

    u.machines.forEach(m => {
      const fl  = m.FirstLogon || {};
      const pf  = fl.ProfileFolder || {};
      const nt  = fl.NTUserDat || {};
      const rk  = fl.RegistryKey || {};
      const tip = 'Profile folder CreationTime:\n  ' + (pf.Value || 'N/A') +
                  '\nNTUSER.DAT CreationTime:\n  ' + (nt.Value || 'N/A') +
                  '\nProfileList key LastWrite\n  (' + (rk.KeyPath || 'HKLM\\...\\ProfileList\\<SID>') + '):\n  ' + (rk.Value || 'N/A') +
                  '\nConfidence: ' + (fl.Confidence || '?');
      const lastTip = 'Source: ProfileList LastUseTime.\nPath: HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\ProfileList\\' + (u.SID || '<SID>') + '\\LastUseTime\nUpdated on each logoff.';
      const profPathFull = m.ProfilePath || '';
      const profPathShort= profPathFull.length > 38 ? '&#8230;' + esc(profPathFull.slice(-36)) : esc(profPathFull || '&#8212;');

      html += `<tr>
        <td>${esc(m.hostname)}</td>
        <td title="${esc(tip)}">${fl.UTC ? fmtUTC(fl.UTC) : '<span style="color:var(--muted)">&#8212;</span>'} ${confBadge(fl.Confidence)}</td>
        <td title="${esc(USER_TIPS.Confidence)}">${confBadge(fl.Confidence)}</td>
        <td title="${esc(lastTip)}">${fmtUTC(m.LastLogon)}</td>
        <td class="mono" style="font-size:10px" title="${esc(profPathFull)}">${profPathShort}</td>
        <td style="text-align:center">${m.IsLoaded ? '<span style="color:var(--green)">&#10003;</span>' : '<span style="color:var(--muted)">&#8212;</span>'}</td>
      </tr>`;

      if (fl.TimestampMismatch) {
        html += `<tr><td colspan="6" style="color:var(--amber);font-size:11px">? Timestamp mismatch across sources</td></tr>`;
      }
    });

    html += '</table>';
  }

  html += '</div>';
  return html;
}
