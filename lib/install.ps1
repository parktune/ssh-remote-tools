# OpenSSH 서버와 Tailscale 설치. 각각 빠른 경로부터 순서대로 시도한다.

function Expand-OpenSshZip {
    $dest = Join-Path $env:ProgramFiles 'OpenSSH-Win64'
    $zip  = Join-Path $env:TEMP 'OpenSSH-Win64.zip'
    $url  = 'https://github.com/PowerShell/Win32-OpenSSH/releases/latest/download/OpenSSH-Win64.zip'
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
    if ($env:Path -notlike ('*' + $dest + '*')) { $env:Path = $env:Path.TrimEnd(';') + ';' + $dest }
    return $dest
}

function Install-SshFromZip {
    $dest = Expand-OpenSshZip
    if (-not (Test-Path (Join-Path $dest 'sshd.exe'))) { throw '압축 해제 후 sshd.exe 가 없습니다.' }
    New-Item -ItemType Directory -Force -Path (Join-Path $env:ProgramData 'ssh') | Out-Null
    & (Join-Path $dest 'install-sshd.ps1') | Out-Null
    Native (Join-Path $dest 'ssh-keygen.exe') @('-A') | Out-Null
    # 배포판마다 파라미터가 달라서 실패해도 설치 자체는 유효하다.
    $fix = Join-Path $dest 'FixHostFilePermissions.ps1'
    if (Test-Path $fix) { try { & $fix -Confirm:$false | Out-Null } catch { try { & $fix | Out-Null } catch {} } }
}

function Install-SshFromWinget {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { throw 'winget 이 없습니다.' }
    $code = Native 'winget' @('install','--id','Microsoft.OpenSSH.Beta','-e','--silent',
        '--accept-source-agreements','--accept-package-agreements','--disable-interactivity')
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

function Install-TsFromMsi {
    $msi = Join-Path $env:TEMP 'tailscale-setup.msi'
    Invoke-WebRequest -Uri 'https://pkgs.tailscale.com/stable/tailscale-setup-latest-amd64.msi' `
        -OutFile $msi -UseBasicParsing -TimeoutSec 180
    $p = Start-Process 'msiexec.exe' -ArgumentList @('/i', ('"' + $msi + '"'), '/quiet', '/norestart', 'TS_UNATTENDEDMODE=always') -Wait -PassThru
    Remove-Item $msi -Force -ErrorAction SilentlyContinue
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) { throw ('msiexec 종료 코드 ' + $p.ExitCode) }
    if (-not (Test-Path $Script:TsExe)) { throw '설치 후 tailscale.exe 가 없습니다.' }
}

function Install-TsFromWinget {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { throw 'winget 이 없습니다.' }
    $code = Native 'winget' @('install','--id','tailscale.tailscale','-e','--silent',
        '--accept-source-agreements','--accept-package-agreements','--disable-interactivity')
    if ($code -ne 0) { throw ('winget 종료 코드 ' + $code) }
    if (-not (Test-Path $Script:TsExe)) { throw '설치 후 tailscale.exe 가 없습니다.' }
}

function Try-Install($methods) {
    foreach ($m in $methods) {
        try { Info ($m.n + ' 시도 중...'); & $m.f; Ok ($m.n + ' 로 설치 완료'); return $true }
        catch { Warn ($m.n + ' 실패: ' + $_.Exception.Message) }
    }
    return $false
}

# 설치 + 서비스 기동까지. 이미 있으면 건너뛴다.
function Ensure-OpenSsh {
    if (Get-Service -Name sshd -ErrorAction SilentlyContinue) {
        Ok 'sshd 이미 설치됨'
    } else {
        Info '설치 진행 (최대 몇 분 걸릴 수 있다)'
        if (-not (Try-Install @(
            @{ n = 'GitHub 공식 배포판(zip)'; f = { Install-SshFromZip } },
            @{ n = 'winget';                  f = { Install-SshFromWinget } },
            @{ n = 'Windows 기능(FoD, 느림)'; f = { Install-SshFromCapability } }
        ))) { Die 'OpenSSH 를 설치할 수 있는 경로를 찾지 못했다.' }
        if (-not (Get-Service -Name sshd -ErrorAction SilentlyContinue)) { Die 'sshd 서비스가 등록되지 않았다. 재부팅 후 다시 실행하라.' }
    }
    Set-Service -Name sshd -StartupType Automatic
    if ((Get-Service sshd).Status -ne 'Running') { Start-Service -Name sshd }
    if ((Get-Service sshd).Status -ne 'Running') { Die 'sshd 기동 실패' }
    Ok '서비스 실행 중 / 시작 유형: 자동'
}

function Ensure-Tailscale {
    if (Test-Path $Script:TsExe) {
        Ok 'Tailscale 이미 설치됨'
    } else {
        Info '설치 진행'
        if (-not (Try-Install @(
            @{ n = '공식 MSI'; f = { Install-TsFromMsi } },
            @{ n = 'winget';   f = { Install-TsFromWinget } }
        ))) { Die 'Tailscale 을 설치할 수 있는 경로를 찾지 못했다.' }
    }
    if (-not (Get-Service -Name Tailscale -ErrorAction SilentlyContinue)) { Die 'Tailscale 서비스가 등록되지 않았다. 재부팅 후 다시 실행하라.' }
    Set-Service -Name Tailscale -StartupType Automatic
    if ((Get-Service Tailscale).Status -ne 'Running') { Start-Service -Name Tailscale }
    Ok '서비스 실행 중 / 시작 유형: 자동'
}
