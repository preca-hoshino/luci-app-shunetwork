<picture><source media="(prefers-color-scheme: dark)" srcset="https://github.com/preca-hoshino/luci-app-shunetwork/assets/logo-dark.svg"><img alt="luci-app-shunetwork" src="https://github.com/preca-hoshino/luci-app-shunetwork/assets/logo.svg" width="400"></picture>

**Ruijie SAM+ portal authentication daemon with LuCI management interface for OpenWrt / ImmortalWrt.**

[![Release](https://img.shields.io/github/v/release/preca-hoshino/luci-app-shunetwork?style=flat-square)](https://github.com/preca-hoshino/luci-app-shunetwork/releases)
[![License](https://img.shields.io/github/license/preca-hoshino/luci-app-shunetwork?style=flat-square)](LICENSE)
[![OpenWrt](https://img.shields.io/badge/platform-OpenWrt%2FImmortalWrt-00a4e6?style=flat-square)](https://openwrt.org)
[![LuCI](https://img.shields.io/badge/LuCI-compat%20%7C%20JS-8B5CFE?style=flat-square)](https://github.com/openwrt/luci)

---

## Overview

`luci-app-shunetwork` is a full-stack campus network authentication solution for Shanghai University (SHU) running on OpenWrt/ImmortalWrt routers. It combines:

- **`shunetwork_core.sh`** — A standalone POSIX shell daemon that detects captive portal redirects, performs Ruijie SAM+ POST login, sends periodic keepalives, and maintains a 9-state auth machine with exponential failure backoff.
- **LuCI web interface** — Settings panel, interface monitor, and log viewer accessible from the router admin UI.
- **procd service** — OpenWrt init script with auto-respawn, config triggers, and UCI integration.

### Use Cases

- **Dormitory routers** sharing a single campus network account across multiple devices
- **Dual-WAN setups** with campus network + PPPoE on the same physical port
- **Unattended operation** requiring automatic reconnection after power cycles or network outages

---

## Features

- **Auto-login** — Detects captive portal redirect and performs Ruijie SAM+ challenge-response login
- **Persistent keepalive** — Configurable interval (60–600s) prevents NAS session timeout
- **Session adoption** — Recovers and adopts existing portal sessions across daemon restarts
- **Exponential backoff** — Auth failure escalates through 30s → 60s → 120s → 300s → 600s, resets on success
- **Manual disconnect** — One-click logout with suppression (stays offline until explicitly re-enabled)
- **Route management** — Automatically creates campus DHCP interface and `10.0.0.0/8` route
- **Config validation** — Detects missing credentials and enters `config_error` state; auto-recovers when filled
- **Logging** — Persistent log at `/etc/shunetwork.log` (64KB rotation) with syslog mirroring
- **zh-cn localization** — Full Chinese translation for LuCI interface
- **Procd supervision** — Auto-respawn on crash, config reload triggers, status monitoring

### LuCI Pages

| Page | Description |
|------|-------------|
| **Settings** | Status bar, auth state, ISP selection, portal/gateway/interface config |
| **Interface Info** | Campus interface IPv4, MTU, and live RX/TX traffic counters |
| **Logs** | Scrollable log viewer with tail/head navigation and clear |

---

## State Machine

The daemon tracks authentication state through 9 well-defined states:

```
                        ┌──────────────┐
                        │   disabled   │
                        └──────┬───────┘
                               │ enable
                               ▼
                        ┌──────────────┐
              ┌─────────│   stopped    │◄────────┐
              │         └──────┬───────┘         │
              │                │ start            │
              │                ▼                  │
              │         ┌──────────────┐          │
              │         │  suppressed  │───login──┘
              │         └──────┬───────┘
              │                │ login
              │                ▼
              │         ┌──────────────┐
              │         │authenticating│
              │         └──────┬───────┘
              │           ┌────┴────┐
              │           ▼         ▼
              │    ┌──────────┐ ┌──────────┐
              │    │  online  │ │  waiting │
              │    └────┬─────┘ └────┬─────┘
              │         │            │
              │    ┌────┴────┐       │
              │    ▼         ▼       │
              │ ┌────────┐┌──────────┘
              │ │offline ││  auth_failed
              │ └───┬────┘└─────┬────┘
              └─────┴───────────┘
```

| State | Meaning |
|-------|---------|
| `disabled` | Service disabled in UCI config |
| `stopped` | Daemon process not running |
| `config_error` | Missing or invalid username/password |
| `suppressed` | Manually disconnected via Logout (holds offline) |
| `authenticating` | Login request in progress |
| `waiting` | No captive portal detected (already online or NAS unreachable) |
| `online` | Authenticated, session active, keepalive running |
| `offline` | Keepalive failed, session lost |
| `auth_failed` | Portal rejected credentials, backoff active |

---

## Screenshots

| Settings | Interface Info | Logs |
|----------|---------------|------|
| *(TODO)* | *(TODO)* | *(TODO)* |

---

## Installation

### Pre-built ipk

Download the latest `.ipk` from the [Releases page](https://github.com/preca-hoshino/luci-app-shunetwork/releases):

```bash
wget -O /tmp/luci-app-shunetwork_latest_all.ipk https://github.com/preca-hoshino/luci-app-shunetwork/releases/latest/download/luci-app-shunetwork_latest_all.ipk
opkg install /tmp/luci-app-shunetwork_latest_all.ipk
```

Or download manually and scp:

```bash
# On router
opkg update
opkg install /tmp/luci-app-shunetwork_*.ipk
```

### OpenWrt SDK

```bash
# Clone into your feeds or package directory
git clone https://github.com/preca-hoshino/luci-app-shunetwork.git package/luci-app-shunetwork
make menuconfig  # LuCI → Applications → luci-app-shunetwork
make package/luci-app-shunetwork/compile V=s
```

### Quick Deploy

> **Note**: Local deploy scripts (`deploy.*`) are gitignored and not distributed. For one-off deployment, scp the `.ipk` and install manually.

---

## Build

```bash
git clone https://github.com/preca-hoshino/luci-app-shunetwork.git
cd luci-app-shunetwork

# Build .ipk (requires python3 for po2lmo)
./tools/ipk-build.sh

# Output: luci-app-shunetwork_1.0-1_all.ipk
```

---

## Configuration

### UCI

```uci
config campus
    option enabled   '1'
    option username  'your_student_id'
    option password  'your_portal_password'
    option service   'shu'         # shu | dx | lt | yd
    option portal    'http://10.50.255.11:8080/eportal'
    option gateway   '10.50.0.1'
    option interface 'campus'
    option cidr      '10.0.0.0/8'
    option keepalive '120'
```

### LuCI

Navigate to **Services → SHU Network** in the router web UI. All settings above are configurable through the Settings tab.

### First-Time Setup

1. Install the ipk
2. Open **Services → SHU Network → Settings**
3. Enter your campus network **Username** and **Password**
4. Adjust **Portal URL** and **Gateway** if your deployment differs
5. Click **Save & Apply**
6. The daemon starts automatically — status shows on the Settings page

---

## API Reference

The LuCI controller exposes REST API endpoints under `/admin/services/shunetwork/api/`.

| Endpoint | Method | Returns |
|----------|--------|---------|
| `status` | GET | `{"enabled":"1","daemon_running":true,"state":"online","state_msg":"","uptime":"0d 2h 15m","pid":"1234"}` |
| `ifstatus` | GET | `{"name":"campus","ipv4":"10.x.x.x","mtu":1500,"rx_bytes":123456,"tx_bytes":654321}` |
| `login` | GET | `{"result":"ok"}` — triggers async login |
| `logout` | GET | `{"result":"ok"}` — triggers async logout + suppress |
| `restart` | GET | `{"result":"ok"}` — restarts daemon |
| `toggle?enabled=0\|1` | GET | `{"result":"ok"}` — enables/disables + stops/starts daemon |
| `log` | GET | Plain text, last 300 lines |
| `log_clear` | GET | `{"result":"ok"}` — truncates log file |

---

## Project Structure

```
luci-app-shunetwork/
├── luasrc/                   # LuCI Lua source → /usr/lib/lua/luci/
│   ├── controller/
│   │   └── shunetwork.lua    # Entry points, API actions
│   ├── model/cbi/shunetwork/
│   │   ├── settings.lua      # Settings form (status + config + tabs)
│   │   ├── interface.lua     # Interface info form
│   │   └── log.lua           # Log viewer form
│   └── view/shunetwork/
│       ├── status-bar.htm    # Status bar template (tailscale-style)
│       ├── interface-status.htm
│       └── log-view.htm
├── root/                     # Filesystem overlay → /
│   ├── etc/
│   │   ├── config/shunetwork # UCI config defaults
│   │   └── init.d/shunetwork # procd init script
│   ├── usr/bin/
│   │   └── shunetwork_core.sh # Core daemon and CLI
│   └── lib/upgrade/keep.d/
│       └── luci-app-shunetwork # sysupgrade persistence list
├── po/zh-cn/                 # Chinese translations
├── tools/                    # Build helpers
│   ├── ipk-build.sh          # Standalone ipk packager
│   └── po2lmo.py             # .po → .lmo compiler
├── .github/workflows/        # CI/CD
│   └── release.yml           # Auto-build on tag push
├── Makefile                  # OpenWrt package Makefile
└── README.md
```

---

## Development

### Requirements

- OpenWrt SDK or buildroot (for `luci.mk`)
- Python 3 (for `po2lmo.py`)

### Contributing

1. Fork the repo
2. Create a feature branch (`git checkout -b feat/my-feature`)
3. Commit with conventional scope (`luci-app-shunetwork: add XYZ`)
4. Push and open a Pull Request

### Commit Conventions

```
luci-app-shunetwork: short description in present tense
```

Optional scope prefix for cross-cutting changes:
- `core: ` — `shunetwork_core.sh`
- `luci: ` — controller / CBI / views / i18n
- `build: ` — Makefile, CI, build scripts

### File Naming

- All lowercase
- Hyphen-separated for multi-word names (`status-bar.htm`)
- Controller file matches module name (`shunetwork.lua`)
- CBI models under `cbi/shunetwork/{section}.lua`
- Views under `view/shunetwork/{section}.htm`

---

## Acknowledgments

- [DongZhouGu/shu-auto-net](https://github.com/DongZhouGu/shu-auto-net) — Original SHU campus network auto-login reference implementation
- [OpenWrt LuCI](https://github.com/openwrt/luci) — Web UI framework
- [ImmortalWrt](https://immortalwrt.org) — Primary testing platform

---

## License

[GNU General Public License v3.0](LICENSE)
