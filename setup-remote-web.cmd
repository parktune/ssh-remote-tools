@echo off
setlocal EnableExtensions
chcp 65001 >nul
title 원격 접속 설정 (웹) - OpenSSH + Tailscale

:: 사용자가 클릭하는 것은 이 파일 하나다. 실제 로직은 lib\ 와 web\ 에 있고,
:: 이 파일은 권한 승격과 실행만 담당한다. 폴더 전체가 같이 다녀야 한다.

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

:: GitHub 에서 zip 으로 받아 풀면 모든 파일에 다운로드 표식(Zone.Identifier)이 붙는다.
:: -ExecutionPolicy Bypass 라 실행은 되지만, 표식을 지워 두면 이후 어떤 경로로 열어도 걸리지 않는다.
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -Path '%~dp0*' -Recurse -File -Include *.ps1,*.cmd,*.html,*.css,*.js,*.md -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue" 2>nul

if not exist "%~dp0lib\main.ps1" (
    echo.
    echo  [!] lib\main.ps1 이 없습니다.
    echo  [!] 이 파일은 lib\ 와 web\ 폴더와 한 세트입니다. 폴더 전체를 두세요.
    echo.
    echo  [입력 대기 중] 창을 닫으려면 아무 키나 누르세요.
    pause >nul
    exit /b 1
)

cls
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0lib\main.ps1"
set "rc=%ERRORLEVEL%"

:: 오류로 끝났을 때 더블클릭 창이 메시지를 데리고 사라지지 않게 잡아 둔다.
if not "%rc%"=="0" (
    echo.
    echo  [!] 종료 코드 %rc% 로 끝났습니다. 위 메시지를 확인하세요.
    echo.
    echo  [입력 대기 중] 창을 닫으려면 아무 키나 누르세요.
    pause >nul
)
exit /b %rc%
