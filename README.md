# luci-app-shucampus

LuCI application for Shanghai University Ruijie SAM+ campus network authentication.

Automatically logs in to the campus network portal and sends keepalive heartbeats to maintain the session.

## Features

- **Auto-login**: Captive portal detection + Ruijie SAM+ POST login
- **Keepalive**: Periodic heartbeat (configurable 60-600s) to prevent idle timeout
- **Session recovery**: Resumes or adopts existing portal sessions across daemon restarts
- **Failure backoff**: Exponential backoff on auth failure (30s → 60s → 120s → 300s → 600s)
- **Manual disconnect**: Logout without auto-reconnect until explicitly re-enabled
- **Route management**: Creates/manages the campus network route and DHCP interface
- **Config validation**: Idles gracefully when credentials are missing
- **Logging**: Persistent log at `/etc/shucampus.log` with syslog mirroring, 64KB rotation
- **Full zh-cn translation**: Localized LuCI interface

### LuCI Pages

| Page | Description |
|------|-------------|
| **Settings** | Status bar, login/auth state, ISP selection, network config |
| **Interface Info** | Campus network interface details and traffic counters |
| **Logs** | Daemon log viewer with scroll and clear |

### 9-State Auth Machine

| State | Meaning |
|-------|---------|
| `disabled` | Service disabled in config |
| `stopped` | Daemon not running |
| `config_error` | Missing username or password |
| `suppressed` | Manually disconnected |
| `authenticating` | Login in progress |
| `waiting` | No captive portal redirect (already online or NAS unreachable) |
| `online` | Authenticated and session active |
| `offline` | Keepalive failed, session lost |
| `auth_failed` | Portal rejected credentials |

## Screenshots

*(TODO)*

## Installation

Download the latest `.ipk` from [Releases](https://github.com/preca-hoshino/luci-app-shucampus/releases) and install:

```bash
opkg update
opkg install /tmp/luci-app-shucampus_*.ipk
```

Or build from source (see below).

## Build

```bash
# Install dependencies for po2lmo
sudo apt install python3

# Build the .ipk
./ipk-build.sh

# Output: luci-app-shucampus_1.0-1_all.ipk
```

## Manual Deploy

Deploy to a running OpenWrt router via SSH:

```powershell
# Edit deploy.ps1, set the SSH host alias, then:
.\deploy.ps1
```

## Development

```bash
# Directories
rootfs/                    # IPK root filesystem
  etc/init.d/shucampus     # procd init script
  usr/bin/shucampus_core.sh # Core daemon and CLI
  usr/lib/lua/luci/        # LuCI controller + CBI models + views + i18n
  lib/upgrade/keep.d/      # sysupgrade persistence

tools/po2lmo.py            # .po → .lmo compiler

ipk-build.sh               # IPK packager
deploy.ps1                 # Build → SCP → install → configure → start
```

## License

GPL-3.0
