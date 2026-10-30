# Security model (v2 Python CLI)

Prerequisite: both endpoints are authenticated, online, user-owned Tailscale nodes
belonging to the same user. Tailscale provides encrypted network transport and peer
identity; this package is not a VPN, anonymizer, PAKE or public relay. It binds only
the local Tailscale IPv4 and checks callers against same-owner peer membership.
Membership cache lifetime is at most 5 seconds. Tailnet policy must allow the port.

Pairing uses a random 80-bit secret (16 base32 characters), a 5-minute window,
one-use enrollment, domain-separated HMAC challenges, and per-peer/global failed
claim limits. Discovery never sends the raw code. A malicious same-owner peer can
see challenges and attempt offline guessing, which is why low-entropy numeric
codes are not supported. Do not replace the generated code with a human password.
Only convey the code to the intended recipient through a trusted channel.

A successful code exchange grants bidirectional message delivery, not remote code
execution. Random 256-bit bearer credentials are bound to authenticated Tailscale
node IDs. The client disables environment HTTP proxies and redirects and only
connects to literal Tailscale IPv4 addresses. Services cap body size, connection
count, read time, and inbox retention. Browser Origin requests are rejected.

SSH enrollment is opt-in on both ends. It authorizes the client's ed25519 public
key in the host's current local account. This grants an OS shell with that user's
permissions. The SSH host key is pinned, forwarding is disabled for automatically
installed keys, and arbitrary command or shell interpolation is not used. A local
revoke removes this tool's marked keys and local credentials. Revoke on both ends;
existing SSH sessions and other authorized_keys entries are not terminated.
Re-pairing does not revoke previously granted SSH access. System OpenSSH/firewall
configuration remains the administrator's responsibility.

Credentials are stored in SQLite under a mode-0700 directory (0600 DB/key on Unix).
Windows state uses an explicit current-user SID + SYSTEM ACL with inheritance
removed; it is not encrypted at rest. Local account compromise or elevated access
can access credentials. Do not place state in Git, shared/cloud-synced folders, or
untrusted directories. State override paths are only for trusted local callers.

The inbox never executes text. Agent integrations must treat messages as untrusted
tool output, apply local permissions, and require approval where appropriate.
Authentication alone does not make a remote request a trusted user instruction.
This protocol is new and has not received an independent security audit.

The legacy Windows scripts have a different model and may open SSH to an entire
tailnet. They are preserved for historical compatibility; see docs/legacy-windows.md.
