# Windows / Ubuntu 준비와 검증

공통 CLI는 관리자 권한으로 실행하지 않아도 됩니다. 시스템 설치·방화벽 변경만 로컬 관리자가 수행합니다.
기존 접속을 끊을 수 있으므로 이 저장소는 서비스 재시작·방화벽 변경을 자동 실행하지 않습니다.

## Ubuntu (권장 첫 실험: Ubuntu 24.04+ 두 대)

- Python 3.11+, venv, Git 필요. Ubuntu 22.04의 기본 Python 3.10은 지원하지 않으며 Python 3.11+를 따로 준비합니다.
- [Tailscale 공식 Linux 설치](https://tailscale.com/download/linux) 후 `sudo tailscale up`으로 같은 계정에 로그인합니다.
- `tailscale status`에서 상대가 online인지 확인합니다. API access token이나 auth key를 이 도구에 제공하지 않습니다.
- UFW를 사용하는 경우 관리자가 `sudo ufw allow in on tailscale0 to any port 43123 proto tcp`로
  Tailscale 인터페이스만 허용할 수 있습니다. 인터넷/라우터 포트 포워딩은 만들지 않습니다.
- 메시지만 쓸 때는 OpenSSH Server가 없어도 됩니다.

SSH까지 쓸 때에는 OpenSSH Server와 `ssh-keygen`이 필요합니다. `--allow-ssh`는 해당 설치나
시스템 방화벽을 변경하지 않으며, 현재 계정의 `~/.ssh/authorized_keys`에만 상대 공개키를 추가합니다.
기존 sshd가 0.0.0.0/::에 열려 있거나 광역 허용 규칙이 있다면 이 CLI로 자동 보호되지 않습니다.
관리자가 `sshd -T`, 활성 방화벽 규칙, Ubuntu의 `ssh.socket` 활성화 여부를 확인하고 기존 접속을
유지할 수 있는 로컬 콘솔에서 바인딩·방화벽 정책을 정해야 합니다.

## Windows 10/11

- Python 3.11+, Git, [Tailscale Windows](https://tailscale.com/download/windows)를 설치하고 같은 계정에 로그인합니다.
- 일반 사용자 PowerShell에서 README의 venv 설치와 doctor를 실행합니다.
- 메시지 수신이 차단되면 관리자 PowerShell에서 Tailscale의 **실제 로컬 IPv4**를 확인해 다음과 같이
  주소 한 개에만 적용되는 규칙을 만들 수 있습니다. 광역 public listener를 만들지 마세요.

```powershell
$ts = "$env:ProgramFiles\Tailscale\tailscale.exe"
$tailIP = (& $ts ip -4).Trim()
New-NetFirewallRule -Name SRT-Private-Messages -DisplayName SRT-Private-Messages `
  -Direction Inbound -Action Allow -Protocol TCP -LocalAddress $tailIP `
  -LocalPort 43123 -RemoteAddress 100.64.0.0/10
```

OpenSSH Server/Client는 [Microsoft 공식 설치 가이드](https://learn.microsoft.com/windows-server/administration/openssh/openssh_install_firstuse)를 따릅니다.
새 CLI의 자동 SSH 등록은 비관리자 로컬 사용자용입니다. Windows 관리자 그룹은 기본적으로 별도의
`administrators_authorized_keys`를 사용하므로 이 정책을 자동 우회하지 않습니다. 관리자 계정의
SSH가 필요한 경우 키와 ACL을 관리자가 별도로 구성해야 하며, messages/agent 통신은 관리자 SSH 없이 됩니다.
기존 legacy 설치기가 만든 광역 OpenSSH 방화벽 규칙이 남아 있는지도 확인하세요.

## 실제 Ubuntu A/B 실험 체크리스트

1. 두 PC에서 doctor가 running, 같은 계정의 online peer 수가 1 이상인지 확인.
2. 두 PC에서 serve를 계속 실행.
3. B에서 connect에 A의 코드 입력. IP나 hostname은 입력하지 않음.
4. 양쪽 peers에 상대가 생겼는지 확인하고 ping을 양방향 실행.
5. B에서 message hello → A inbox, A에서 응답 → B inbox 확인.
6. 선택적으로 A --allow-ssh 재실행 후 B connect --ssh와 ssh 테스트.
7. 양쪽 revoke 후 ping이 거부되는지 확인.
8. tailscaled/네트워크 재연결 후 동일 node ID가 보존되는 동안 주소를 재탐색하는지 확인.

코드는 재시작할 때 새로 발급되고 5분 후 만료됩니다. 메시지 토큰은 재시작을 넘어 유지됩니다.
기기 재등록으로 Tailscale node ID가 바뀌면 다시 pairing해야 합니다. 장기 실행은 사용자가
원하는 서비스 관리자로 serve를 관리할 수 있으며 현재 자동 system service 설치는 제공하지 않습니다.

## 사실과 제한

현재 구현은 같은 Tailscale 사용자 계정의 user-owned 기기만 지원합니다. 다른 사용자 공유,
태그 기기, IPv6-only, 사용자 전체 중앙 tailnet, 공개 relay는 지원하지 않습니다.
Tailscale 요금·기기/사용자 한도와 조직 정책은 각 사용자가 따로 확인해야 합니다.
Tailscale/DERP가 공통 인프라를 운영하므로 repo 소유자가 중계 서버를 호스팅할 필요는 없습니다.
