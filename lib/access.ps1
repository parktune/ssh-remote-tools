# 22번 포트 개방/차단과 만료 예약. 상태는 "우리 규칙이 존재하는가" 하나로 판정한다.
#
# netsh 의 출력은 한국어 로캘에서 파싱할 수 없다. 대신 종료 코드만 쓴다.
#   netsh advfirewall firewall show rule name=<X>   →  있으면 0, 없으면 1
# 그래서 닫을 때는 비활성화(enable=No)가 아니라 삭제한다. 그래야 존재 여부가
# 곧 개방 여부가 되어 상태를 한 번의 호출로 알 수 있다.

# OpenSSH 는 설치 경로에 따라 서로 다른 이름의 광역 규칙을 만든다.
#   Windows 기능(FoD)  : OpenSSH-Server-In-TCP
#   winget / MSI 설치본 : OpenSSH SSH Server (sshd)
# 둘 다 RemoteIP=Any 라서 남겨 두면 22번이 사설망 전체에 열린다.
# 우리 규칙을 Tailscale 대역으로 좁혀 놓아도 이것들이 살아 있으면 의미가 없다.
$Script:KnownBroadRules = @('OpenSSH-Server-In-TCP', 'OpenSSH SSH Server (sshd)')

function Test-RuleExists([string]$name) {
    return ((Native 'netsh' @('advfirewall','firewall','show','rule',('name=' + $name))) -eq 0)
}

function Test-AccessOpen { return (Test-RuleExists $Script:RuleName) }

# 22번을 여는 광역 규칙을 전부 찾아 끈다. 끈 규칙의 이름을 돌려준다.
function Disable-BroadSshRules {
    $hit = @()

    # 1단계: 알려진 이름으로 즉시 처리. netsh 라 빠르다.
    foreach ($n in $Script:KnownBroadRules) {
        if (Test-RuleExists $n) {
            Native 'netsh' @('advfirewall','firewall','set','rule',('name=' + $n),'new','enable=No') | Out-Null
            $hit += $n
        }
    }

    # 2단계: 이름이 다른 규칙이 더 있을 수 있다. CIM 조회는 몇 초 걸리지만
    # 이 함수는 개방할 때 한 번만 부르므로 감당할 수 있다. 실패해도 1단계는 유효하다.
    try {
        $f22 = Get-NetFirewallPortFilter -ErrorAction Stop |
               Where-Object { @($_.LocalPort) -contains '22' }
        if ($f22) {
            $ids = @{}
            foreach ($f in $f22) { $ids[[string]$f.InstanceID] = $true }
            $rules = Get-NetFirewallRule -Direction Inbound -Action Allow -Enabled True -ErrorAction Stop |
                     Where-Object { $ids.ContainsKey([string]$_.Name) -and $_.DisplayName -ne $Script:RuleName }
            foreach ($r in $rules) {
                Disable-NetFirewallRule -InputObject $r -ErrorAction SilentlyContinue
                if ($hit -notcontains $r.DisplayName) { $hit += $r.DisplayName }
            }
        }
    } catch {
        # NetSecurity 모듈이 없거나 조회가 막힌 환경. 1단계 결과만 가지고 간다.
    }
    return @($hit)
}

function Open-Access {
    Native 'netsh' @('advfirewall','firewall','delete','rule',('name=' + $Script:RuleName)) | Out-Null
    Native 'netsh' @('advfirewall','firewall','delete','rule',('name=' + $Script:OldRule))  | Out-Null
    return (Native 'netsh' @(
        'advfirewall','firewall','add','rule',('name=' + $Script:RuleName),
        'dir=in','action=allow','protocol=TCP','localport=22',
        ('remoteip=' + $Script:TsRange),'profile=any'
    ))
}

function Close-Access {
    Native 'netsh' @('advfirewall','firewall','delete','rule',('name=' + $Script:RuleName)) | Out-Null
    Native 'netsh' @('advfirewall','firewall','delete','rule',('name=' + $Script:OldRule))  | Out-Null
}

function Remove-CloseTask { Native 'schtasks' @('/Delete','/TN',$Script:CloseTask,'/F') | Out-Null }

# 예약 작업은 XML 로 등록한다. schtasks 의 /ST /SD 인자는 시스템 날짜 형식을 타서
# 한국어 로캘에서 실패하지만, XML 의 StartBoundary 는 ISO 8601 고정이라 안전하다.
function Register-CloseTask([datetime]$when) {
    Remove-CloseTask
    $iso  = $when.ToString('yyyy-MM-ddTHH:mm:ss')
    # Close-Access 와 같은 일을 해야 한다. 삭제이지 비활성화가 아니다.
    # ($args 는 PowerShell 자동 변수라 이름을 피한다)
    $netshArgs = 'advfirewall firewall delete rule name="' + $Script:RuleName + '"'
    $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>SSH remote access auto-close</Description></RegistrationInfo>
  <Triggers><TimeTrigger><StartBoundary>$iso</StartBoundary><Enabled>true</Enabled></TimeTrigger></Triggers>
  <Principals><Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled><Hidden>false</Hidden><RunOnlyIfIdle>false</RunOnlyIfIdle><WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT10M</ExecutionTimeLimit><Priority>7</Priority>
  </Settings>
  <Actions Context="Author"><Exec><Command>netsh.exe</Command><Arguments>$netshArgs</Arguments></Exec></Actions>
</Task>
"@
    $path = Join-Path $env:TEMP 'ssh-remote-close.xml'
    [IO.File]::WriteAllText($path, $xml, [Text.Encoding]::Unicode)   # schtasks 는 UTF-16 을 요구한다
    $code = Native 'schtasks' @('/Create','/TN',$Script:CloseTask,'/XML',$path,'/F')
    Remove-Item $path -Force -ErrorAction SilentlyContinue
    if ($code -ne 0) { return $code }
    return (Native 'schtasks' @('/Query','/TN',$Script:CloseTask))   # 출력 파싱 없이 존재만 확인
}

function Set-Expiry($when) {
    Ensure-StateDir
    if ($when) { Set-Content -Path $Script:ExpiryFile -Value $when.ToString('o') -Encoding ASCII }
    elseif (Test-Path $Script:ExpiryFile) { Remove-Item $Script:ExpiryFile -Force -ErrorAction SilentlyContinue }
}

function Get-Expiry {
    if (-not (Test-Path $Script:ExpiryFile)) { return $null }
    try { return [datetime]::Parse((Get-Content $Script:ExpiryFile -Raw).Trim()) } catch { return $null }
}
