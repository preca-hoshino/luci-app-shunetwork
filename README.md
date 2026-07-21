# luci-app-shunetwork

[![Release](https://img.shields.io/github/v/release/preca-hoshino/luci-app-shunetwork?style=flat-square)](https://github.com/preca-hoshino/luci-app-shunetwork/releases)
[![License](https://img.shields.io/github/license/preca-hoshino/luci-app-shunetwork?style=flat-square)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-OpenWrt%2FImmortalWrt-00a4e6?style=flat-square)](https://openwrt.org)

**Ruijie SAM+ portal authentication daemon with LuCI management interface for OpenWrt / ImmortalWrt.** Designed for Shanghai University (SHU) campus network.

---

## Features

- **Auto-login** — Captive portal detection + Ruijie SAM+ challenge-response login
- **Persistent keepalive** — Configurable interval (60–600s) to prevent NAS session timeout
- **Session adoption** — Recovers existing portal sessions across daemon restarts
- **Exponential backoff** — Auth failure escalates: 30s → 60s → 120s → 300s → 600s
- **Manual disconnect** — One-click logout with suppression (stays offline until re-enabled)
- **Route management** — Auto-creates campus DHCP interface and `10.0.0.0/8` route
- **Config validation** — Graceful `config_error` state when credentials missing; auto-recovers
- **Logging** — Persistent `/etc/shunetwork.log` with 64KB rotation and syslog mirroring
- **zh-cn localization** — Full Chinese translation for LuCI interface
- **9-state auth machine** — `disabled/stopped/suppressed/authenticating/waiting/online/offline/auth_failed/config_error`

### LuCI Pages

| Page | Description |
|------|-------------|
| **Settings** | Status bar, auth state, ISP selection, portal/gateway/interface config |
| **Interface Info** | Campus interface IPv4, MTU, live RX/TX traffic |
| **Logs** | Scrollable log viewer with tail/head navigation and clear |

---

## Installation

```bash
# Download from Releases
wget -O /tmp/luci-app-shunetwork_latest_all.ipk https://github.com/preca-hoshino/luci-app-shunetwork/releases/latest/download/luci-app-shunetwork_latest_all.ipk
opkg install /tmp/luci-app-shunetwork_latest_all.ipk

# Or build from source
git clone https://github.com/preca-hoshino/luci-app-shunetwork.git
cd luci-app-shunetwork
./tools/ipk-build.sh
```

### OpenWrt SDK

```bash
git clone https://github.com/preca-hoshino/luci-app-shunetwork.git package/luci-app-shunetwork
make menuconfig  # LuCI → Applications → luci-app-shunetwork
make package/luci-app-shunetwork/compile V=s
```

---

## Configuration

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

Navigate to **Services → SHU Network** in LuCI after install. Enter credentials, adjust portal/gateway if needed, then Save & Apply.

---

## Acknowledgments

- [DongZhouGu/shu-auto-net](https://github.com/DongZhouGu/shu-auto-net) — Reference implementation for SHU campus network auth
- [OpenWrt LuCI](https://github.com/openwrt/luci) — Web UI framework
- [ImmortalWrt](https://immortalwrt.org) — Primary testing platform

---

## License

[GNU General Public License v3.0](LICENSE)
