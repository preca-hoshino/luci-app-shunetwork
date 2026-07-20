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
