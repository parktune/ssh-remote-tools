@echo off
setlocal EnableExtensions
chcp 65001 >nul
title 원격 접속 설정 (TUI) - OpenSSH + Tailscale

:: 관리자 권한 확보. 승인이 취소되면 창이 그냥 사라지지 않도록 이유를 남긴다.
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo.
    echo  [알림] 관리자 권한이 필요합니다. 권한 승인 창에서 '예'를 눌러주세요.
    echo.
    powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Start-Process -FilePath '%~f0' -Verb RunAs } catch { exit 1 }"
    if errorlevel 1 (
        echo.
        echo  [!] 권한 승인이 취소되었습니다.
        echo  [!] 파일을 우클릭 - "관리자 권한으로 실행" 을 눌러주세요.
        echo.
        echo  [입력 대기 중] 창을 닫으려면 아무 키나 누르세요.
        pause >nul
    )
    exit /b
)

cls
:: 이 파일 하단의 PowerShell 본문을 단일 프로세스로 실행
powershell -NoProfile -ExecutionPolicy Bypass -Command "$f=[IO.File]::ReadAllText('%~f0',[Text.Encoding]::UTF8); $m='#PS'+'START'; Invoke-Expression $f.Substring($f.IndexOf($m)+$m.Length)"
exit /b %errorlevel%

#PSSTART
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # Invoke-WebRequest 속도가 수십 배 차이난다
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

function Ok($t)   { Write-Host ('      OK  ' + $t) -ForegroundColor Green }
function Info($t) { Write-Host ('      -   ' + $t) -ForegroundColor DarkGray }
function Warn($t) { Write-Host ('      !   ' + $t) -ForegroundColor Yellow }
function Bad($t)  { Write-Host ('      X   ' + $t) -ForegroundColor Red }
function Head($t) { Write-Host ''; Write-Host $t -ForegroundColor Cyan }

$global:StepNo    = 0
$global:StepTotal = 0
function Step($t) {
    $global:StepNo++
    Write-Host ''
    Write-Host ('[' + $global:StepNo + '/' + $global:StepTotal + '] ' + $t) -ForegroundColor Cyan
}

# ══════════════════════════════════════════════════════════════
#  키 입력 / TUI
#  mount.ps1 의 Read-Key / Draw-Box / Menu-Single 을 그대로 따랐다.
#  두 도구 사이에 조작감이 같아야 손이 헷갈리지 않는다.
# ══════════════════════════════════════════════════════════════

# RawUI 를 못 쓰는 환경(출력 리디렉션 등)에서는 번호 입력으로 내려간다.
$global:CanReadKey = $true
try { if (-not $Host.UI.RawUI) { $global:CanReadKey = $false } } catch { $global:CanReadKey = $false }

function Read-Key {
    try {
        # AllowCtrlC 를 빼면 Ctrl+C 와 Ctrl+Shift+C 가 호스트의 break 로 처리되어
        # 스크립트가 그 자리에서 죽는다. 키로 받아서 우리가 직접 정리한다.
        $k = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown,AllowCtrlC')
    } catch {
        $global:CanReadKey = $false
        return 'esc'
    }
    # Ctrl+C 는 문자 0x03 으로, Ctrl+Break 는 VK_CANCEL(3) 로 들어온다.
    # Ctrl+Shift+C 도 터미널이 복사로 가로채지 않으면 0x03 으로 도착한다.
    if ($k.VirtualKeyCode -eq 3 -or $k.Character -eq [char]3) { return 'cancel' }
    switch ($k.VirtualKeyCode) {
        38 { 'up' } 40 { 'down' } 37 { 'left' } 39 { 'right' }
        13 { 'enter' } 27 { 'esc' } 32 { 'space' } 36 { 'home' } 35 { 'end' }
        default {
            switch ($k.Character) {
                'k' { 'up' } 'j' { 'down' } 'h' { 'left' } 'l' { 'right' }
                'q' { 'quit' } default { [string]$k.Character }
            }
        }
    }
}

# 한글은 콘솔에서 두 칸을 차지한다. .Length 로 재면 상자 오른쪽 선이 안 맞는다.
# mount.ps1 은 내용이 전부 영문이라 이 보정이 필요 없었다.
function Vis-Width([string]$s) {
    $w = 0
    foreach ($ch in $s.ToCharArray()) {
        $c = [int]$ch
        if (($c -ge 0x1100 -and $c -le 0x115F) -or ($c -ge 0x2E80 -and $c -le 0xA4CF) -or
            ($c -ge 0xAC00 -and $c -le 0xD7A3) -or ($c -ge 0xF900 -and $c -le 0xFAFF) -or
            ($c -ge 0xFE30 -and $c -le 0xFE6F) -or ($c -ge 0xFF00 -and $c -le 0xFF60) -or
            ($c -ge 0xFFE0 -and $c -le 0xFFE6)) { $w += 2 } else { $w += 1 }
    }
    return $w
}

function Vis-Pad([string]$s, [int]$w) {
    $d = $w - (Vis-Width $s)
    if ($d -le 0) { return $s }
    return ($s + (' ' * $d))
}

function Vis-Trim([string]$s, [int]$max) {
    if ((Vis-Width $s) -le $max) { return $s }
    $out = ''
    foreach ($ch in $s.ToCharArray()) {
        if ((Vis-Width ($out + $ch)) -gt ($max - 1)) { break }
        $out += $ch
    }
    return ($out + '…')
}

function Draw-Box {
    param([string]$Title, [string[]]$Lines, [int]$Cursor = -1, [string]$Note = '', [string]$Hint = '')
    Clear-Host
    if ($Note) { Write-Host $Note -ForegroundColor DarkGray }
    $w = 4
    foreach ($l in $Lines) {
        if ($l -eq '__RULE__') { continue }
        $lw = Vis-Width $l
        if ($lw -gt $w) { $w = $lw }
    }
    $tw = Vis-Width $Title
    if ($tw + 4 -gt $w) { $w = $tw + 4 }
    # RawUI 가 없는 환경에서도 죽지 않도록 폭을 고정값으로 떨어뜨린다.
    $max = 76
    try { $max = [Math]::Max(20, $Host.UI.RawUI.WindowSize.Width - 6) } catch {}
    if ($w -gt $max) { $w = $max }

    Write-Host ("┌─ $Title " + ('─' * [Math]::Max(0, $w - $tw - 2)) + '┐') -ForegroundColor DarkGray
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $text = $Lines[$i]
        # 항목 묶음 사이의 구분선. mount.ps1 과 같은 토큰을 쓴다.
        if ($text -eq '__RULE__') {
            Write-Host '│ ' -ForegroundColor DarkGray -NoNewline
            Write-Host ('─' * $w) -ForegroundColor DarkGray -NoNewline
            Write-Host ' │' -ForegroundColor DarkGray
            continue
        }
        $text = Vis-Trim $text $w
        $pad  = ' ' * [Math]::Max(0, $w - (Vis-Width $text))
        Write-Host '│ ' -ForegroundColor DarkGray -NoNewline
        if ($i -eq $Cursor) { Write-Host $text -ForegroundColor Black -BackgroundColor Gray -NoNewline }
        else                { Write-Host $text -NoNewline }
        Write-Host "$pad │" -ForegroundColor DarkGray
    }
    Write-Host ('└' + ('─' * ($w + 2)) + '┘') -ForegroundColor DarkGray
    if ($Hint) { Write-Host $Hint -ForegroundColor DarkGray }
}

function Menu-Single {
    param(
        [string]$Title, [string[]]$Items, [string]$Note = '',
        [string[]]$ItemNotes = $null, [int]$Start = 0, [switch]$NoEsc
    )
    if (-not $global:CanReadKey) { return (Menu-Fallback $Title $Items $Start) }

    $cur = $Start
    while ($true) {
        # ReadKey 가 도중에 실패하면 CanReadKey 가 꺼진다. NoEsc 메뉴에서
        # 그대로 두면 빠져나갈 키가 없어 무한 루프가 되므로 여기서 내려간다.
        if (-not $global:CanReadKey) { return (Menu-Fallback $Title $Items $Start) }

        $hint = '[입력 대기 중]  ↑ ↓ 이동  ·  Enter 선택'
        if (-not $NoEsc) { $hint += '  ·  Esc 뒤로' }
        if ($ItemNotes -and $cur -lt $ItemNotes.Count -and $ItemNotes[$cur]) {
            $hint = '  ' + $ItemNotes[$cur] + "`n" + $hint
        }
        Draw-Box -Title $Title -Lines $Items -Cursor $cur -Note $Note -Hint $hint
        switch (Read-Key) {
            'up'    { $n = $cur - 1; while ($n -ge 0 -and $Items[$n] -eq '__RULE__') { $n-- }
                      if ($n -ge 0) { $cur = $n } }
            'down'  { $n = $cur + 1; while ($n -lt $Items.Count -and $Items[$n] -eq '__RULE__') { $n++ }
                      if ($n -lt $Items.Count) { $cur = $n } }
            'home'  { $n = 0; while ($n -lt $Items.Count - 1 -and $Items[$n] -eq '__RULE__') { $n++ }; $cur = $n }
            'end'   { $n = $Items.Count - 1; while ($n -gt 0 -and $Items[$n] -eq '__RULE__') { $n-- }; $cur = $n }
            'enter'  { return $cur }
            'right'  { return $cur }
            'esc'    { if (-not $NoEsc) { return -1 } }
            'quit'   { if (-not $NoEsc) { return -1 } }
            # NoEsc 메뉴에서도 Ctrl+C 는 빠져나갈 수 있어야 한다.
            'cancel' { Abort-Script }
        }
    }
}

# 방향키를 못 읽는 환경용. 화면 구성은 포기하고 번호만 받는다.
function Menu-Fallback([string]$Title, [string[]]$Items, [int]$Start) {
    Write-Host ''
    Write-Host ('   ' + $Title) -ForegroundColor Cyan
    $map = @()
    for ($i = 0; $i -lt $Items.Count; $i++) {
        if ($Items[$i] -eq '__RULE__') { continue }
        $map += $i
        Write-Host ('     ' + $map.Count + ') ' + $Items[$i])
    }
    Write-Host ''
    Write-Host '   방향키를 쓸 수 없는 환경이라 번호로 받는다.' -ForegroundColor DarkGray
    Write-Host '   [입력 대기 중] 번호를 입력한 뒤 엔터를 누르세요.' -ForegroundColor Yellow
    $a = Read-Host ('   번호 (엔터 = ' + ($Start + 1) + ')')
    $n = 0
    if ([int]::TryParse($a.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $map.Count) { return $map[$n - 1] }
    return $Start
}

function Pause-Key([string]$msg = '계속하려면 아무 키나 누르세요') {
    Write-Host ''
    if ($global:CanReadKey) {
        Write-Host ('   [입력 대기 중] ' + $msg) -ForegroundColor Yellow -NoNewline
        $k = Read-Key
        Write-Host ''
        if ($k -eq 'cancel') { Abort-Script }
    } else {
        Write-Host ('   [입력 대기 중] ' + $msg + ' (엔터)') -ForegroundColor Yellow
        [void](Read-Host '   엔터')
    }
}

# 방화벽을 연 뒤에 중단되면 열린 채로 남는다. 예약 작업이 있어 언젠가는 닫히지만,
# 지금 닫을 기회를 주고 끝내는 편이 낫다.
$global:AccessOpened = $false

function Abort-Script {
    Clear-Host
    Write-Host ''
    Warn '사용자가 중단했다. (Ctrl+C)'
    if ($global:AccessOpened) {
        Write-Host ''
        Write-Host '   이 PC 의 22번은 아직 열려 있다. 예약된 시각에 자동으로 닫힌다.'
        Write-Host ''
        # 여기서 Read-Key 를 다시 쓰면 Ctrl+C 처리가 재귀한다. 줄 입력으로 받는다.
        Write-Host '   [입력 대기 중] 지금 닫으려면 c 를 입력하고 엔터, 그냥 두려면 엔터.' -ForegroundColor Yellow
        $a = Read-Host '   선택'
        if ($a -match '^\s*[cC]') {
            Close-Access
            Remove-CloseTask
            $global:AccessOpened = $false
            Ok '접속을 차단했다.'
        } else {
            Info '열린 상태로 둔다.'
        }
    }
    Write-Host ''
    Write-Host '   [입력 대기 중] 창을 닫으려면 엔터를 누르세요.' -ForegroundColor Yellow
    [void](Read-Host '   엔터')
    exit 0
}

# 값 입력. 방향키로 받을 수 없는 항목(인증 키, 계정명)에만 쓴다.
function Ask-Value {
    param([string]$Title, [string]$Question, [string[]]$Notes, [string]$Label)
    Clear-Host
    Write-Host ''
    Write-Host ('   ' + $Title) -ForegroundColor Cyan
    Write-Host ''
    Write-Host ('   ' + $Question)
    if ($Notes) { Write-Host ''; foreach ($n in $Notes) { Write-Host ('   ' + $n) -ForegroundColor DarkGray } }
    Write-Host ''
    Write-Host '   [입력 대기 중] 입력한 뒤 엔터를 누르세요.' -ForegroundColor Yellow
    return (Read-Host ('   ' + $Label))
}

# ══════════════════════════════════════════════════════════════
#  공통 유틸
# ══════════════════════════════════════════════════════════════

# 네이티브 명령 실행용. stderr 한 줄이 종료 예외로 승격되는 것을 막고 종료 코드만 돌려준다.
function Native([string]$exe, [string[]]$argv) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $exe @argv 2>&1 | Out-Null
        return $LASTEXITCODE
    } finally { $ErrorActionPreference = $old }
}

# 출력을 보여줘야 하는 명령용. tailscale up 은 브라우저 로그인 URL 을 화면에 찍는다.
function NativeShow([string]$exe, [string[]]$argv) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $exe @argv
        return $LASTEXITCODE
    } finally { $ErrorActionPreference = $old }
}

function Die($msg) {
    Bad $msg
    Write-Host ''
    Write-Host '--------------------------------------------------------'
    Write-Host '  진단에 쓸 명령 (관리자 PowerShell):'
    Write-Host '    Get-Service sshd, Tailscale'
    Write-Host '    Get-Content $env:ProgramData\ssh\logs\sshd.log -Tail 40'
    Write-Host '    & "$env:ProgramFiles\Tailscale\tailscale.exe" status'
    Write-Host '    schtasks /Query /TN ssh-remote-close /V /FO LIST'
    Write-Host '    netsh advfirewall firewall show rule name=all | findstr /i ssh'
    Write-Host '--------------------------------------------------------'
    Pause-Key '위 내용을 확인한 뒤 아무 키나 누르면 닫힙니다'
    exit 1
}

# setup-remote.cmd 와 같은 이름을 쓴다. 두 파일 중 아무거나로 열고 닫을 수 있어야 한다.
$RuleName  = 'OpenSSH-Server-Tailscale-22'
$OldRule   = 'OpenSSH-Server-sshd-22'
$TsRange   = '100.64.0.0/10'
$CloseTask = 'ssh-remote-close'
$TS         = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
$UserStore  = Join-Path $env:LOCALAPPDATA 'ssh-remote\hosts.txt'
$TokenStore = Join-Path $env:LOCALAPPDATA 'ssh-remote\tsapi.dat'
$TsApi      = 'https://api.tailscale.com/api/v2/tailnet/-/keys'

# 이 스크립트는 브라우저를 열지 않는다. Tailscale 연결은 인증 키로만 한다.
# 키는 (1) 상대가 보내준 것을 붙여넣거나 (2) 저장된 API 토큰으로 직접 발급한다.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# ══════════════════════════════════════════════════════════════
#  접속 허용 / 차단
# ══════════════════════════════════════════════════════════════

# 규칙의 현재 상태를 netsh 출력에서 읽으려 하면 한국어 로캘에서 깨진다.
# 그래서 상태를 조회하지 않고, 열 때는 항상 지웠다 새로 만들고 닫을 때는 지운다.
function Open-Access {
    Native 'netsh' @('advfirewall','firewall','delete','rule',('name=' + $RuleName)) | Out-Null
    Native 'netsh' @('advfirewall','firewall','delete','rule',('name=' + $OldRule))  | Out-Null
    $code = Native 'netsh' @(
        'advfirewall','firewall','add','rule',('name=' + $RuleName),
        'dir=in','action=allow','protocol=TCP','localport=22',
        ('remoteip=' + $TsRange),'profile=any'
    )
    Native 'netsh' @('advfirewall','firewall','set','rule','name=OpenSSH-Server-In-TCP','new','enable=No') | Out-Null
    return $code
}

function Close-Access {
    Native 'netsh' @('advfirewall','firewall','delete','rule',('name=' + $RuleName)) | Out-Null
    Native 'netsh' @('advfirewall','firewall','delete','rule',('name=' + $OldRule))  | Out-Null
    Native 'netsh' @('advfirewall','firewall','set','rule','name=OpenSSH-Server-In-TCP','new','enable=No') | Out-Null
}

function Remove-CloseTask {
    Native 'schtasks' @('/Delete','/TN',$CloseTask,'/F') | Out-Null
}

# 예약 작업은 XML 로 등록한다. schtasks 의 /ST /SD 인자는 시스템 날짜 형식을 타서
# 한국어 로캘에서 실패하지만, XML 의 StartBoundary 는 ISO 8601 고정이라 안전하다.
function Register-CloseTask([datetime]$when) {
    Remove-CloseTask
    $iso       = $when.ToString('yyyy-MM-ddTHH:mm:ss')
    $netshArgs = 'advfirewall firewall set rule name="' + $RuleName + '" new enable=No'
    $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>SSH remote access auto-close</Description>
  </RegistrationInfo>
  <Triggers>
    <TimeTrigger>
      <StartBoundary>$iso</StartBoundary>
      <Enabled>true</Enabled>
    </TimeTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT10M</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>netsh.exe</Command>
      <Arguments>$netshArgs</Arguments>
    </Exec>
  </Actions>
</Task>
"@
    # schtasks 는 UTF-16 XML 을 요구한다.
    $path = Join-Path $env:TEMP 'ssh-remote-close.xml'
    [IO.File]::WriteAllText($path, $xml, [Text.Encoding]::Unicode)
    $code = Native 'schtasks' @('/Create','/TN',$CloseTask,'/XML',$path,'/F')
    Remove-Item $path -Force -ErrorAction SilentlyContinue
    if ($code -ne 0) { return $code }
    # 등록됐는지 종료 코드로만 확인한다. 출력 파싱은 로캘을 타서 쓰지 않는다.
    return (Native 'schtasks' @('/Query','/TN',$CloseTask))
}

# ══════════════════════════════════════════════════════════════
#  설치 경로들
# ══════════════════════════════════════════════════════════════

# zip 을 받아 풀기만 한다. 서비스 등록 여부는 호출한 쪽이 정한다.
function Expand-OpenSshZip {
    $dest = Join-Path $env:ProgramFiles 'OpenSSH-Win64'
    $zip  = Join-Path $env:TEMP 'OpenSSH-Win64.zip'
    $url  = 'https://github.com/PowerShell/Win32-OpenSSH/releases/latest/download/OpenSSH-Win64.zip'
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

    try {
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -TimeoutSec 90
    } catch {
        # 자산 이름이 바뀌었을 경우 API 로 재시도
        $rel = Invoke-RestMethod 'https://api.github.com/repos/PowerShell/Win32-OpenSSH/releases/latest' -UseBasicParsing -TimeoutSec 30
        $a = $rel.assets | Where-Object { $_.name -like 'OpenSSH-Win64*.zip' } | Select-Object -First 1
        if (-not $a) { throw '릴리스에서 OpenSSH-Win64 zip 을 찾지 못했습니다.' }
        Invoke-WebRequest -Uri $a.browser_download_url -OutFile $zip -UseBasicParsing -TimeoutSec 180
    }

    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $env:ProgramFiles -Force
    Remove-Item $zip -Force -ErrorAction SilentlyContinue

    $p = [Environment]::GetEnvironmentVariable('Path','Machine')
    if ($p -notlike ('*' + $dest + '*')) {
        [Environment]::SetEnvironmentVariable('Path', ($p.TrimEnd(';') + ';' + $dest), 'Machine')
    }
    # 현재 프로세스에도 즉시 반영해야 아래 접속 단계에서 ssh.exe 를 바로 쓸 수 있다.
    if ($env:Path -notlike ('*' + $dest + '*')) { $env:Path = $env:Path.TrimEnd(';') + ';' + $dest }
    return $dest
}

function Install-SshFromZip {
    $dest = Expand-OpenSshZip
    if (-not (Test-Path (Join-Path $dest 'sshd.exe'))) { throw '압축 해제 후 sshd.exe 가 없습니다.' }
    New-Item -ItemType Directory -Force -Path (Join-Path $env:ProgramData 'ssh') | Out-Null
    & (Join-Path $dest 'install-sshd.ps1') | Out-Null
    Native (Join-Path $dest 'ssh-keygen.exe') @('-A') | Out-Null
    # 배포판마다 파라미터가 달라서 실패해도 설치 자체는 유효하다. 치명적으로 다루지 않는다.
    $fix = Join-Path $dest 'FixHostFilePermissions.ps1'
    if (Test-Path $fix) {
        try { & $fix -Confirm:$false | Out-Null } catch { try { & $fix | Out-Null } catch {} }
    }
}

function Install-SshFromWinget {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { throw 'winget 이 없습니다.' }
    $code = Native 'winget' @(
        'install','--id','Microsoft.OpenSSH.Beta','-e','--silent',
        '--accept-source-agreements','--accept-package-agreements','--disable-interactivity'
    )
    if ($code -ne 0) { throw ('winget 종료 코드 ' + $code) }
}

function Install-SshFromCapability {
    $au = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
    $old = $null; $touched = $false
    if (Test-Path $au) {
        $old = (Get-ItemProperty -Path $au -Name UseWUServer -ErrorAction SilentlyContinue).UseWUServer
        if ($old -eq 1) {
            Warn 'WSUS 정책 감지 - 설치하는 동안만 우회한다.'
            Set-ItemProperty -Path $au -Name UseWUServer -Value 0
            Restart-Service wuauserv -ErrorAction SilentlyContinue
            $touched = $true
        }
    }
    try {
        # 와일드카드 조회는 그 자체로 수 분이 걸려서 생략하고 정식 이름을 바로 지정한다.
        Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' | Out-Null
    } finally {
        if ($touched) {
            Set-ItemProperty -Path $au -Name UseWUServer -Value $old
            Restart-Service wuauserv -ErrorAction SilentlyContinue
        }
    }
}

# 클라이언트 전용. 서버 서비스를 등록하지 않으므로 이 PC 는 열리지 않는다.
function Install-SshClientFromCapability {
    Add-WindowsCapability -Online -Name 'OpenSSH.Client~~~~0.0.1.0' | Out-Null
}
function Install-SshClientFromZip {
    $dest = Expand-OpenSshZip
    if (-not (Test-Path (Join-Path $dest 'ssh.exe'))) { throw '압축 해제 후 ssh.exe 가 없습니다.' }
}

function Install-TsFromMsi {
    $msi = Join-Path $env:TEMP 'tailscale-setup.msi'
    $url = 'https://pkgs.tailscale.com/stable/tailscale-setup-latest-amd64.msi'
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
    Invoke-WebRequest -Uri $url -OutFile $msi -UseBasicParsing -TimeoutSec 180
    $p = Start-Process 'msiexec.exe' -ArgumentList @('/i', ('"' + $msi + '"'), '/quiet', '/norestart', 'TS_UNATTENDEDMODE=always') -Wait -PassThru
    Remove-Item $msi -Force -ErrorAction SilentlyContinue
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) { throw ('msiexec 종료 코드 ' + $p.ExitCode) }
    if (-not (Test-Path $TS)) { throw '설치 후 tailscale.exe 가 없습니다.' }
}

function Install-TsFromWinget {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { throw 'winget 이 없습니다.' }
    $code = Native 'winget' @(
        'install','--id','tailscale.tailscale','-e','--silent',
        '--accept-source-agreements','--accept-package-agreements','--disable-interactivity'
    )
    if ($code -ne 0) { throw ('winget 종료 코드 ' + $code) }
    if (-not (Test-Path $TS)) { throw '설치 후 tailscale.exe 가 없습니다.' }
}

function Try-Install($methods) {
    foreach ($m in $methods) {
        try {
            Info ($m.n + ' 시도 중...')
            & $m.f
            Ok ($m.n + ' 로 설치 완료')
            return $true
        } catch {
            Warn ($m.n + ' 실패: ' + $_.Exception.Message)
        }
    }
    return $false
}

# ══════════════════════════════════════════════════════════════
#  접속 대상 관리
# ══════════════════════════════════════════════════════════════

# 상대 PC 의 Windows 계정명은 Tailscale 이 알려주지 않는다. 한 번 입력하면 기억해 둔다.
function Get-SavedUser([string]$ip) {
    if (-not (Test-Path $UserStore)) { return $null }
    foreach ($l in (Get-Content $UserStore -ErrorAction SilentlyContinue)) {
        $kv = $l -split '=', 2
        if ($kv.Count -eq 2 -and $kv[0] -eq $ip) { return $kv[1] }
    }
    return $null
}

function Save-User([string]$ip, [string]$u) {
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path $UserStore) | Out-Null
        $lines = @()
        if (Test-Path $UserStore) {
            $lines = @(Get-Content $UserStore | Where-Object { (($_ -split '=', 2)[0]) -ne $ip })
        }
        $lines += ($ip + '=' + $u)
        Set-Content -Path $UserStore -Value $lines -Encoding UTF8
    } catch {}
}

function Get-Peers {
    try {
        $j = (& $TS status --json 2>$null | Out-String | ConvertFrom-Json)
    } catch { return @() }
    $out = @()
    if ($j -and $j.Peer) {
        foreach ($pr in $j.Peer.PSObject.Properties) {
            $v  = $pr.Value
            $ip = @($v.TailscaleIPs) | Where-Object { $_ -like '100.*' } | Select-Object -First 1
            if (-not $ip) { continue }
            $out += [pscustomobject]@{
                Name   = [string]$v.HostName
                IP     = [string]$ip
                Online = [bool]$v.Online
                OS     = [string]$v.OS
            }
        }
    }
    return @($out | Sort-Object -Property @{ Expression = 'Online'; Descending = $true }, 'Name')
}

function Resolve-Ssh {
    $c = Get-Command ssh.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($p in @(
        (Join-Path $env:ProgramFiles 'OpenSSH-Win64\ssh.exe'),
        (Join-Path $env:WinDir 'System32\OpenSSH\ssh.exe')
    )) { if (Test-Path $p) { return $p } }
    return $null
}

# ══════════════════════════════════════════════════════════════
#  Tailscale 인증 - 전부 터미널 안에서 처리한다
#
#  Tailscale 계정 로그인 자체는 OAuth 라 웹을 거쳐야 한다. 그래서
#  브라우저 로그인 대신 인증 키만 쓴다. 키를 얻는 길은 두 가지다.
#    - 상대가 보내준 키를 붙여넣는다 (접속받는 쪽. 웹을 전혀 안 본다)
#    - 저장된 API 토큰으로 직접 발급한다 (tailnet 주인. 웹은 최초 1회뿐)
# ══════════════════════════════════════════════════════════════

# ProtectedData 는 System.Security.dll 에 있고 PS 5.1 이 기본으로 로드하지 않는다.
try { Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue } catch {}

# API 토큰은 DPAPI 로 이 사용자 계정에서만 풀리도록 암호화해 둔다.
# 파일이 통째로 복사돼도 다른 계정이나 다른 PC 에서는 복호화되지 않는다.
function Write-TsToken([string]$token) {
    New-Item -ItemType Directory -Force -Path (Split-Path $TokenStore) | Out-Null
    $b = [Text.Encoding]::UTF8.GetBytes($token)
    $e = [Security.Cryptography.ProtectedData]::Protect(
            $b, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    [IO.File]::WriteAllBytes($TokenStore, $e)
}

function Read-TsToken {
    if (-not (Test-Path $TokenStore)) { return $null }
    try {
        $e = [IO.File]::ReadAllBytes($TokenStore)
        $b = [Security.Cryptography.ProtectedData]::Unprotect(
                $e, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        return [Text.Encoding]::UTF8.GetString($b)
    } catch {
        # 다른 관리자 계정으로 승격했거나 파일이 깨진 경우. 없는 것으로 취급한다.
        return $null
    }
}

# Invoke-RestMethod 는 4xx 응답 본문을 예외 메시지에 담아 주지 않는다.
# 원인을 알려면 스트림에서 직접 읽어야 한다.
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

# capabilities.devices.create 를 비워 두면 일회용 + 태그 없는 키가 나온다.
# 사용자 access token 으로 만드는 키는 태그가 필요 없다.
function New-TsAuthKey([string]$token, [int]$seconds, [string]$desc) {
    $body = @{
        keyType       = 'auth'
        description   = $desc
        expirySeconds = $seconds
        capabilities  = @{ devices = @{ create = @{
            reusable      = $false
            ephemeral     = $false
            preauthorized = $true
        } } }
    } | ConvertTo-Json -Depth 6

    $r = Invoke-RestMethod -Method Post -Uri $TsApi `
            -Headers @{ Authorization = ('Bearer ' + $token) } `
            -ContentType 'application/json' -Body $body -TimeoutSec 30
    if (-not $r.key) { throw 'API 응답에 key 필드가 없다.' }
    return [string]$r.key
}

# 토큰을 받아 실제로 키를 하나 만들어 본 뒤에만 저장한다.
# 동작을 확인하지 않은 토큰을 저장해 두면 나중에 엉뚱한 데서 실패한다.
function Register-TsToken([int]$seconds, [string]$desc) {
    $t = Ask-Value -Title 'Tailscale API 토큰 등록' `
        -Question 'API 액세스 토큰(tskey-api-... )을 붙여넣어라.' `
        -Notes @(
            '웹을 거치는 것은 이 한 번뿐이다. 이후로는 터미널에서 키를 발급한다.',
            '발급 위치 : https://login.tailscale.com/admin/settings/keys',
            '            Keys 페이지에서 Generate access token',
            '',
            '토큰은 이 PC 의 이 계정에서만 풀리도록 암호화해 저장한다.',
            '접속을 받기만 하는 PC 에는 토큰을 넣을 필요가 없다.'
        ) -Label 'API 토큰'
    if ([string]::IsNullOrWhiteSpace($t)) { return $null }
    $t = $t.Trim()

    Clear-Host
    Write-Host ''
    Info '토큰 확인 중... 키를 하나 발급해 본다.'
    try {
        $k = New-TsAuthKey $t $seconds $desc
    } catch {
        Write-Host ''
        Bad '토큰으로 키를 발급하지 못했다. 저장하지 않는다.'
        Info (Get-WebErrorText $_)
        Info '401 이면 토큰이 틀렸거나 만료된 것이다.'
        Pause-Key '아무 키나 누르면 돌아갑니다'
        return $null
    }
    Write-TsToken $t
    Ok '토큰 확인 및 저장 완료'
    return $k
}

# 발급된 키를 화면에 크게 띄운다. 상대에게 그대로 전달하면 된다.
function Show-AuthKey([string]$key, [string]$title, [string]$note) {
    $copied = $false
    try { Set-Clipboard -Value $key; $copied = $true } catch {}
    Clear-Host
    Write-Host ''
    Write-Host ('   ' + $title) -ForegroundColor Cyan
    Write-Host ''
    Write-Host ('   ' + $note)
    Write-Host ''
    # 상자에 넣으면 창이 좁을 때 Vis-Trim 에 잘린다. 잘린 키는 쓸 수 없으므로
    # 키만은 상자 밖에 그대로 찍는다.
    Write-Host ('   ' + $key) -ForegroundColor Yellow
    Write-Host ''
    Write-Host '   이 키는 1회용이다. 한 번 쓰면 다시 못 쓴다.' -ForegroundColor DarkGray
    if ($copied) { Write-Host '   클립보드에 복사해 두었다. 그대로 붙여넣으면 된다.' -ForegroundColor DarkGray }
    else         { Write-Host '   드래그해서 복사한 뒤 상대에게 전달하라.' -ForegroundColor DarkGray }
    Pause-Key '아무 키나 누르면 계속합니다'
}

# 연결에 쓸 인증 키를 얻는다. 브라우저는 어느 경로에서도 열리지 않는다.
# 사용자가 그만두면 $null 을 돌려준다.
function Get-AuthKey {
    while ($true) {
        $tok    = Read-TsToken
        $items  = @()
        $inotes = @()

        if ($tok) {
            $items  += 'API 토큰으로 키를 발급해 바로 연결'
            $inotes += '저장된 토큰으로 1회용 키를 만들어 이 PC 를 연결한다. 입력할 것이 없다.'
        }
        $items  += '인증 키 붙여넣기'
        $inotes += '상대가 보내준 tskey-auth-... 를 입력한다. 접속받는 쪽은 이것만 쓰면 된다.'

        if ($tok) {
            $items  += 'API 토큰 다시 등록'
            $inotes += '토큰이 만료됐거나 다른 계정으로 바꿀 때.'
        } else {
            $items  += 'API 토큰 등록 (최초 1회)'
            $inotes += 'tailnet 주인만 하면 된다. 이후 웹 없이 키를 발급할 수 있다.'
        }
        $items  += '__RULE__'; $inotes += ''
        $items  += '종료'
        $inotes += '연결하지 않고 끝낸다.'

        $sel = Menu-Single -Title 'Tailscale 연결' -Items $items -ItemNotes $inotes -Start 0 -NoEsc `
            -Note "  브라우저는 열리지 않는다. 인증 키로만 연결한다.`n  키가 없고 tailnet 주인도 아니라면, 주인에게 키를 받아야 한다."

        $label = $items[$sel]

        if ($label -eq '종료') { return $null }

        if ($label -eq 'API 토큰으로 키를 발급해 바로 연결') {
            Clear-Host
            Write-Host ''
            Info '키 발급 중...'
            try {
                return (New-TsAuthKey $tok 3600 'ssh-remote self')
            } catch {
                Write-Host ''
                Bad '키 발급에 실패했다.'
                Info (Get-WebErrorText $_)
                Pause-Key '아무 키나 누르면 돌아갑니다'
                continue
            }
        }

        if ($label -eq '인증 키 붙여넣기') {
            $k = Ask-Value -Title 'Tailscale 연결' `
                -Question '인증 키를 붙여넣어라.' `
                -Notes @(
                    'tskey-auth- 로 시작하는 문자열이다.',
                    '접속을 받을 PC 는 이것만 있으면 된다. 웹에 들어갈 일이 없다.'
                ) -Label '인증 키'
            if (-not [string]::IsNullOrWhiteSpace($k)) { return $k.Trim() }
            continue
        }

        # 토큰 등록. 성공하면 그 자리에서 발급된 키를 그대로 쓴다.
        $k = Register-TsToken 3600 'ssh-remote self'
        if ($k) { return $k }
    }
}

# 상대에게 건네줄 키를 발급한다. Tailscale 연결 여부와 무관하게 언제든 부를 수 있어야
# 한다. 이미 연결된 PC 는 Get-AuthKey 를 타지 않으므로, 여기를 거치지 않으면 토큰을
# 등록할 기회조차 없다.
function Issue-InviteKey {
    $tok = Read-TsToken
    if (-not $tok) {
        # 토큰 등록 과정에서 확인용으로 키가 하나 발급된다. 버리지 않고 그대로 쓴다.
        $k = Register-TsToken 86400 'ssh-remote invite'
        if (-not $k) { return }
        Show-AuthKey $k '친구에게 줄 인증 키' '아래 키를 상대에게 그대로 전달하라. 24시간 안에 써야 한다.'
        return
    }
    Clear-Host
    Write-Host ''
    Info '키 발급 중...'
    try {
        $k = New-TsAuthKey $tok 86400 'ssh-remote invite'
        Show-AuthKey $k '친구에게 줄 인증 키' '아래 키를 상대에게 그대로 전달하라. 24시간 안에 써야 한다.'
    } catch {
        Write-Host ''
        Bad '키 발급에 실패했다.'
        Info (Get-WebErrorText $_)
        Pause-Key '아무 키나 누르면 돌아갑니다'
    }
}

# ══════════════════════════════════════════════════════════════
#  화면 1 - 역할 선택
# ══════════════════════════════════════════════════════════════

$roleNote = @'
  원격 접속 설정  -  OpenSSH + Tailscale

  포트포워딩이나 공유기 설정은 필요 없다.
  22번 포트는 인터넷이 아니라 Tailscale 망에만 열린다.
  브라우저는 열리지 않는다. 모든 과정이 이 창 안에서 끝난다.
'@

$IsServer = $false
while ($true) {
    $ritems = @(
        '이 PC 로 접속을 받는다',
        '다른 PC 에 접속만 한다',
        '__RULE__',
        '친구에게 줄 인증 키 발급',
        '__RULE__',
        '종료'
    )
    $rnotes = @(
        '22번을 정해진 시간 동안만 연다. 원격 지원을 받을 PC 쪽.',
        '이 PC 는 전혀 열리지 않는다. 접속하는 쪽 전용.',
        '',
        '상대가 붙여넣을 1회용 키를 만들어 화면에 띄운다. 여기서 바로 확인할 수 있다.',
        '',
        '아무것도 바꾸지 않고 끝낸다.'
    )
    $role   = Menu-Single -Title '이 PC 의 역할' -Note $roleNote -Items $ritems -ItemNotes $rnotes -Start 1 -NoEsc
    $rlabel = $ritems[$role]

    if ($rlabel -eq '종료') { exit 0 }
    # 키 발급은 역할과 무관하다. 발급만 하고 이 화면으로 돌아온다.
    if ($rlabel -eq '친구에게 줄 인증 키 발급') { Issue-InviteKey; continue }

    $IsServer = ($rlabel -eq '이 PC 로 접속을 받는다')
    break
}

# ══════════════════════════════════════════════════════════════
#  화면 2 - 개방 시간 (서버 역할일 때만)
# ══════════════════════════════════════════════════════════════

$Hours  = 4
$Expire = $null

if ($IsServer) {
    $hourNote = @'
  접속을 허용할 시간을 정한다.
  시간이 지나면 예약 작업이 방화벽을 자동으로 닫는다.
  창을 닫든 재부팅하든 만료 시각은 그대로 유지된다.
'@
    $hi = Menu-Single -Title '접속 허용 시간' -Note $hourNote -Items @(
        '1시간', '4시간', '12시간', '__RULE__', '무기한 (자동 차단 없음)'
    ) -ItemNotes @(
        '잠깐 봐주기만 할 때.',
        '기본값. 한 번 작업하기에 충분하다.',
        '길게 붙잡고 작업할 때.',
        '',
        '직접 닫기 전까지 계속 열려 있다. 권장하지 않는다.'
    ) -Start 1
    if ($hi -lt 0) { exit 0 }
    switch ($hi) {
        0 { $Hours = 1 }
        1 { $Hours = 4 }
        2 { $Hours = 12 }
        4 { $Hours = 0 }
    }
    $global:StepTotal = 6
} else {
    $global:StepTotal = 4
}

# ══════════════════════════════════════════════════════════════
#  화면 3 - 설치 및 설정 (로그가 흐르는 화면)
# ══════════════════════════════════════════════════════════════

Clear-Host
$sw = [Diagnostics.Stopwatch]::StartNew()
Write-Host '========================================================'
if ($IsServer) { Write-Host '   설치 및 설정  -  이 PC 로 접속을 받는다' }
else           { Write-Host '   설치 및 설정  -  다른 PC 에 접속만 한다' }
Write-Host '========================================================'
Write-Host ''
Write-Host '  진행 중에는 입력이 필요 없다. 그대로 기다리면 된다.' -ForegroundColor DarkGray

if ($IsServer) {

    # ── 설치 여부는 서비스 존재로만 판정한다. 온라인 카탈로그 조회를 안 하므로 즉시 끝난다.
    Step 'OpenSSH 서버 설치 상태 확인'
    $svc = Get-Service -Name sshd -ErrorAction SilentlyContinue
    if ($svc) {
        Ok 'sshd 이미 설치됨 - 설치 단계 건너뜀'
    } else {
        Info 'sshd 없음 - 설치 진행 (최대 몇 분 걸릴 수 있다)'
        $done = Try-Install @(
            @{ n = 'GitHub 공식 배포판(zip)'; f = { Install-SshFromZip } },
            @{ n = 'winget';                  f = { Install-SshFromWinget } },
            @{ n = 'Windows 기능(FoD, 느림)'; f = { Install-SshFromCapability } }
        )
        if (-not $done) { Die 'OpenSSH 를 설치할 수 있는 경로를 찾지 못했다.' }
        $svc = Get-Service -Name sshd -ErrorAction SilentlyContinue
        if (-not $svc) { Die 'sshd 서비스가 등록되지 않았다. 재부팅 후 다시 실행하라.' }
    }

    Step 'sshd 서비스 시작 및 자동 실행 등록'
    Set-Service -Name sshd -StartupType Automatic
    if ((Get-Service sshd).Status -ne 'Running') { Start-Service -Name sshd }
    $st = (Get-Service sshd).Status
    if ($st -ne 'Running') { Die ('sshd 기동 실패 (상태: ' + $st + ')') }
    Ok ('상태: ' + $st + ' / 시작 유형: 자동')

    # ── netsh 사용. NetSecurity 모듈 로드(1~2초)를 피한다.
    Step '방화벽 개방 및 자동 차단 예약'
    $code = Open-Access
    if ($code -ne 0) { Die ('netsh 방화벽 규칙 추가 실패 (코드 ' + $code + ')') }
    Ok ('인바운드 TCP 22 - ' + $TsRange + ' 에서만 허용')
    # 이 뒤로 중단되면 열린 채로 남는다. Abort-Script 가 이 값을 보고 정리를 제안한다.
    $global:AccessOpened = $true

    if ($Hours -gt 0) {
        $Expire = (Get-Date).AddHours($Hours)
        $tcode  = Register-CloseTask $Expire
        if ($tcode -ne 0) {
            Warn ('자동 차단 예약 실패 (코드 ' + $tcode + '). 끝나면 직접 닫아야 한다.')
            $Expire = $null
        } else {
            Ok ('자동 차단 예약됨 - ' + $Expire.ToString('yyyy-MM-dd HH:mm') + ' 에 닫힌다')
            Info ('예약 작업 이름: ' + $CloseTask + ' (SYSTEM 권한, 로그아웃 상태에서도 실행된다)')
        }
    } else {
        Remove-CloseTask
        Warn '무기한 개방이다. 자동 차단이 없으니 직접 닫아야 한다.'
    }

} else {

    Step 'SSH 클라이언트 확인'
    if (Resolve-Ssh) {
        Ok 'ssh.exe 이미 있음 - 설치 단계 건너뜀'
    } else {
        Info 'ssh.exe 없음 - 클라이언트만 설치한다 (서버는 설치하지 않는다)'
        $done = Try-Install @(
            @{ n = 'Windows 기능(OpenSSH 클라이언트)'; f = { Install-SshClientFromCapability } },
            @{ n = 'GitHub 공식 배포판(zip)';          f = { Install-SshClientFromZip } }
        )
        if (-not $done) { Die 'SSH 클라이언트를 설치할 수 있는 경로를 찾지 못했다.' }
        if (-not (Resolve-Ssh)) { Die '설치 후에도 ssh.exe 를 찾지 못했다.' }
        Ok 'ssh.exe 준비됨'
    }

    # 전에 이 PC 를 서버로 쓴 적이 있다면 그 흔적을 확실히 지운다.
    Close-Access
    Remove-CloseTask
    Ok '이 PC 의 22번 인바운드 규칙 없음 - 접속을 받지 않는다'
}

Step 'Tailscale 설치 상태 확인'
if (Test-Path $TS) {
    Ok 'Tailscale 이미 설치됨 - 설치 단계 건너뜀'
} else {
    Info 'Tailscale 없음 - 설치 진행'
    $done = Try-Install @(
        @{ n = '공식 MSI'; f = { Install-TsFromMsi } },
        @{ n = 'winget';   f = { Install-TsFromWinget } }
    )
    if (-not $done) { Die 'Tailscale 을 설치할 수 있는 경로를 찾지 못했다.' }
}

$tsSvc = Get-Service -Name Tailscale -ErrorAction SilentlyContinue
if (-not $tsSvc) { Die 'Tailscale 서비스가 등록되지 않았다. 재부팅 후 다시 실행하라.' }
Set-Service -Name Tailscale -StartupType Automatic
if ((Get-Service Tailscale).Status -ne 'Running') { Start-Service -Name Tailscale }
Ok '서비스 상태: Running / 시작 유형: 자동'

# ── 이미 로그인돼 있으면 인증 키를 묻지 않는다. 재실행이 빨라진다.
Step 'Tailscale 네트워크 연결'
$state = ''
try { $state = [string]((& $TS status --json 2>$null | Out-String | ConvertFrom-Json).BackendState) } catch {}

if ($state -eq 'Running') {
    Ok '이미 연결되어 있음 - 로그인 단계 건너뜀'
} else {
    $key = Get-AuthKey
    if (-not $key) {
        Clear-Host
        Write-Host ''
        Info '연결하지 않고 끝낸다. 설치된 것은 그대로 남는다.'
        Pause-Key '아무 키나 누르면 닫힙니다'
        exit 0
    }

    Clear-Host
    Write-Host ''
    Info '인증 키로 연결 중... 브라우저는 열리지 않는다.'
    Write-Host ''
    # --authkey 를 주면 대화형 로그인 경로를 타지 않는다. 브라우저가 열릴 일이 없다.
    $code = NativeShow $TS @('up','--unattended','--accept-dns=false','--timeout=180s',('--authkey=' + $key))
    Write-Host ''
    if ($code -ne 0) { Die ('tailscale up 실패 (코드 ' + $code + '). 키가 만료됐거나 이미 사용된 1회용 키다.') }
    Ok '네트워크 연결됨'
}

Step '연결 상태 확인'
$tsip = $null
foreach ($i in 1..20) {
    $o = (& $TS ip -4 2>$null | Select-Object -First 1)
    if ($o -and $o -match '^100\.') { $tsip = $o.Trim(); break }
    Start-Sleep -Milliseconds 500
}
if (-not $tsip) { Die '100.x 주소를 받지 못했다. tailscale status 로 확인하라.' }

if ($IsServer) {
    # .NET API 로 즉시 확인. Get-NetTCPConnection 모듈 로드를 피한다.
    $listen = $false
    foreach ($i in 1..12) {
        $l = [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()
        if ($l | Where-Object { $_.Port -eq 22 }) { $listen = $true; break }
        Start-Sleep -Milliseconds 250
    }
    if (-not $listen) { Die '22번 포트가 LISTEN 상태가 아니다. sshd 기동에 실패했다.' }
    Ok ('LISTEN 확인됨 / 이 PC 주소: ' + $tsip)
} else {
    Ok ('이 PC 주소: ' + $tsip + ' (수신 포트 없음)')
}
$sw.Stop()
Ok ('설정 완료 - 소요 시간 ' + [Math]::Round($sw.Elapsed.TotalSeconds,1) + '초')
Pause-Key '아무 키나 누르면 상태 화면으로 넘어갑니다'

# ══════════════════════════════════════════════════════════════
#  화면 4 - 이 PC 의 상태
# ══════════════════════════════════════════════════════════════

$isMs = $false
try {
    $u = Get-LocalUser -Name $env:USERNAME -ErrorAction Stop
    $isMs = ($u.PrincipalSource -eq 'MicrosoftAccount')
} catch {}

$lines = @()
if ($IsServer) {
    $lines += ('사용자 계정 : ' + $env:USERNAME)
    $lines += ''
    $lines += ('  ssh ' + $env:USERNAME + '@' + $tsip)
    $lines += ''
    if ($Expire) {
        $lines += ('접속 허용 : ' + $Expire.ToString('yyyy-MM-dd HH:mm') + ' 까지 (' + $Hours + '시간)')
        $lines += '그 시각이 되면 방화벽이 자동으로 닫힌다.'
        $lines += '창을 닫아도, 재부팅해도 유지된다.'
    } else {
        $lines += '접속 허용 : 무기한 (자동 차단 없음)'
        $lines += '다 쓰고 나면 직접 닫아야 한다.'
    }
    $lines += '__RULE__'
    if ($isMs) { $lines += 'Microsoft 계정이다. SSH 암호로 Microsoft 계정 암호를 넣어라.' }
    else       { $lines += '암호는 Windows 로그인 암호다. PIN 은 쓸 수 없다.' }
} else {
    $lines += '이 PC 는 접속을 받지 않는다.'
    $lines += '22번 인바운드 방화벽 규칙이 없다.'
    $lines += '__RULE__'
    $lines += ('이 PC 의 Tailscale 주소 : ' + $tsip)
}

Draw-Box -Title '이 PC 의 상태' -Lines $lines -Cursor -1 `
    -Note ($(if ($IsServer) { '  상대에게 알려줄 내용' } else { '  설정 결과' }))
Pause-Key '아무 키나 누르면 접속 화면으로 넘어갑니다'

# ══════════════════════════════════════════════════════════════
#  화면 5 - 다른 PC 에 접속하기
# ══════════════════════════════════════════════════════════════

$sshExe = Resolve-Ssh

while ($true) {
    $peers  = Get-Peers
    $items  = @()
    $inotes = @()

    foreach ($p in $peers) {
        $mark = if ($p.Online) { 'online ' } else { 'offline' }
        $items  += ((Vis-Pad $p.Name 18) + ' ' + (Vis-Pad $p.IP 15) + ' ' + $mark)
        $inotes += ('OS: ' + $p.OS + '   ' + $(if ($p.Online) { '지금 접속할 수 있다.' } else { '꺼져 있거나 Tailscale 이 꺼져 있다.' }))
    }
    if ($peers.Count -gt 0) { $items += '__RULE__'; $inotes += '' }
    $items  += '목록 새로고침'
    $inotes += '상대가 방금 접속했다면 새로고침하면 나타난다.'
    $items  += '친구에게 줄 인증 키 발급'
    $inotes += '1회용 키를 만들어 화면에 띄운다. 토큰이 없으면 등록부터 안내한다.'
    $items  += '종료'
    $inotes += '접속하지 않고 끝낸다.'

    $note = if ($peers.Count -eq 0) {
        "  연결 가능한 PC 가 아직 없다.`n  상대방도 이 파일을 실행하고 인증 키로 연결하면 나타난다."
    } else { '  같은 Tailscale 망에 있는 PC 목록' }

    $sel = Menu-Single -Title '다른 PC 에 접속하기' -Note $note -Items $items -ItemNotes $inotes -Start 0
    if ($sel -lt 0) { break }                                          # Esc

    # 항목 위치가 아니라 이름으로 분기한다. 메뉴에 항목이 늘어도 어긋나지 않는다.
    $label = $items[$sel]
    if ($label -eq '종료')          { break }
    if ($label -eq '목록 새로고침') { continue }
    if ($label -eq '__RULE__')      { continue }

    if ($label -eq '친구에게 줄 인증 키 발급') { Issue-InviteKey; continue }

    $target = $peers[$sel]

    # 계정명은 Tailscale 이 알려주지 않는다. 저장돼 있으면 선택지로 먼저 보여준다.
    $saved = Get-SavedUser $target.IP
    $ru = $null
    if ($saved) {
        $ui = Menu-Single -Title ($target.Name + ' 에 접속') -Items @(
            ($saved + '  (저장된 계정)'), '다른 계정 입력'
        ) -ItemNotes @(
            '전에 이 PC 에 접속할 때 쓴 계정이다.',
            '계정이 바뀌었다면 여기서 새로 입력한다.'
        ) -Note ('  ' + $target.IP) -Start 0
        if ($ui -lt 0) { continue }
        if ($ui -eq 0) { $ru = $saved }
    }
    if (-not $ru) {
        $ru = Ask-Value -Title ($target.Name + ' 에 접속') `
            -Question '상대 PC 의 사용자 계정을 입력하라.' `
            -Notes @('상대 PC 화면에 뜬 ssh 명령에서 @ 앞부분이다.', ('주소 : ' + $target.IP)) `
            -Label '사용자 계정'
        if ([string]::IsNullOrWhiteSpace($ru)) { continue }
    }
    $ru = $ru.Trim()
    Save-User $target.IP $ru

    if (-not $sshExe) { Bad 'ssh.exe 를 찾지 못했다. 창을 닫고 다시 실행하라.'; break }

    Clear-Host
    Write-Host ''
    Write-Host ('   ssh ' + $ru + '@' + $target.IP) -ForegroundColor Yellow
    Write-Host ''
    Write-Host '   [입력 대기 중] 처음 접속이면 fingerprint 확인에 yes 를 입력하고 엔터,' -ForegroundColor Yellow
    Write-Host '                  그 다음 상대 PC 의 Windows 암호를 입력하고 엔터.' -ForegroundColor Yellow
    Write-Host '                  (암호는 화면에 표시되지 않는다. 끊으려면 exit)' -ForegroundColor DarkGray
    Write-Host ''

    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $sshExe ($ru + '@' + $target.IP) } catch { Bad $_.Exception.Message }
    $ErrorActionPreference = $old

    Write-Host ''
    Info 'SSH 세션이 끝났다.'
    Pause-Key '아무 키나 누르면 목록으로 돌아갑니다'
}

# ══════════════════════════════════════════════════════════════
#  화면 6 - 종료
# ══════════════════════════════════════════════════════════════

if ($IsServer) {
    $stateLine = if ($Expire) {
        '  이 PC 는 ' + $Expire.ToString('yyyy-MM-dd HH:mm') + ' 까지 접속을 받는 상태다.'
    } else {
        '  이 PC 는 무기한 접속을 받는 상태다.'
    }
    $ei = Menu-Single -Title '끝내기' -Note $stateLine -Items @(
        '그대로 두고 종료', '지금 즉시 접속 차단'
    ) -ItemNotes @(
        '예약된 시각까지는 상대가 접속할 수 있다.',
        '방화벽 규칙과 예약 작업을 지금 바로 지운다.'
    ) -Start 0 -NoEsc

    if ($ei -eq 1) {
        Clear-Host
        Write-Host ''
        Close-Access
        Remove-CloseTask
        $global:AccessOpened = $false
        Ok '접속을 차단했다. 이 PC 는 더 이상 접속을 받지 않는다.'
        Info '다시 열려면 이 파일을 또 실행하면 된다.'
    }
}

Pause-Key '아무 키나 누르면 닫힙니다'
exit 0
