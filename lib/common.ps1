# 공통 상수와 유틸리티. 다른 모든 lib 파일이 이 파일을 먼저 dot-source 한다.

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # Invoke-WebRequest 속도가 수십 배 차이난다
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
try { Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue } catch {}

# setup-remote-tui.cmd 와 같은 이름을 쓴다. 어느 쪽으로 열고 닫아도 같은 것을 가리켜야 한다.
$Script:RuleName    = 'OpenSSH-Server-Tailscale-22'
$Script:OldRule     = 'OpenSSH-Server-sshd-22'
$Script:TsRange     = '100.64.0.0/10'          # Tailscale 이 쓰는 CGNAT 대역
$Script:CloseTask   = 'ssh-remote-close'
$Script:TsExe       = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
$Script:StateDir    = Join-Path $env:LOCALAPPDATA 'ssh-remote'
$Script:TokenStore  = Join-Path $Script:StateDir 'tsapi.dat'
$Script:ExpiryFile  = Join-Path $Script:StateDir 'expires.txt'
$Script:UserStore   = Join-Path $Script:StateDir 'hosts.txt'
$Script:LoginOut    = Join-Path $env:TEMP 'ssh-remote-login.out'
$Script:LoginErr    = Join-Path $env:TEMP 'ssh-remote-login.err'
$Script:TsKeysApi   = 'https://api.tailscale.com/api/v2/tailnet/-/keys'
$Script:TsInviteApi = 'https://api.tailscale.com/api/v2/tailnet/-/user-invites'

function Ok($t)   { Write-Host ('      OK  ' + $t) -ForegroundColor Green }
function Info($t) { Write-Host ('      -   ' + $t) -ForegroundColor DarkGray }
function Warn($t) { Write-Host ('      !   ' + $t) -ForegroundColor Yellow }
function Bad($t)  { Write-Host ('      X   ' + $t) -ForegroundColor Red }
function Head($t) { Write-Host ''; Write-Host $t -ForegroundColor Cyan }

# 네이티브 명령 실행용. stderr 한 줄이 종료 예외로 승격되는 것을 막고 종료 코드만 돌려준다.
function Native([string]$exe, [string[]]$argv) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $exe @argv 2>&1 | Out-Null; return $LASTEXITCODE } finally { $ErrorActionPreference = $old }
}

function Ensure-StateDir { New-Item -ItemType Directory -Force -Path $Script:StateDir | Out-Null }

function Die($msg) {
    Bad $msg
    Write-Host ''
    Write-Host '  진단: Get-Service sshd, Tailscale' -ForegroundColor DarkGray
    Write-Host '        & "$env:ProgramFiles\Tailscale\tailscale.exe" status' -ForegroundColor DarkGray
    Write-Host '        schtasks /Query /TN ssh-remote-close /V /FO LIST' -ForegroundColor DarkGray
    Write-Host '        netsh advfirewall firewall show rule name=all | findstr /i ssh' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  [입력 대기 중] 창을 닫으려면 엔터를 누르세요.' -ForegroundColor Yellow
    [void](Read-Host '  엔터')
    exit 1
}
