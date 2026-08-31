# clipd-agent installer

One-line installer + release assets for `clipd-agent` (the jump-host side of
[clipboard-bridge](https://github.com/wusung/clipboard-bridge)). This repo
only carries `install.ps1` and packaged release zips — the agent's source
lives in the main clipboard-bridge repo.

## Install

On a Windows host that can reach `github.com`/`raw.githubusercontent.com`,
open PowerShell and run:

```powershell
irm https://raw.githubusercontent.com/wusung/clipd-agent/main/install.ps1 | iex
```

This downloads the latest release's `clipd-agent.zip`, verifies it against
`clipd-agent.zip.sha256`, and extracts it to `%USERPROFILE%\clipd-agent`. An
existing `registry\targets.txt` (your host allowlist) is never overwritten.

To install a specific version instead of latest:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/wusung/clipd-agent/main/install.ps1))) -Version v0.2.54
```

## After install

```
start now:        powershell -ExecutionPolicy Bypass -File %USERPROFILE%\clipd-agent\Start-ClipdAgent.ps1
start on login:   powershell -ExecutionPolicy Bypass -File %USERPROFILE%\clipd-agent\clipd-agent.ps1 service --install
```

`service --install` registers a logon-triggered Scheduled Task (no admin
rights required) and starts the supervisor once immediately; it does not use
a Windows service, since Session 0 has no clipboard access. See
`service --status` / `--stop` / `--restart` / `--uninstall` for other
lifecycle commands.

Before first use, edit `%USERPROFILE%\clipd-agent\registry\targets.txt` to
list the `host:port` targets the agent is allowed to tunnel to — anything
not listed is rejected.

## Releases

Each release attaches:
- `clipd-agent.zip` — the install bundle
- `clipd-agent.zip.sha256` — its SHA256, checked by `install.ps1` before
  extracting

## No direct internet from the target host?

This one-line installer requires outbound access to GitHub. If the actual
target machine is air-gapped behind a jump host that does have internet
access, use the jump host's own relay/transfer tooling instead — see
`clipd-agent/deploy/DEPLOY.md` in the main clipboard-bridge repo.
