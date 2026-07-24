local http = require "luci.http"
local sys = require "luci.sys"

module("luci.controller.shunetwork", package.seeall)

function index()
    entry({"admin", "services", "shunetwork"},
        firstchild(),
        _("SHU Network"), 80
    )

    entry({"admin", "services", "shunetwork", "settings"},
        cbi("shunetwork/settings"),
        _("Settings"), 10
    ).leaf = true

    entry({"admin", "services", "shunetwork", "interface"},
        cbi("shunetwork/interface"),
        _("Interface Info"), 20
    ).leaf = true

    entry({"admin", "services", "shunetwork", "log"},
        cbi("shunetwork/log"),
        _("Logs"), 30
    ).leaf = true

    -- JSON API (kept separate from page paths)
    entry({"admin", "services", "shunetwork", "api", "status"},
        call("action_status"))

    entry({"admin", "services", "shunetwork", "api", "ifstatus"},
        call("action_ifstatus"))

    entry({"admin", "services", "shunetwork", "api", "log"},
        call("action_log"))

    entry({"admin", "services", "shunetwork", "api", "log_clear"},
        call("action_log_clear"))

    entry({"admin", "services", "shunetwork", "api", "login"},
        call("action_login"))

    entry({"admin", "services", "shunetwork", "api", "logout"},
        call("action_logout"))

    entry({"admin", "services", "shunetwork", "api", "restart"},
        call("action_restart"))

    entry({"admin", "services", "shunetwork", "api", "toggle"},
        call("action_toggle"))
end

local CORE = "/usr/bin/shunetwork_core.sh"
local LOGFILE = "/etc/shunetwork.log"

function action_status()
    http.prepare_content("application/json")
    http.write(sys.exec(CORE .. " status 2>/dev/null"))
end

function action_log()
    http.prepare_content("text/plain; charset=utf-8")
    http.write(sys.exec("tail -n 300 " .. LOGFILE .. " 2>/dev/null"))
end

function action_ifstatus()
    http.prepare_content("application/json")
    local json = require "luci.jsonc"
    local util = require "luci.util"
    local uci = require "luci.model.uci".cursor()
    local ifname = uci:get("shunetwork", "@campus[0]", "interface") or "campus"
    local result = { name = ifname }

    local st = util.ubus("network.interface." .. ifname, "status", {})
    if type(st) == "table" and st.up then
        local addrs = st["ipv4-address"]
        if type(addrs) == "table" and type(addrs[1]) == "table" then
            result.ipv4 = addrs[1].address
        end

        local dev = st.l3_device or st.device
        if type(dev) == "string" and #dev > 0 then
            local raw = sys.exec("ip -s -j link show dev " .. dev .. " 2>/dev/null")
            local data = json.parse(raw)
            if type(data) == "table" and type(data[1]) == "table" then
                result.mtu = data[1].mtu
                if type(data[1].stats64) == "table" then
                    result.rx_bytes = data[1].stats64.rx and data[1].stats64.rx.bytes
                    result.tx_bytes = data[1].stats64.tx and data[1].stats64.tx.bytes
                end
            end
        end
    else
        result.name = nil
    end

    http.write(json.stringify(result))
end

function action_log_clear()
    sys.call(": > " .. LOGFILE .. " 2>/dev/null")
    http.prepare_content("application/json")
    http.write('{"result":"ok"}')
end

function action_login()
    sys.call(CORE .. " login >/dev/null 2>&1 &")
    http.prepare_content("application/json")
    http.write('{"result":"ok"}')
end

function action_logout()
    sys.call(CORE .. " logout >/dev/null 2>&1 &")
    http.prepare_content("application/json")
    http.write('{"result":"ok"}')
end

function action_restart()
    sys.call("/etc/init.d/shunetwork restart >/dev/null 2>&1 &")
    http.prepare_content("application/json")
    http.write('{"result":"ok"}')
end

function action_toggle()
    local state = http.formvalue("enabled")
    if state == "1" then
        sys.call("uci set shunetwork.@campus[0].enabled=1; uci commit shunetwork; /etc/init.d/shunetwork restart >/dev/null 2>&1")
    else
        sys.call("uci set shunetwork.@campus[0].enabled=0; uci commit shunetwork; /usr/bin/shunetwork_core.sh logout >/dev/null 2>&1; /etc/init.d/shunetwork stop >/dev/null 2>&1")
    end
    http.prepare_content("application/json")
    http.write('{"result":"ok"}')
end
