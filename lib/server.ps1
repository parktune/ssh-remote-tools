# 로컬 웹 서버. 127.0.0.1 에만 바인딩한다 - 0.0.0.0 으로 열면 방화벽을 여닫는
# 이 제어 API 가 같은 랜에 노출된다.
#
# 브라우저의 다른 사이트가 이 API 를 호출하지 못하도록 실행마다 새로 만드는
# 논스를 요구한다. 페이지는 주소 쿼리(?t=)로 받고, API 는 X-Auth 헤더로 확인한다.
# 커스텀 헤더를 요구하면 타 사이트발 요청은 브라우저의 CORS 사전 검사에서 막힌다.

function Send-Bytes($ctx, [byte[]]$bytes, [string]$type, [int]$code) {
    $ctx.Response.StatusCode  = $code
    $ctx.Response.ContentType = $type
    $ctx.Response.Headers['Cache-Control']          = 'no-store'
    $ctx.Response.Headers['X-Content-Type-Options'] = 'nosniff'
    $ctx.Response.ContentLength64 = $bytes.Length
    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $ctx.Response.Close()
}

function Send-Json($ctx, $obj, [int]$code = 200) {
    Send-Bytes $ctx ([Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Depth 6 -Compress))) 'application/json; charset=utf-8' $code
}

function Send-Text($ctx, [string]$s, [string]$type, [int]$code = 200) {
    Send-Bytes $ctx ([Text.Encoding]::UTF8.GetBytes($s)) $type $code
}

function Read-Body($ctx) {
    if (-not $ctx.Request.HasEntityBody) { return $null }
    $sr = New-Object IO.StreamReader($ctx.Request.InputStream, $ctx.Request.ContentEncoding)
    $t  = $sr.ReadToEnd(); $sr.Close()
    if ([string]::IsNullOrWhiteSpace($t)) { return $null }
    try { return ($t | ConvertFrom-Json) } catch { return $null }
}

function Start-LocalListener {
    foreach ($p in 8790..8809) {
        $l = $null
        try {
            $l = New-Object System.Net.HttpListener
            $l.Prefixes.Add("http://127.0.0.1:$p/")
            $l.Start()
            return @{ listener = $l; port = $p }
        } catch { if ($l) { try { $l.Close() } catch {} } }
    }
    return $null
}

# 웹 자산은 파일에서 읽는다. 확장자별 타입만 허용하고, 경로 탈출을 막기 위해
# 파일 이름만 취해서 web/ 안에서만 찾는다.
function Get-AssetPath([string]$urlPath) {
    $name = [IO.Path]::GetFileName($urlPath)
    if ($name -notmatch '^[A-Za-z0-9._-]+$') { return $null }
    $full = Join-Path $Script:WebDir $name
    if (-not (Test-Path $full)) { return $null }
    return $full
}

function Get-ContentTypeFor([string]$path) {
    switch ([IO.Path]::GetExtension($path).ToLower()) {
        '.html' { 'text/html; charset=utf-8' }
        '.css'  { 'text/css; charset=utf-8' }
        '.js'   { 'text/javascript; charset=utf-8' }
        '.svg'  { 'image/svg+xml' }
        '.ico'  { 'image/x-icon' }
        default { 'application/octet-stream' }
    }
}

function Handle-Api($ctx, [string]$path, $body) {
    switch ($path) {

        '/api/state' {
            $st   = Get-TsStatus
            $exp  = Get-Expiry
            $open = Test-AccessOpen
            # 예약 작업이 규칙을 지웠으면 만료 기록도 치운다.
            if (-not $open -and $exp) { Set-Expiry $null; $exp = $null }
            $isMs = $false
            try { $isMs = ((Get-LocalUser -Name $env:USERNAME -ErrorAction Stop).PrincipalSource -eq 'MicrosoftAccount') } catch {}
            $ip = Get-MyIp $st
            Send-Json $ctx @{
                backendState = $(if ($st) { [string]$st.BackendState } else { '' })
                loginUrl     = $(if (-not $st -or $st.BackendState -ne 'Running') { Get-LoginUrl } else { '' })
                myIp         = $ip
                myUser       = $env:USERNAME
                sshCmd       = ('ssh ' + $env:USERNAME + '@' + $ip)
                accessOpen   = $open
                expiresAt    = $(if ($exp) { $exp.ToString('o') } else { '' })
                hasToken     = [bool](Read-TsToken)
                isMsAccount  = $isMs
                peers        = @(Get-Peers $st)
            }
        }

        '/api/login/start' { Start-TsLogin; Send-Json $ctx @{ ok = $true } }

        '/api/login/authkey' {
            $k = ''
            if ($body -and $body.key) { $k = ([string]$body.key).Trim() }
            if (-not $k) { Send-Json $ctx @{ error = '키가 비어 있습니다.' }; return }
            $code = Join-WithAuthKey $k
            if ($code -ne 0) { Send-Json $ctx @{ error = ('연결 실패 (코드 ' + $code + '). 키가 만료됐거나 이미 사용된 키입니다.') } }
            else { Send-Json $ctx @{ ok = $true } }
        }

        '/api/token' {
            $t = ''
            if ($body -and $body.token) { $t = ([string]$body.token).Trim() }
            if (-not $t) { Send-Json $ctx @{ error = '토큰이 비어 있습니다.' }; return }
            # 실제로 동작하는지 확인한 토큰만 저장한다.
            try { [void](New-TsAuthKey $t 3600 'ssh-remote check'); Write-TsToken $t; Send-Json $ctx @{ ok = $true } }
            catch { Send-Json $ctx @{ error = ('토큰 확인 실패: ' + (Get-WebErrorText $_)) } }
        }

        '/api/invite/key' {
            $t = Read-TsToken
            if (-not $t) { Send-Json $ctx @{ error = '먼저 API 토큰을 등록하세요.' }; return }
            try { Send-Json $ctx @{ key = (New-TsAuthKey $t 86400 'ssh-remote invite') } }
            catch { Send-Json $ctx @{ error = ('키 발급 실패: ' + (Get-WebErrorText $_)) } }
        }

        '/api/invite/link' {
            $t = Read-TsToken
            if (-not $t) { Send-Json $ctx @{ error = '먼저 API 토큰을 등록하세요.' }; return }
            try { Send-Json $ctx @{ url = (New-TsInvite $t) } }
            catch { Send-Json $ctx @{ error = ('초대 링크 발급 실패: ' + (Get-WebErrorText $_)) } }
        }

        '/api/access/open' {
            $h = 4
            if ($body -and $body.hours) { $h = [int]$body.hours }
            if ($h -lt 1 -or $h -gt 24) { $h = 4 }
            $code = Open-Access
            if ($code -ne 0) { Send-Json $ctx @{ error = ('방화벽 규칙 추가 실패 (코드 ' + $code + ')') }; return }
            # 광역 규칙이 남아 있으면 대역 제한이 무의미하다. 열 때마다 확인한다.
            $broad = Disable-BroadSshRules
            $when  = (Get-Date).AddHours($h)
            $tc    = Register-CloseTask $when
            if ($tc -ne 0) {
                Set-Expiry $null
                Send-Json $ctx @{ ok = $true; disabledRules = $broad; warning = ('자동 차단 예약 실패 (코드 ' + $tc + '). 직접 닫아야 합니다.') }
            } else {
                Set-Expiry $when
                Send-Json $ctx @{ ok = $true; disabledRules = $broad }
            }
        }

        '/api/access/close' { Close-Access; Remove-CloseTask; Set-Expiry $null; Send-Json $ctx @{ ok = $true } }

        '/api/peer/user' {
            $ip = ''; $u = ''
            if ($body -and $body.ip)   { $ip = ([string]$body.ip).Trim() }
            if ($body -and $body.user) { $u  = ([string]$body.user).Trim() }
            if ($ip -notmatch '^100\.\d+\.\d+\.\d+$') { Send-Json $ctx @{ error = '잘못된 주소입니다.' }; return }
            Save-User $ip $u
            Send-Json $ctx @{ ok = $true }
        }

        '/api/quit' { Send-Json $ctx @{ ok = $true }; $Script:ServerRunning = $false }

        default { Send-Json $ctx @{ error = 'unknown endpoint' } 404 }
    }
}

function Run-Server($listener, [string]$nonce) {
    $Script:ServerRunning = $true
    while ($Script:ServerRunning -and $listener.IsListening) {
        $ctx = $null
        try { $ctx = $listener.GetContext() } catch { break }
        try {
            $req  = $ctx.Request
            $path = $req.Url.AbsolutePath

            if ($path -eq '/') {
                if ($req.QueryString['t'] -ne $nonce) {
                    Send-Text $ctx '<meta charset="utf-8"><p style="font:15px sans-serif;padding:40px">주소가 올바르지 않습니다. 콘솔 창에 표시된 주소로 다시 여세요.</p>' 'text/html; charset=utf-8' 403
                    continue
                }
                Send-Text $ctx ([IO.File]::ReadAllText((Join-Path $Script:WebDir 'index.html'), [Text.Encoding]::UTF8)) 'text/html; charset=utf-8' 200
                continue
            }

            # 정적 자산. 논스 검사 없이 준다 - 비밀이 없고, 캐시·리로드가 단순해진다.
            if ($path -like '/web/*') {
                $file = Get-AssetPath $path
                if ($file) { Send-Bytes $ctx ([IO.File]::ReadAllBytes($file)) (Get-ContentTypeFor $file) 200 }
                else       { Send-Text $ctx 'not found' 'text/plain' 404 }
                continue
            }

            if (-not $path.StartsWith('/api/')) { Send-Text $ctx 'not found' 'text/plain' 404; continue }
            if ($req.Headers['X-Auth'] -ne $nonce) { Send-Json $ctx @{ error = 'unauthorized' } 403; continue }

            Handle-Api $ctx $path (Read-Body $ctx)
        } catch {
            try { Send-Json $ctx @{ error = $_.Exception.Message } 500 } catch {}
        }
    }
    try { $listener.Stop(); $listener.Close() } catch {}
}
