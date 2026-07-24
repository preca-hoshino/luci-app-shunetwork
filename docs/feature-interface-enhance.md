# Feature: Interface Info Page Enhancement

## Goal

Expand the LuCI Interface Info page from a single network stats table to a three-tab panel:

1. **Interface** — Richer network interface info (current)
2. **My Devices** — All devices logged into this account, with router self-identification
3. **Service History** — Last 10 login/logout events

Data source: Ruijie SAM+ self-service portal at `http://10.10.9.49/selfservice/`.

---

## 1. Interface Tab (Richer)

Currently shows: name, IPv4, MTU, RX/TX bytes.

Expand to:

| Field | Source |
|-------|--------|
| Interface name | UCI `shunetwork.@campus[0].interface` |
| Logical interface status | ubus `network.interface.<name> status` |
| IPv4 address | ubus `network.interface.<name> status` → `ipv4-address[0].address` |
| IPv4 mask | ubus → `ipv4-address[0].mask` |
| MAC address | `ip -s -j link show dev <l3_device>` → `address` |
| MTU | `ip -j link` → `mtu` |
| RX bytes / packets / errors / drops | `ip -s -j link` → `stats64.rx` |
| TX bytes / packets / errors / drops | `ip -s -j link` → `stats64.tx` |
| Gateway | UCI `shunetwork.@campus[0].gateway` |
| DNS | ubus `network.interface.<name> status` → `dns-server` |
| Uptime | From daemon state (`/var/run/shunetwork_uptime`) |
| Link state | `ip -j link` → `operstate` (UP/DOWN) |

---

## 2. My Devices Tab

### Data Source

The self-service portal at `http://10.10.9.49/selfservice/` exposes online user info.
Based on the portal's JS strings, the relevant endpoint pattern is:

```
POST /selfservice/module/usermanage/web/userinfo_self.jsf
  or
POST /selfservice/module/webcontent/web/online_user_list.jsf
```

Parameters required: JSF view state + session cookie (obtained by logging into the portal).

### Auth Flow

The self-service portal uses the **same credentials** as the campus network portal
(username + password). The login endpoint is typically:

```
POST /selfservice/login
  account=<username>&password=<password>&auth_type=0
```

On success, returns a session cookie (`JSESSIONID`) that must be sent with subsequent requests.

### Device Info to Display

| Field | Notes |
|-------|-------|
| MAC address | Used to identify the router |
| IPv4 address | |
| IPv6 address | |
| Access type | Web / 1X |
| Online duration | |
| NAS IP | |
| NAS port | |
| VLAN (inner/outer) | |
| Terminal type | PC / Phone / Pad |

### Router Self-identification

The router's WAN MAC is obtained from:
```bash
ip -j link show dev wan | jq -r '.[0].address'
```

Compare against the MAC in the device list. Mark the matching row with a
"(This Router)" badge.

### Mock Data (for development without portal access)

```json
{
  "devices": [
    {"mac":"aa:bb:cc:dd:ee:01", "ip":"10.50.1.100", "type":"PC",
     "duration":"2h 15m", "nas":"10.50.255.11", "vlan":"101", "online": true},
    {"mac":"11:22:33:44:55:66", "ip":"10.50.1.101", "type":"Phone",
     "duration":"0h 30m", "nas":"10.50.255.11", "vlan":"101", "online": true}
  ]
}
```

---

## 3. Service History Tab

### Data Source

The self-service portal's account flow page:

```
POST /selfservice/module/usermanage/web/useraccountflow_current.jsf
```

Shows recent login/logout events for the account.

### Fields to Display (last 10)

| Field | Description |
|-------|-------------|
| Session ID | Unique session identifier |
| Start time | Login timestamp |
| End time | Logout/disconnect timestamp |
| Duration | Online duration |
| MAC address | Device MAC |
| IPv4 | Device IP |
| NAS IP | Access gateway |
| Cause | Normal logout / timeout / admin kick |

### Mock Data

```json
{
  "history": [
    {"session":"SESS001", "start":"2026-07-21 10:00:00", "end":"2026-07-21 12:30:00",
     "duration":"2h 30m", "mac":"aa:bb:cc:dd:ee:01", "ip":"10.50.1.100",
     "cause":"Normal logout"},
    {"session":"SESS002", "start":"2026-07-21 08:00:00", "end":"2026-07-21 09:45:00",
     "duration":"1h 45m", "mac":"11:22:33:44:55:66", "ip":"10.50.1.101",
     "cause":"Session timeout"}
  ]
}
```

---

## Technical Approach

### Option A: Daemon-side fetching (recommended)

Extend `shunetwork_core.sh` with subcommands:
- `self_login` — Authenticate against self-service portal, cache session cookie
- `self_devices` — Fetch online device list, output JSON
- `self_history` — Fetch account flow, output JSON
- `self_logout` — Clear cached session

Data is cached in `/var/run/shunetwork_self_cookie` (session cookie) and
`/var/run/shunetwork_self_cache` (JSON cache, TTL 30s).

LuCI controller calls the shell subcommand and pipes JSON to the frontend.

### Option B: LuCI-side fetching

Add API actions directly in the LuCI controller that call `curl` to the self-service
portal. Simpler but slower (LuCI runs synchronously per request).

**Recommendation**: Option A for separation of concerns + caching.

### Portal Scraping Challenges

1. **JSF view state**: Each page has a `javax.faces.ViewState` hidden field that must
   be extracted from the HTML form and submitted with the POST.
2. **Session management**: Need to POST login, capture `JSESSIONID` cookie, maintain it.
3. **Form encoding**: Chinese characters in the page may be GBK-encoded (not UTF-8).
4. **Page structure changes**: HTML parsing is fragile; XPath or regex-based extraction.

### Mitigation Strategy

1. Use `curl` with `-c`/`-b` for cookie handling
2. Extract ViewState with `grep -oP 'name="javax.faces.ViewState" value="\K[^"]+'`
3. Prefer JSON endpoints if available (some Ruijie portals expose JSON APIs behind
   the JSF pages)
4. Implement mock mode for development/testing when portal is unreachable

---

## LuCI Page Layout

The current `interface.lua` (SimpleSection + template) becomes a `TypedSection` with tabs:

```
Interface Info
├── Tab: Interface     (richer table from ubus + ip)
├── Tab: My Devices    (table from self-service portal)
└── Tab: History       (table from self-service portal)
```

Each tab uses a template or a DummyValue with JS rendering, similar to the existing
Settings page pattern.

New/modified files:
- `luasrc/model/cbi/shunetwork/interface.lua` — Rewrite with tabs
- `luasrc/view/shunetwork/interface.htm` — New main template with tab switching
- `luasrc/view/shunetwork/devices.htm` — Device list template (or inline in interface.htm)
- `luasrc/view/shunetwork/history.htm` — History table template (or inline)
- `luasrc/controller/shunetwork.lua` — Add JSON API actions for devices/history
- `root/usr/bin/shunetwork_core.sh` — Add `self_login`/`self_devices`/`self_history` subcommands

---

## Implementation Order

1. **Phase 1** — Richer interface info (ubus + ip stats expansion, no portal dependency)
2. **Phase 2** — Self-service portal auth flow (login + cookie management in shell)
3. **Phase 3** — My Devices tab (fetch + parse device list, router MAC identification)
4. **Phase 4** — Service History tab (fetch + parse account flow)
5. **Phase 5** — Mock mode (fallback when portal unreachable, for testing)
6. **Phase 6** — LuCI UI polish (error states, loading indicators, zh-cn translations)
