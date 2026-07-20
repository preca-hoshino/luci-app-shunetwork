local http = require "luci.http"

module("luci.controller.shucampus", package.seeall)

function index()
    entry({"admin", "services", "shucampus"},
        firstchild(),
        _("Campus Network"), 80
    )

    entry({"admin", "services", "shucampus", "settings"},
        cbi("shucampus/settings"),
        _("Settings"), 10
    ).leaf = true

    entry({"admin", "services", "shucampus", "interface"},
        cbi("shucampus/interface"),
        _("Interface Info"), 20
    ).leaf = true

    entry({"admin", "services", "shucampus", "log"},
        cbi("shucampus/log"),
        _("Logs"), 30
    ).leaf = true

    -- JSON API (kept separate from page paths)
    entry({"admin", "services", "shucampus", "api", "status"},
        call("action_status"))

    entry({"admin", "services", "shucampus", "api", "ifstatus"},
        call("action_ifstatus"))

    entry({"admin", "services", "shucampus", "api", "log"},
        call("action_log"))

    entry({"admin", "services", "shucampus", "api", "log_clear"},
        call("action_log_clear"))

    entry({"admin", "services", "shucampus", "api", "login"},
        call("action_login"))

    entry({"admin", "services", "shucampus", "api", "logout"},
        call("action_logout"))

    entry({"admin", "services", "shucampus", "api", "restart"},
        call("action_restart"))
end

local CORE = "/usr/bin/shucampus_core.sh"
local LOGFILE = "/var/log/shucampus.log"

function action_status()
    http.prepare_content("application/json")
    http.write(luci.sys.exec(CORE .. " status 2>/dev/null"))
end

function action_log()
    http.prepare_content("text/plain; charset=utf-8")
    http.write(luci.sys.exec("tail -n 300 " .. LOGFILE .. " 2>/dev/null"))
end

-- Network interface data for the info page (from `ip -s -j addr`).
-- Prefers the campus (10.x) IPv4 address, falls back to the first inet one.
function action_ifstatus()
    http.prepare_content("application/json")
    local json = require "luci.jsonc"
    local raw = luci.sys.exec("ip -s -j addr show dev wan 2>/dev/null")
    local data = json.parse(raw)
    local result = {}
    if type(data) == "table" and type(data[1]) == "table" then
        local dev = data[1]
        result.name = dev.ifname
        result.mtu = dev.mtu
        local first4, campus4
        for _, a in ipairs(dev.addr_info or {}) do
            local addr = a["local"]   -- "local" is a reserved word in Lua
            if a.family == "inet" then
                first4 = first4 or addr
                if type(addr) == "string" and addr:match("^10%.") then
                    campus4 = addr
                end
            end
        end
        result.ipv4 = campus4 or first4
        if type(dev.stats64) == "table" then
            result.rx_bytes = dev.stats64.rx and dev.stats64.rx.bytes
            result.tx_bytes = dev.stats64.tx and dev.stats64.tx.bytes
        end
    end
    http.write(json.stringify(result))
end

function action_log_clear()
    luci.sys.call(": > " .. LOGFILE .. " 2>/dev/null")
    http.prepare_content("application/json")
    http.write('{"result":"ok"}')
end

function action_login()
    luci.sys.call(CORE .. " login >/dev/null 2>&1 &")
    http.prepare_content("application/json")
    http.write('{"result":"ok"}')
end

function action_logout()
    luci.sys.call(CORE .. " logout >/dev/null 2>&1 &")
    http.prepare_content("application/json")
    http.write('{"result":"ok"}')
end

function action_restart()
    luci.sys.call("/etc/init.d/shucampus restart >/dev/null 2>&1 &")
    http.prepare_content("application/json")
    http.write('{"result":"ok"}')
end
