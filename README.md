# ssh-remote-tools

Windows와 Ubuntu에서 **자기 Tailscale 계정의 두 PC를 코드 하나로 등록하고**, 메시지 또는
일반 OpenSSH로 연결하는 공통 CLI입니다. 별도 중계 서버·공인 IP 공유·포트 포워딩이 필요 없습니다.

기존 Windows 웹/TUI는 [legacy 사용법](docs/legacy-windows.md)에 보존했습니다.
새 공통 CLI의 핵심은 `ssh_remote_tools` Python 패키지이며 codex-bridge에서도 재사용합니다.

## 시작

1. 두 PC에 Python 3.11+와 [Tailscale](https://tailscale.com/download)을 설치합니다.
2. **같은 Tailscale 사용자 계정**으로 로그인합니다. 다른 사용자 공유·태그 기기는 현재 지원하지 않습니다.
3. 두 PC에서 설치합니다.

Ubuntu:

```bash
git clone https://github.com/parktune/ssh-remote-tools.git
cd ssh-remote-tools
python3 -m venv .venv
.venv/bin/python -m pip install -e .
.venv/bin/srt doctor
```

Windows PowerShell:

```powershell
git clone https://github.com/parktune/ssh-remote-tools.git
cd ssh-remote-tools
py -3 -m venv .venv
.venv\Scripts\python.exe -m pip install -e .
.venv\Scripts\srt.exe doctor
```

이후 Ubuntu는 `.venv/bin/srt`, Windows는 `.venv\Scripts\srt.exe`를 사용합니다.
`remote-tools.sh` / `remote-tools.cmd`도 같은 CLI 실행기입니다.

## 코드 하나로 양방향 연결

두 PC에서 수신 프로세스를 각각 실행한 채로 둡니다.

```bash
srt serve
```

화면에 `XXXX-XXXX-XXXX-XXXX` 형태의 **16자, 80비트 랜덤 코드**가 표시됩니다.
두 코드 중 A의 코드 하나를 B에 전달한 뒤, B의 **다른 터미널**에서 실행합니다.

```bash
srt connect
# A의 코드를 비표시 입력. 5분 내 한 번만 사용 가능.
srt peers
srt ping <A의 이름>
srt message <A의 이름> "hello"
```

A에서:

```bash
srt inbox
srt peers
srt message <B의 이름> "hello received"
```

단 한 번의 등록으로 **A→B, B→A 메시지 자격을 모두 교환**합니다. 양쪽 수신 프로세스는 계속
실행되어야 합니다. 표준 포트는 TCP 43123이며 Tailscale 주소 하나에만 바인딩합니다.
방화벽이 이 포트를 막으면 [설정 가이드](docs/setup.md)에 따라 Tailscale 인터페이스에서만 허용합니다.

## SSH는 명시적으로 허용

메시지 연결만으로 쉘을 열거나 명령을 실행하지 않습니다. OpenSSH Server가 준비된 A에서:

```bash
srt serve --allow-ssh
```

B에서 A의 새 코드를 사용합니다.

```bash
srt connect --ssh
srt ssh <A의 이름>
```

B의 ed25519 공개키만 A의 **현재 로컬 OS 계정**에 등록합니다. 개인키는 B에 남고,
SSH 호스트 공개키는 pairing 응답으로 받아 고정합니다. `StrictHostKeyChecking=yes`이며,
자동 등록한 키에는 agent/X11/port forwarding 금지 옵션을 붙입니다.
Tailscale SSH 기능에 의존하지 않으므로 일반 OpenSSH가 있는 Windows·Ubuntu에 같은 방식입니다.
Windows 자동 SSH 키 등록은 **비관리자 로컬 계정**을 대상으로 합니다. 관리자 그룹의 기본
`administrators_authorized_keys` 정책은 자동 변경하지 않습니다. [설정 가이드](docs/setup.md)를 읽으세요.

## 폐기와 수신함

```bash
srt revoke <상대 이름>   # 이 PC의 상대 토큰과 이 도구가 등록한 상대 SSH 키 제거
srt ack <message-id>    # 처리 확인
srt prune               # 확인한 메시지만 삭제
```

연결을 완전히 폐기하려면 양쪽에서 revoke합니다. SSH 세션 종료, Tailscale 기기 삭제,
다른 도구가 등록한 SSH 키 제거는 수행하지 않습니다. 이름이 겹치면 `peers`의 node ID를 선택합니다.

## 보안과 범위

- 네트워크 가입은 Tailscale이 담당합니다. pairing code가 Tailscale 로그인·ACL을 우회하지 않습니다.
- 각 사용자가 자기 계정의 망을 사용합니다. 프로젝트 주인의 공용 tailnet에 모두 가입시키지 않습니다.
- 공인 IP를 **사용자가 직접 공유할 필요가 없다**는 의미입니다. 인증된 피어에게 실제 네트워크 주소를 숨기는 익명화 기능은 아닙니다.
- discovery에 코드를 평문으로 보내지 않으며 랜덤 challenge의 HMAC으로 상대를 확인합니다.
  PAKE가 아니므로 짧은 숫자 코드를 지원하지 않습니다. 상세 위협 모델은 [SECURITY.md](SECURITY.md)에 있습니다.
- 저장소 소스에는 비밀을 넣지 않습니다. 토큰·개인키는 소유자 전용 로컬 상태 디렉터리에 보관합니다.
- 수신 메시지는 DB에만 저장하며 원격 명령으로 실행하지 않습니다. 파일 전송·LLM 실행은 이 패키지의 역할이 아닙니다.
- 기존 Windows legacy 스크립트는 별도 구현입니다. 새 CLI 실행은 시스템 SSH 설정·광역 방화벽 규칙·tailnet ACL을 자동 변경하지 않습니다.

## 검증

```bash
python -m unittest discover -s tests -v
```

로컬 HTTP 통합 테스트에서 한 코드 등록·양방향 메시지·토큰 폐기·중복 방지·SSH host-key pinning을
검증합니다. GitHub Actions는 Windows/Ubuntu × Python 3.11/3.13을 실행합니다.
이 개발 PC에는 Tailscale이 설치되어 있지 않아 **실제 두 호스트/NAT 왕복은 아직 검증 전**입니다.
CI가 통과해도 실제 OS 서비스 설치·방화벽·tailnet 연결의 성공을 뜻하지 않습니다.

Apache-2.0.
