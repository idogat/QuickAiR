// ── USERS TAB ──────────────────────────────────────────────────────────────────
// Cross-host user correlation. Reads window.userIndex (built by buildUserIndex).

let usersView  = 'peruser';   // 'peruser' | 'perhost'
let usersSearch= '';
let usersData  = [];          // flat array of userIndex entries for virtual scroll

// ── Field tooltips ────────────────────────────────────────────────────────────
const USER_TIPS = {
  FirstLogon:      "Earliest of: profile folder creation time, NTUSER.DAT creation time, ProfileList registry key write time",
  ProfileFolder:   "Profile folder CreationTime\n(created on first logon, can be modified)",
  NTUserDat:       "NTUSER.DAT CreationTime\n(created with profile on first logon)",
  RegistryKey:     "ProfileList registry key LastWrite time\n(set when profile first registered)",
  LastUseTime:     "ProfileList LastUseTime value\n(updated on each logoff)",
  WhenCreated:     "AD whenCreated attribute\n(set at account creation, DC only)",
  LastLogonAD:     "AD lastLogonTimestamp\n(replicates every 9-14 days, may be stale)",
  IsLoaded:        "ProfileList State value\n(1=currently loaded, 0=not loaded)",
  LogonType:       "Win32_LogonSession LogonType\n2=Interactive 3=Network 4=Batch\n5=Service 7=Unlock 10=RDP 11=Cached",
  SID:             "ProfileList key name (SID)\nS-1-5-21-<machine>-* = local\nS-1-5-21-<domain>-* = domain",
  Confidence:      "Cross-check: profile folder + NTUSER.DAT\n+ registry key\nHIGH=all agree MEDIUM=two agree\nLOW=one source TAMPERED=differ >7 days",
};

const CONF_BADGE = {
  HIGH:     '<span style="color:var(--green)">✓ HIGH</span>',
  MEDIUM:   '<span style="color:var(--amber)">~ MEDIUM</span>',
  LOW:      '<span style="color:var(--muted)">? LOW</span>',
  TAMPERED: '<span style="color:var(--red)">⚠ TAMPERED</span>',
};

function confBadge(c) { return CONF_BADGE[c] || `<span>${esc(c||'?')}</span>`; }
function fmtDate(s)   { if (!s) return '<span style="color:var(--muted)">—</span>'; return esc(s.slice(0,10)); }
function fmtTs(s)     { if (!s) return '—'; return s.slice(0,19).replace('T',' '); }

// ── MAIN RENDER ───────────────────────────────────────────────────────────────
function renderUsers() {
  const panel = el('panel-users');
  if (!panel) return;

  const hasAnyUsers = Object.values(state.hosts).some(h => h.Users);
  if (!hasAnyUsers) {
    panel.innerHTML = '<div class="solo-notice">No Users data loaded.</div>';
    return;
  }

  panel.innerHTML = `
    <div class="filter-bar" style="margin-bottom:10px">
      <button id="users-btn-peruser" ${usersView==='peruser'?'class="active"':''} onclick="usersSetView('peruser')">Per User</button>
      <button id="users-btn-perhost" ${usersView==='perhost'?'class="active"':''} onclick="usersSetView('perhost')">Per Host</button>
      <span class="sep">|</span>
      <input type="text" id="users-search" value="${esc(usersSearch)}" placeholder="Search username, SID, group…" style="width:280px"
             oninput="usersSearch=this.value;usersApplyFilters()">
      <span id="users-count" style="color:var(--muted);font-size:11px;margin-left:8px"></span>
    </div>
    <div id="users-view-container"></div>`;

  usersApplyFilters();
  setTimeout(() => addResizeHandles('users-header', 'users'), 0);
}

function usersSetView(v) {
  usersView = v;
  el('users-btn-peruser').classList.toggle('active', v === 'peruser');
  el('users-btn-perhost').classList.toggle('active', v === 'perhost');
  usersApplyFilters();
  setTimeout(() => addResizeHandles('users-header', 'users'), 0);
}

function usersApplyFilters() {
  const container = el('users-view-container');
  if (!container) return;
  if (usersView === 'perhost') { renderUsersPerHost(container); return; }
  renderUsersPerUser(container);
}

// ── PER USER VIEW ─────────────────────────────────────────────────────────────
const UCOLS = '160px 100px 120px 70px 120px 120px 80px 90px 70px';

function renderUsersPerUser(container) {
  const idx = window.userIndex || {};
  const lq  = usersSearch.toLowerCase();

  let rows = Object.values(idx).filter(u => {
    if (!lq) return true;
    return (str(u.username).includes(lq) || str(u.SID).includes(lq) ||
            u.groups.some(g => str(g.GroupName).includes(lq)));
  });

  rows.sort((a, b) => str(a.username).localeCompare(str(b.username)));
  usersData = rows;

  const cnt = el('users-count');
  if (cnt) cnt.textContent = rows.length + ' users';

  container.innerHTML = `
    <div class="tbl-wrap">
      <div class="tbl-header" style="grid-template-columns:${UCOLS}" id="users-header">
        <div class="th">Username</div>
        <div class="th">Acct Type</div>
        <div class="th" title="${esc(USER_TIPS.WhenCreated)}">Created (DC)</div>
        <div class="th">Hosts</div>
        <div class="th" title="${esc(USER_TIPS.FirstLogon)}">First Seen</div>
        <div class="th" title="${esc(USER_TIPS.LastUseTime)}">Last Seen</div>
        <div class="th">Active</div>
        <div class="th">Domain Acct</div>
        <div class="th" title="${esc(USER_TIPS.Confidence)}">Tampered</div>
      </div>
      <div id="users-vs"></div>
    </div>`;

  state.vsInstances['users'] = createVS(
    'users-vs', UCOLS, rows, renderUserRow, onUserRowClick, 'users');
}

function renderUserRow(u) {
  const hasTamper  = u.appearances.some(a => a.TamperedFlag);
  const isActive   = u.sessions.length > 0;
  const isDomDisabled = u.domainAccount && u.domainAccount.Enabled === false;

  let rowClass = '';
  if (hasTamper)    rowClass = 'color:var(--red)';
  else if (isDomDisabled && u.appearances.length > 0) rowClass = 'color:var(--amber)';
  else if (isActive) rowClass = 'color:var(--green)';

  const acctType = u.appearances.length > 0 ? (u.appearances[0].AccountType || '—') : '—';
  const dcCreated= u.domainAccount ? fmtDate(u.domainAccount.WhenCreated) : '<span style="color:var(--muted)">—</span>';
  const hostCount= u.appearances.length;
  const firstSeen= u.appearances.reduce((best, a) => {
    if (!a.FirstLogon || !a.FirstLogon.UTC) return best;
    return (!best || a.FirstLogon.UTC < best) ? a.FirstLogon.UTC : best;
  }, null);
  const lastSeen = u.appearances.reduce((best, a) => {
    if (!a.LastLogon) return best;
    return (!best || a.LastLogon > best) ? a.LastLogon : best;
  }, null);

  return `
    <div class="td mono" style="${rowClass}" title="${esc(USER_TIPS.SID)}\nSID: ${esc(u.SID)}">${esc(u.username||u.SID)}</div>
    <div class="td dim">${esc(acctType)}</div>
    <div class="td dim" title="${esc(USER_TIPS.WhenCreated)}">${dcCreated}</div>
    <div class="td dim">${hostCount || '<span style="color:var(--muted)">—</span>'}</div>
    <div class="td dim" title="${esc(USER_TIPS.FirstLogon)}">${fmtDate(firstSeen)}</div>
    <div class="td dim" title="${esc(USER_TIPS.LastUseTime)}">${fmtDate(lastSeen)}</div>
    <div class="td">${isActive ? '<span style="color:var(--green)">yes</span>' : '<span style="color:var(--muted)">—</span>'}</div>
    <div class="td dim">${u.domainAccount ? '<span style="color:var(--accent)">yes</span>' : '<span style="color:var(--muted)">—</span>'}</div>
    <div class="td">${hasTamper ? '<span style="color:var(--red)">⚠</span>' : '<span style="color:var(--muted)">—</span>'}</div>`;
}

function onUserRowClick(i, u, rowEl) {
  const vs   = state.vsInstances['users'];
  const prev = state.expandedRows['users'];
  if (prev === i) { state.expandedRows['users'] = null; if (vs) vs.collapse(); return; }
  state.expandedRows['users'] = i;

  const expand = document.createElement('div');
  expand.innerHTML = buildUserExpand(u);
  if (vs) vs.expand(i, expand);
}

function buildUserExpand(u) {
  let html = '';

  // ── Section 1: Domain account ──
  if (u.domainAccount) {
    const da = u.domainAccount;
    const src = da.Source || '?';
    const srcColor = src === 'Get-ADUser' ? 'var(--green)' : 'var(--accent)';
    html += `
      <h4 style="margin-bottom:6px">Domain Account
        <span style="background:rgba(0,0,0,0.3);border:1px solid var(--border);padding:1px 6px;border-radius:3px;font-size:10px;color:${srcColor};margin-left:8px">${esc(src)}</span>
      </h4>
      <div class="kv-grid" style="margin-bottom:10px">
        <span class="k" title="${esc(USER_TIPS.WhenCreated)}">Created</span>
          <span class="v">${esc(fmtTs(da.WhenCreated))}</span>
        <span class="k" title="${esc(USER_TIPS.LastLogonAD)}">Last Logon (AD)</span>
          <span class="v">${esc(fmtTs(da.LastLogon))}</span>
        <span class="k">Password Last Set</span>
          <span class="v">${esc(fmtTs(da.PasswordLastSet))}</span>
        <span class="k">Enabled</span>
          <span class="v" style="color:${da.Enabled?'var(--green)':'var(--red)'}">${da.Enabled?'yes':'no'}</span>
        <span class="k">Locked Out</span>
          <span class="v" style="color:${da.LockedOut?'var(--red)':'var(--muted)'}">${da.LockedOut?'YES':'no'}</span>
        <span class="k">Bad Logon Count</span>
          <span class="v" style="color:${(da.BadLogonCount>0)?'var(--amber)':'var(--muted)'}">${da.BadLogonCount||0}</span>
        <span class="k">DC Host</span>
          <span class="v">${esc(da.host)}</span>
      </div>`;
  }

  // ── Section 2: Appearances per host ──
  if (u.appearances.length > 0) {
    html += `<h4 style="margin-bottom:6px">Profile Appearances (${u.appearances.length} host${u.appearances.length!==1?'s':''})</h4>
      <table class="expand-tbl" style="margin-bottom:10px">
        <tr>
          <th>Host</th><th title="${esc(USER_TIPS.FirstLogon)}">First Logon</th>
          <th title="${esc(USER_TIPS.Confidence)}">Confidence</th>
          <th title="${esc(USER_TIPS.LastUseTime)}">Last Logon</th>
          <th>Profile Path</th><th title="${esc(USER_TIPS.IsLoaded)}">Loaded</th>
        </tr>`;
    u.appearances.forEach(a => {
      const fl  = a.FirstLogon || {};
      const tip = fl.ProfileFolder || fl.NTUserDat || fl.RegistryKey
        ? `Profile folder: ${fl.ProfileFolder ? fl.ProfileFolder.UTC||'?' : 'N/A'}\nNTUSER.DAT:     ${fl.NTUserDat ? fl.NTUserDat.UTC||'?' : 'N/A'}\nRegistry key:   ${fl.RegistryKey ? fl.RegistryKey.UTC||'?' : 'N/A'}\nConfidence:     ${fl.Confidence||'?'}`
        : '';
      const pfVal = fl.ProfileFolder ? (fl.ProfileFolder.Value || fl.ProfileFolder.UTC) : null;
      const ntVal = fl.NTUserDat    ? (fl.NTUserDat.Value    || fl.NTUserDat.UTC)    : null;
      const rkVal = fl.RegistryKey  ? (fl.RegistryKey.Value  || fl.RegistryKey.UTC)  : null;
      const srcRow = (pfVal || ntVal || rkVal) ? `
        <tr><td colspan="6" style="padding:1px 8px 5px 8px;font-size:11px;color:var(--muted)">
          <span title="${esc(USER_TIPS.ProfileFolder)}">ProfileFolder: <span style="color:${pfVal?'var(--text)':'var(--red)'}">${pfVal ? esc(pfVal.slice(0,19).replace('T',' ')) : 'null'}</span></span>
          &nbsp;&nbsp;
          <span title="${esc(USER_TIPS.NTUserDat)}">NTUserDat: <span style="color:${ntVal?'var(--text)':'var(--red)'}">${ntVal ? esc(ntVal.slice(0,19).replace('T',' ')) : 'null'}</span></span>
          &nbsp;&nbsp;
          <span title="${esc(USER_TIPS.RegistryKey)}">RegistryKey: <span style="color:${rkVal?'var(--text)':'var(--red)'}">${rkVal ? esc(rkVal.slice(0,19).replace('T',' ')) : 'null'}</span></span>
        </td></tr>` : '';
      html += `<tr>
        <td>${esc(a.host)}</td>
        <td title="${esc(tip)}">${fmtDate(fl.UTC)}</td>
        <td title="${esc(USER_TIPS.Confidence)}">${confBadge(fl.Confidence)}</td>
        <td title="${esc(USER_TIPS.LastUseTime)}">${fmtDate(a.LastLogon)}</td>
        <td class="mono" style="font-size:10px">${esc(a.ProfilePath||'—')}</td>
        <td title="${esc(USER_TIPS.IsLoaded)}">${a.IsLoaded ? '<span style="color:var(--accent)">yes</span>' : '<span style="color:var(--muted)">—</span>'}</td>
      </tr>${srcRow}`;
      if (fl.TamperedFlag) {
        html += `<tr><td colspan="6" style="color:var(--red);font-size:11px">⚠ TAMPERED: ${esc(fl.TamperedNote||'')}</td></tr>`;
      }
    });
    html += '</table>';
  }

  // ── Section 3: Active sessions ──
  if (u.sessions.length > 0) {
    html += `<h4 style="margin-bottom:6px">Active Sessions (${u.sessions.length})</h4>
      <table class="expand-tbl" style="margin-bottom:10px">
        <tr><th>Host</th><th title="${esc(USER_TIPS.LogonType)}">Type</th><th>Type Name</th><th>Logon Time</th><th>Session ID</th></tr>`;
    u.sessions.forEach(s => {
      html += `<tr>
        <td>${esc(s.host)}</td>
        <td title="${esc(USER_TIPS.LogonType)}">${s.LogonType||'—'}</td>
        <td>${esc(s.LogonTypeName||'—')}</td>
        <td>${esc(fmtTs(s.LogonTimeUTC))}</td>
        <td class="mono">${esc(s.SessionId||'—')}</td>
      </tr>`;
    });
    html += '</table>';
  }

  // ── Section 4: Group membership ──
  if (u.groups.length > 0) {
    html += `<h4 style="margin-bottom:6px">Group Membership (${u.groups.length})</h4>
      <table class="expand-tbl" style="margin-bottom:10px">
        <tr><th>Group</th><th>Host</th><th>Local Group</th></tr>`;
    u.groups.forEach(g => {
      html += `<tr>
        <td style="color:var(--amber)">${esc(g.GroupName)}</td>
        <td>${esc(g.host)}</td>
        <td>${g.IsLocal ? '<span style="color:var(--accent)">yes</span>' : '<span style="color:var(--muted)">—</span>'}</td>
      </tr>`;
    });
    html += '</table>';
  }

  if (!html) html = '<div style="color:var(--muted);padding:8px">No detail available.</div>';
  return html;
}

// ── PER HOST VIEW ─────────────────────────────────────────────────────────────
function renderUsersPerHost(container) {
  const lq = usersSearch.toLowerCase();
  let totalRows = 0;

  // Per Host shows selected host only
  const hostname = state.activeHost;
  const hostData = state.hosts[hostname];
  if (!hostData || !hostData.Users) {
    container.innerHTML = '<div class="solo-notice">No Users data for selected host.</div>';
    return;
  }

  let html = '';
  (function() {
    const u = hostData.Users;
    if (!u) return;

    html += `<div style="margin-bottom:20px">
      <div style="padding:6px 12px;background:var(--surface);border:1px solid var(--border);border-radius:4px 4px 0 0;font-size:12px;color:var(--muted)">
        <span style="color:var(--accent)">${esc(hostname)}</span>
        ${u.is_domain_controller ? ' <span style="color:var(--amber);font-size:10px">DC</span>' : ''}
        &nbsp;·&nbsp; domain: ${esc(u.domain_name||'?')}
        &nbsp;·&nbsp; machine_sid: <span class="mono" style="font-size:10px">${esc(u.machine_sid||'?')}</span>
      </div>
      <div style="border:1px solid var(--border);border-top:none;border-radius:0 0 4px 4px;padding:10px 16px">`;

    // Sessions
    const sessions = (u.sessions || []).filter(s => !lq || str(s.Username).includes(lq) || str(s.SID).includes(lq));
    if (sessions.length) {
      html += `<h4 style="margin-bottom:6px">Active Sessions (${sessions.length})</h4>
        <table class="expand-tbl" style="margin-bottom:10px">
          <tr><th>Username</th><th>Domain</th><th title="${esc(USER_TIPS.LogonType)}">Type</th><th>Type Name</th><th>Logon Time</th><th title="${esc(USER_TIPS.SID)}">SID</th></tr>`;
      sessions.forEach(s => {
        html += `<tr>
          <td class="mono">${esc(s.Username||'—')}</td>
          <td>${esc(s.Domain||'—')}</td>
          <td title="${esc(USER_TIPS.LogonType)}">${s.LogonType||'—'}</td>
          <td>${esc(s.LogonTypeName||'—')}</td>
          <td title="${esc(USER_TIPS.LastUseTime)}">${esc(fmtTs(s.LogonTimeUTC))}</td>
          <td class="mono" style="font-size:10px" title="${esc(USER_TIPS.SID)}">${esc(s.SID||'—')}</td>
        </tr>`;
      });
      html += '</table>';
      totalRows += sessions.length;
    }

    // Profiles
    const profiles = (u.profiles || []).filter(p => !lq || str(p.Username).includes(lq) || str(p.SID).includes(lq));
    if (profiles.length) {
      html += `<h4 style="margin-bottom:6px">User Profiles (${profiles.length})</h4>
        <table class="expand-tbl" style="margin-bottom:10px">
          <tr>
            <th>Username</th><th title="${esc(USER_TIPS.SID)}">SID</th><th>Type</th>
            <th title="${esc(USER_TIPS.FirstLogon)}">First Logon</th>
            <th title="${esc(USER_TIPS.Confidence)}">Confidence</th>
            <th title="${esc(USER_TIPS.LastUseTime)}">Last Use</th>
            <th title="${esc(USER_TIPS.IsLoaded)}">Loaded</th>
          </tr>`;
      profiles.forEach(p => {
        const fl = p.FirstLogon || {};
        const tip = `Profile folder: ${fl.ProfileFolder?fl.ProfileFolder.UTC||'?':'N/A'}\nNTUSER.DAT: ${fl.NTUserDat?fl.NTUserDat.UTC||'?':'N/A'}\nRegistry key: ${fl.RegistryKey?fl.RegistryKey.UTC||'?':'N/A'}`;
        const tamperStyle = fl.TamperedFlag ? 'border-left:3px solid var(--red)' : '';
        html += `<tr style="${tamperStyle}">
          <td class="mono">${esc(p.Username||'—')}</td>
          <td class="mono" style="font-size:10px" title="${esc(USER_TIPS.SID)}">${esc(p.SID||'—')}</td>
          <td>${esc(p.AccountType||'—')}</td>
          <td title="${esc(tip)}">${fmtDate(fl.UTC)}</td>
          <td title="${esc(USER_TIPS.Confidence)}">${confBadge(fl.Confidence)}</td>
          <td title="${esc(USER_TIPS.LastUseTime)}">${fmtDate(p.LastUseTimeUTC)}</td>
          <td title="${esc(USER_TIPS.IsLoaded)}">${p.IsLoaded?'<span style="color:var(--accent)">yes</span>':'—'}</td>
        </tr>`;
      });
      html += '</table>';
      totalRows += profiles.length;
    }

    // Local accounts
    const locals = (u.local_accounts || []).filter(a => !lq || str(a.Name).includes(lq) || str(a.SID).includes(lq));
    if (locals.length) {
      html += `<h4 style="margin-bottom:6px">Local Accounts (${locals.length})</h4>
        <table class="expand-tbl" style="margin-bottom:10px">
          <tr><th>Name</th><th title="${esc(USER_TIPS.SID)}">SID</th><th>Disabled</th><th>Pwd Required</th><th>Has Profile</th><th>Description</th></tr>`;
      locals.forEach(a => {
        const disStyle = a.Disabled ? 'color:var(--muted)' : '';
        html += `<tr style="${disStyle}">
          <td class="mono">${esc(a.Name||'—')}</td>
          <td class="mono" style="font-size:10px" title="${esc(USER_TIPS.SID)}">${esc(a.SID||'—')}</td>
          <td style="color:${a.Disabled?'var(--amber)':'var(--muted)'}">${a.Disabled?'yes':'—'}</td>
          <td>${a.PasswordRequired?'yes':'—'}</td>
          <td>${a.HasProfile?'<span style="color:var(--accent)">yes</span>':'—'}</td>
          <td style="color:var(--muted)">${esc(a.Description||'')}</td>
        </tr>`;
      });
      html += '</table>';
      totalRows += locals.length;
    }

    // Group members
    const members = (u.group_members || []).filter(m => !lq || str(m.MemberName).includes(lq) || str(m.GroupName).includes(lq));
    if (members.length) {
      html += `<h4 style="margin-bottom:6px">Privileged Group Members (${members.length})</h4>
        <table class="expand-tbl" style="margin-bottom:10px">
          <tr><th>Group</th><th>Member</th><th>Domain</th><th title="${esc(USER_TIPS.SID)}">SID</th><th>Local</th></tr>`;
      members.forEach(m => {
        html += `<tr>
          <td style="color:var(--amber)">${esc(m.GroupName||'—')}</td>
          <td class="mono">${esc(m.MemberName||'—')}</td>
          <td>${esc(m.MemberDomain||'—')}</td>
          <td class="mono" style="font-size:10px" title="${esc(USER_TIPS.SID)}">${esc(m.MemberSID||'—')}</td>
          <td>${m.IsLocal?'<span style="color:var(--accent)">yes</span>':'—'}</td>
        </tr>`;
      });
      html += '</table>';
      totalRows += members.length;
    }

    // DC domain accounts
    if (u.is_domain_controller && u.domain_accounts && u.domain_accounts.length) {
      const das = u.domain_accounts.filter(a => !lq || str(a.SamAccountName).includes(lq) || str(a.SID).includes(lq));
      if (das.length) {
        html += `<h4 style="margin-bottom:6px">Domain Accounts — DC (${das.length})</h4>
          <table class="expand-tbl" style="margin-bottom:10px">
            <tr>
              <th>SAMAccountName</th><th>Display</th><th title="${esc(USER_TIPS.WhenCreated)}">Created</th>
              <th title="${esc(USER_TIPS.LastLogonAD)}">Last Logon</th><th>Enabled</th><th>Locked</th>
              <th>Bad Pwd</th><th>Source</th>
            </tr>`;
        das.forEach(a => {
          const enStyle = a.Enabled ? '' : 'color:var(--muted)';
          html += `<tr style="${enStyle}">
            <td class="mono">${esc(a.SamAccountName||'—')}</td>
            <td>${esc(a.DisplayName||'—')}</td>
            <td title="${esc(USER_TIPS.WhenCreated)}">${fmtDate(a.WhenCreatedUTC)}</td>
            <td title="${esc(USER_TIPS.LastLogonAD)}">${fmtDate(a.LastLogonUTC)}</td>
            <td style="color:${a.Enabled?'var(--green)':'var(--red)'}">${a.Enabled?'yes':'no'}</td>
            <td style="color:${a.LockedOut?'var(--red)':'var(--muted)'}">${a.LockedOut?'YES':'—'}</td>
            <td style="color:${(a.BadLogonCount>0)?'var(--amber)':'var(--muted)'}">${a.BadLogonCount||0}</td>
            <td style="color:var(--muted);font-size:10px">${esc(a.Source||'—')}</td>
          </tr>`;
        });
        html += '</table>';
        totalRows += das.length;
      }
    }

    html += '</div></div>';
  })();

  if (!html) html = '<div class="solo-notice">No Users data matches filter.</div>';
  container.innerHTML = html;
  const cnt = el('users-count');
  if (cnt) cnt.textContent = totalRows + ' records';
}
