# Tailscale 상태 조회, 로그인, API(키/초대), 토큰 보관, 상대 계정명 기억.

function Get-TsStatus {
    try { return (& $Script:TsExe status --json 2>$null | Out-String | ConvertFrom-Json) } catch { return $null }
}

function Get-Peers($st) {
    $out = @()
    if ($st -and $st.Peer) {
        foreach ($pr in $st.Peer.PSObject.Properties) {
            $v  = $pr.Value
            $ip = @($v.TailscaleIPs) | Where-Object { $_ -like '100.*' } | Select-Object -First 1
            if (-not $ip) { continue }
            $out += [pscustomobject]@{
                name   = [string]$v.HostName
                ip     = [string]$ip
                online = [bool]$v.Online
                os     = [string]$v.OS
                user   = (Get-SavedUser ([string]$ip))
            }
        }
    }
    return @($out | Sort-Object -Property @{ Expression = 'online'; Descending = $true }, 'name')
}

function Get-MyIp($st) {
    if ($st -and $st.Self) {
        $ip = @($st.Self.TailscaleIPs) | Where-Object { $_ -like '100.*' } | Select-Object -First 1
        if ($ip) { return [string]$ip }
    }
    return ''
}

# ── 로그인 ────────────────────────────────────────────────────
# tailscale up 은 로그인이 끝날 때까지 블로킹한다. 웹 UI 가 멈추면 안 되므로
# 별도 프로세스로 띄우고 출력만 읽는다. 로그인 URL 이 그 출력에 찍힌다.
function Start-TsLogin {
    foreach ($f in @($Script:LoginOut, $Script:LoginErr)) { Remove-Item $f -Force -ErrorAction SilentlyContinue }
    Start-Process -FilePath $Script:TsExe `
        -ArgumentList @('up','--unattended','--accept-dns=false','--timeout=600s') `
        -RedirectStandardOutput $Script:LoginOut -RedirectStandardError $Script:LoginErr `
        -WindowStyle Hidden | Out-Null
}

function Get-LoginUrl {
    foreach ($f in @($Script:LoginErr, $Script:LoginOut)) {
        if (-not (Test-Path $f)) { continue }
        try {
            $t = Get-Content $f -Raw -ErrorAction Stop
            $m = [regex]::Match([string]$t, 'https://login\.tailscale\.com/\S+')
            if ($m.Success) { return $m.Value.TrimEnd('.', ',') }
        } catch {}
    }
    return ''
}

function Join-WithAuthKey([string]$key) {
    return (Native $Script:TsExe @('up','--unattended','--accept-dns=false','--timeout=120s',('--authkey=' + $key)))
}

# ── API 토큰 ──────────────────────────────────────────────────
# DPAPI CurrentUser 로 암호화한다. 파일이 복사돼도 다른 계정/PC 에서는 풀리지 않는다.
function Write-TsToken([string]$token) {
    Ensure-StateDir
    $b = [Text.Encoding]::UTF8.GetBytes($token)
    $e = [Security.Cryptography.ProtectedData]::Protect($b, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    [IO.File]::WriteAllBytes($Script:TokenStore, $e)
}

function Read-TsToken {
    if (-not (Test-Path $Script:TokenStore)) { return $null }
    try {
        $e = [IO.File]::ReadAllBytes($Script:TokenStore)
        $b = [Security.Cryptography.ProtectedData]::Unprotect($e, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        return [Text.Encoding]::UTF8.GetString($b)
    } catch { return $null }   # 다른 관리자 계정으로 승격했거나 파일이 깨진 경우
}

# Invoke-RestMethod 는 4xx 응답 본문을 예외 메시지에 담아 주지 않는다.
function Get-WebErrorText($err) {
    try {
        $r = $err.Exception.Response
        if ($r) {
            $sr = New-Object IO.StreamReader($r.GetResponseStream())
            $txt = $sr.ReadToEnd()
            if ($txt) { return $txt }
        }
    } catch {}
    return $err.Exception.Message
}

# capabilities.devices.create 를 비워 두면 1회용 + 태그 없는 키가 나온다.
# 사용자 access token 으로 만드는 키는 태그가 필요 없다.
function New-TsAuthKey([string]$token, [int]$seconds, [string]$desc) {
    $body = @{
        keyType = 'auth'; description = $desc; expirySeconds = $seconds
        capabilities = @{ devices = @{ create = @{ reusable = $false; ephemeral = $false; preauthorized = $true } } }
    } | ConvertTo-Json -Depth 6
    $r = Invoke-RestMethod -Method Post -Uri $Script:TsKeysApi `
            -Headers @{ Authorization = ('Bearer ' + $token) } `
            -ContentType 'application/json' -Body $body -TimeoutSec 30
    if (-not $r.key) { throw 'API 응답에 key 필드가 없다.' }
    return [string]$r.key
}

# 본문이 배열이라는 점에 주의. email 을 생략하면 메일을 보내지 않고 inviteUrl 만 돌려준다.
# user-owned 토큰에서만 동작한다 (초대에는 초대한 사용자가 필요하므로).
function New-TsInvite([string]$token) {
    $body = ConvertTo-Json -Depth 4 -InputObject @(@{ role = 'member' })
    $r = Invoke-RestMethod -Method Post -Uri $Script:TsInviteApi `
            -Headers @{ Authorization = ('Bearer ' + $token) } `
            -ContentType 'application/json' -Body $body -TimeoutSec 30
    $first = @($r)[0]
    if (-not $first.inviteUrl) { throw 'API 응답에 inviteUrl 이 없다.' }
    return [string]$first.inviteUrl
}

# ── 상대 계정명 기억 ──────────────────────────────────────────
# Tailscale 은 상대 PC 의 Windows 계정명을 알려주지 않는다. 사용자가 입력한 값을
# IP 별로 저장한다. setup-remote-tui.cmd 와 같은 파일을 공유한다.
function Get-SavedUser([string]$ip) {
    if (-not (Test-Path $Script:UserStore)) { return '' }
    foreach ($l in (Get-Content $Script:UserStore -ErrorAction SilentlyContinue)) {
        $kv = $l -split '=', 2
        if ($kv.Count -eq 2 -and $kv[0] -eq $ip) { return $kv[1] }
    }
    return ''
}

function Save-User([string]$ip, [string]$u) {
    try {
        Ensure-StateDir
        $lines = @()
        if (Test-Path $Script:UserStore) {
            $lines = @(Get-Content $Script:UserStore | Where-Object { (($_ -split '=', 2)[0]) -ne $ip })
        }
        if ($u) { $lines += ($ip + '=' + $u) }
        Set-Content -Path $Script:UserStore -Value $lines -Encoding UTF8
    } catch {}
}
