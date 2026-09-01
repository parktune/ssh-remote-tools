// 원격 접속 설정 웹 UI.
// 서버는 실행할 때마다 새 논스를 만들고, 이 페이지는 주소 쿼리 t 로 받아
// 모든 API 요청의 X-Auth 헤더에 실어 보낸다. 다른 사이트가 이 API 를 못 부르게 하는 장치다.

const T = new URLSearchParams(location.search).get('t') || '';
let S = null, busy = false;

async function api(path, body) {
  const r = await fetch(path, {
    method: body ? 'POST' : 'GET',
    headers: { 'X-Auth': T, 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined
  });
  return await r.json();
}

function toast(m) {
  const t = document.getElementById('toast');
  t.textContent = m;
  t.classList.add('show');
  setTimeout(() => t.classList.remove('show'), 1800);
}

async function copy(s) {
  try { await navigator.clipboard.writeText(s); toast('복사했습니다'); }
  catch (e) { toast('복사 실패 — 직접 선택해 주세요'); }
}

function esc(s) {
  return String(s == null ? '' : s).replace(/[&<>"']/g,
    c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}
// onclick 속성 안에 문자열 인자를 안전하게 넣기 위한 이중 인코딩
function attrArg(s) { return esc(JSON.stringify(String(s))); }

function remain(iso) {
  if (!iso) return '';
  const ms = new Date(iso) - new Date();
  if (ms <= 0) return '만료됨';
  const h = Math.floor(ms / 3600000), m = Math.floor(ms / 60000) % 60;
  return h > 0 ? (h + '시간 ' + m + '분 남음') : (m + '분 남음');
}

async function act(fn) {
  if (busy) return;
  busy = true;
  try { await fn(); } finally { busy = false; await refresh(); }
}

const openAccess = h => act(async () => {
  const r = await api('/api/access/open', { hours: h });
  if (r.error) { toast(r.error); return; }
  if (r.warning) toast(r.warning);
  const broad = Array.isArray(r.disabledRules) ? r.disabledRules : (r.disabledRules ? [r.disabledRules] : []);
  if (broad.length) toast('전체 개방 규칙 ' + broad.length + '개를 껐습니다: ' + broad.join(', '));
});
const closeAccess = () => act(async () => { await api('/api/access/close', {}); });
const startLogin  = () => act(async () => { await api('/api/login/start', {}); toast('로그인 링크를 준비하는 중…'); });

async function useKey() {
  const v = document.getElementById('authkey').value.trim();
  if (!v) return;
  await act(async () => {
    const r = await api('/api/login/authkey', { key: v });
    if (r.error) toast(r.error);
  });
}

async function saveToken() {
  const v = document.getElementById('apitoken').value.trim();
  if (!v) return;
  await act(async () => {
    const r = await api('/api/token', { token: v });
    toast(r.error ? r.error : '토큰을 확인하고 저장했습니다');
  });
}

async function issue(kind) {
  await act(async () => {
    const r = await api(kind === 'key' ? '/api/invite/key' : '/api/invite/link', {});
    const box = document.getElementById('issued');
    if (r.error) { box.innerHTML = '<div class="note">' + esc(r.error) + '</div>'; return; }
    const v = r.key || r.url;
    box.innerHTML =
      '<div class="cmd"><code class="mono">' + esc(v) + '</code>' +
      '<button onclick="copy(' + attrArg(v) + ')">복사</button></div>' +
      '<div class="hint">' + (kind === 'key'
        ? '상대가 이 도구를 실행한 뒤 붙여넣으면 됩니다. 1회용 · 24시간 유효.'
        : '상대가 링크를 열어 본인 계정으로 로그인하면 이 네트워크에 참여합니다.') + '</div>';
  });
}

// 피어별 계정명. 입력을 벗어나면 저장하고, 복사 버튼은 저장된 값을 쓴다.
async function savePeerUser(ip, el) {
  const u = el.value.trim();
  await api('/api/peer/user', { ip: ip, user: u });
  const p = (Array.isArray(S.peers) ? S.peers : [S.peers]).find(x => x && x.ip === ip);
  if (p) p.user = u;
}
function copyPeer(ip) {
  const ps = Array.isArray(S.peers) ? S.peers : (S.peers ? [S.peers] : []);
  const p = ps.find(x => x && x.ip === ip);
  if (!p) return;
  if (!p.user) { toast('먼저 계정 이름을 입력해 주세요'); return; }
  copy('ssh ' + p.user + '@' + p.ip);
}

async function quit() {
  await api('/api/quit', {});
  document.body.innerHTML = '<div class="wrap"><div class="card">종료했습니다. 이 탭을 닫아도 됩니다.</div></div>';
}

function loginCard() {
  return '<div class="card full"><h2>Tailscale 로그인</h2>' +
    '<p class="hint">두 PC 가 같은 네트워크에 있어야 서로 보입니다. 아래 중 하나를 고르세요.</p>' +
    (S.loginUrl
      ? '<div class="note">아래 링크를 열어 로그인하세요. 끝나면 이 화면이 저절로 바뀝니다.<br>' +
        '<a href="' + esc(S.loginUrl) + '" target="_blank" rel="noopener">' + esc(S.loginUrl) + '</a></div>'
      : '<div class="row"><button class="primary" onclick="startLogin()">브라우저로 로그인</button>' +
        '<span class="pill off">내 계정으로 로그인 · 네트워크를 새로 만들 때</span></div>') +
    '<div class="row" style="margin-top:16px">' +
    '<input type="text" id="authkey" placeholder="tskey-auth-… (받은 인증 키 붙여넣기)"></div>' +
    '<div class="row"><button onclick="useKey()">인증 키로 참여</button>' +
    '<span class="pill off">상대가 보내준 키가 있을 때 · 계정 불필요</span></div></div>';
}

function incomingCard() {
  const open = S.accessOpen;
  return '<div class="card"><h2>접속받기 <span class="pill ' + (open ? 'on' : 'off') + '">' +
    (open ? '열림' : '닫힘') + '</span></h2>' +
    '<p class="hint">이 PC 로 다른 사람이 들어올 수 있게 합니다.</p>' +
    '<div class="cmd"><code class="mono">' + esc(S.sshCmd) + '</code>' +
    '<button onclick="copy(' + attrArg(S.sshCmd) + ')">복사</button></div>' +
    (open
      ? '<div class="hint">' + (S.expiresAt
          ? remain(S.expiresAt) + ' · ' + new Date(S.expiresAt).toLocaleString('ko-KR')
          : '자동 차단 예약 없음') + '</div>' +
        '<div class="row"><button class="danger" onclick="closeAccess()">지금 닫기</button>' +
        '<button onclick="openAccess(1)">1시간으로 재설정</button>' +
        '<button onclick="openAccess(4)">4시간으로 재설정</button></div>'
      : '<div class="row"><button class="primary" onclick="openAccess(1)">1시간 열기</button>' +
        '<button onclick="openAccess(4)">4시간</button><button onclick="openAccess(12)">12시간</button></div>') +
    '<div class="hint" style="margin-top:12px">22번 포트는 Tailscale 망(100.64.0.0/10)에만 열립니다. ' +
    '인터넷·공용 와이파이·같은 랜에서는 닿지 않습니다. 시간이 지나면 자동으로 닫힙니다.</div>' +
    (S.isMsAccount
      ? '<div class="note">Microsoft 계정입니다. SSH 암호로 Microsoft 계정 암호를 입력하세요. PIN 은 쓸 수 없습니다.</div>'
      : '') +
    '</div>';
}

function outgoingCard() {
  const ps = Array.isArray(S.peers) ? S.peers : (S.peers ? [S.peers] : []);
  let body;
  if (!ps.length) {
    body = '<div class="empty">아직 연결된 PC 가 없습니다.<br>' +
      '상대도 이 도구를 실행하고 같은 네트워크에 참여하면 여기에 나타납니다.</div>';
  } else {
    body = ps.map(p =>
      '<div class="peer"><span class="dot ' + (p.online ? 'on' : '') + '"></span>' +
      '<span class="grow"><span class="pname">' + esc(p.name) + '</span>' +
      '<br><span class="pip mono">' + esc(p.ip) + '</span> ' +
      '<span class="pip">· ' + (p.online ? '온라인' : '오프라인') + (p.os ? ' · ' + esc(p.os) : '') + '</span></span>' +
      '<input type="text" class="puser" placeholder="계정" value="' + esc(p.user || '') + '"' +
      ' onchange="savePeerUser(' + attrArg(p.ip) + ', this)">' +
      '<button onclick="copyPeer(' + attrArg(p.ip) + ')">명령 복사</button></div>'
    ).join('');
  }
  return '<div class="card"><h2>접속하기</h2>' +
    '<p class="hint">계정 이름을 넣고 [명령 복사] → 터미널에 붙여넣으면 접속됩니다.</p>' + body +
    '<div class="hint" style="margin-top:12px">계정 이름은 상대 PC 화면의 ssh 명령에서 @ 앞부분입니다. 한 번 넣으면 기억합니다.</div></div>';
}

function inviteCard() {
  if (!S.hasToken) {
    return '<div class="card full"><h2>상대 초대하기</h2>' +
      '<p class="hint">API 토큰을 한 번만 등록하면, 이후로는 이 화면에서 인증 키와 초대 링크를 바로 만들 수 있습니다.</p>' +
      '<div class="row"><a href="https://login.tailscale.com/admin/settings/keys" target="_blank" rel="noopener">' +
      '<button class="primary" type="button">Keys 페이지 열기</button></a>' +
      '<span class="pill off">Generate access token 으로 만든 값을 아래에 붙여넣기</span></div>' +
      '<div class="row"><input type="text" id="apitoken" placeholder="tskey-api-…"></div>' +
      '<div class="row"><button onclick="saveToken()">토큰 저장</button></div>' +
      '<div class="hint" style="margin-top:10px">토큰은 이 PC 의 이 계정에서만 풀리도록 암호화해 저장합니다. 밖으로 나가지 않습니다.</div></div>';
  }
  return '<div class="card full"><h2>상대 초대하기</h2>' +
    '<p class="hint">둘 중 편한 쪽을 쓰세요.</p>' +
    '<div class="row"><button class="primary" onclick="issue(\'key\')">인증 키 발급</button>' +
    '<span class="pill off">상대가 Tailscale 계정 없이 참여 · 붙여넣기 한 번</span></div>' +
    '<div class="row"><button onclick="issue(\'link\')">초대 링크 발급</button>' +
    '<span class="pill off">상대가 본인 계정으로 참여 · 붙여넣을 것 없음</span></div>' +
    '<div class="out" id="issued"></div></div>';
}

function render() {
  const conn = document.getElementById('conn');
  const on = S.backendState === 'Running';
  conn.textContent = on ? 'Tailscale 연결됨' : 'Tailscale 미연결';
  conn.className = 'pill ' + (on ? 'on' : 'off');

  // 입력 중에 다시 그리면 쓰던 값이 날아간다. 포커스가 입력에 있으면 건너뛴다.
  const ae = document.activeElement;
  if (ae && ae.tagName === 'INPUT') return;

  document.getElementById('app').innerHTML =
    '<div class="grid">' + (on ? incomingCard() + outgoingCard() + inviteCard() : loginCard()) + '</div>';
}

async function refresh() {
  try { S = await api('/api/state'); render(); }
  catch (e) { /* 서버가 내려간 경우 - 다음 폴링에서 재시도 */ }
}

refresh();
setInterval(() => { if (!busy) refresh(); }, 2500);
