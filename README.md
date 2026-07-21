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
./tools/ipk-build.sh

# Output: luci-app-shucampus_1.0-1_all.ipk
```

## Conventions

### Directory Layout

```
luci-app-shucampus/
  luasrc/                   # LuCI Lua source → /usr/lib/lua/luci/
    controller/             #   Entry points (module("luci.controller.*"))
    model/cbi/              #   CBI form models
    view/                   #   .htm templates
  root/                     # Filesystem overlay → /
    etc/config/             #   UCI config defaults
    etc/init.d/             #   procd init script
    usr/bin/                #   Core daemon/CLI
    lib/upgrade/keep.d/     #   sysupgrade persistence
  po/{lang}/                # Translation .po files
  tools/                    # Build-time helpers (po2lmo.py)
```

### Git Commit Style

```
luci-app-shucampus: short description in present tense

Optional body explaining what and why.
```

Prefix scope for cross-cutting changes:
- `core: ` → `shucampus_core.sh`
- `luci: ` → controller/CBI/views/i18n  
- `build: ` → Makefile, ipk-build.sh, CI

### File Naming

- All lowercase
- Hyphen-separated for multi-word names (e.g., `status-bar.htm`, not `status_bar.htm`)
- Controller: `{appname}.lua`
- CBI model: `{appname}/{section}.lua`
- View: `{appname}/{section}.htm`

## License

GPL-3.0
