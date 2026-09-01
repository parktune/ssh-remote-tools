# 진입점. setup-remote-web.cmd 가 관리자 권한으로 이 파일을 실행한다.
# 설치 → 로컬 웹 서버 기동 → 브라우저 오픈 → 요청 처리 루프.

$Script:LibDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script:RootDir = Split-Path -Parent $Script:LibDir
$Script:WebDir  = Join-Path $Script:RootDir 'web'

. (Join-Path $Script:LibDir 'common.ps1')
. (Join-Path $Script:LibDir 'access.ps1')
. (Join-Path $Script:LibDir 'install.ps1')
. (Join-Path $Script:LibDir 'tailscale.ps1')
. (Join-Path $Script:LibDir 'server.ps1')

Write-Host '========================================================'
Write-Host '        원격 접속 설정 (웹)  -  OpenSSH + Tailscale'
Write-Host '========================================================'
Write-Host ''
Write-Host '  준비가 끝나면 브라우저가 자동으로 열립니다. 잠시 기다려 주세요.' -ForegroundColor DarkGray

if (-not (Test-Path (Join-Path $Script:WebDir 'index.html'))) {
    Die ('web\index.html 이 없다. 이 파일들은 한 폴더로 같이 다녀야 한다: ' + $Script:RootDir)
}

Head '[1/4] OpenSSH 서버'
Ensure-OpenSsh
# 서비스는 켜 두되 방화벽은 닫아 둔다. 실제 개방은 웹에서 사용자가 누를 때만 일어난다.
Info '방화벽은 닫힌 상태로 시작한다. 여는 것은 웹 화면에서 결정한다.'

Head '[2/4] Tailscale'
Ensure-Tailscale

Head '[3/4] 로컬 웹 서버'
$srv = Start-LocalListener
if (-not $srv) { Die '8790~8809 사이에 쓸 수 있는 포트가 없다.' }
$nonce = [Guid]::NewGuid().ToString('N')
$url   = ('http://127.0.0.1:' + $srv.port + '/?t=' + $nonce)
Ok ('주소: ' + $url)

Head '[4/4] 브라우저 열기'
# 관리자 권한 프로세스에서 Start-Process 로 브라우저를 띄우면 브라우저까지 관리자로
# 돈다. explorer 를 거치면 일반 권한으로 열린다.
try { Start-Process 'explorer.exe' -ArgumentList $url | Out-Null; Ok '열었다' }
catch { try { Start-Process $url | Out-Null; Ok '열었다' } catch { Warn '자동으로 열지 못했다. 위 주소를 직접 입력하라.' } }

Write-Host ''
Write-Host '  이 창은 웹 화면이 동작하는 동안 열어 두세요.' -ForegroundColor Yellow
Write-Host '  종료하려면 웹 화면의 [서버 종료] 를 누르거나 이 창에서 Ctrl+C 를 누르세요.' -ForegroundColor DarkGray
Write-Host ''

Run-Server $srv.listener $nonce

Write-Host ''
Ok '웹 서버를 종료했다.'
if (Test-AccessOpen) {
    $e = Get-Expiry
    if ($e) { Warn ('접속은 아직 열려 있다. ' + $e.ToString('yyyy-MM-dd HH:mm') + ' 에 자동으로 닫힌다.') }
    else    { Warn '접속이 아직 열려 있고 자동 차단 예약이 없다. 다시 실행해 닫아라.' }
} else {
    Info '이 PC 는 접속을 받지 않는 상태다.'
}
Write-Host ''
Write-Host '  [입력 대기 중] 창을 닫으려면 엔터를 누르세요.' -ForegroundColor Yellow
[void](Read-Host '  엔터')
exit 0
