local http = require "luci.http"

module("luci.controller.shucampus", package.seeall)

function index()
    entry({"admin", "services", "shucampus"},
        cbi("shucampus"),
        _("Campus Network"), 80
    )

    entry({"admin", "services", "shucampus", "status"},
        call("action_status"))

    entry({"admin", "services", "shucampus", "log"},
        call("action_log"))

    entry({"admin", "services", "shucampus", "login"},
        call("action_login"))

    entry({"admin", "services", "shucampus", "logout"},
        call("action_logout"))

    entry({"admin", "services", "shucampus", "restart"},
        call("action_restart"))
end

local CORE = "/usr/bin/shucampus_core.sh"

function action_status()
    http.prepare_content("application/json")
    http.write(luci.sys.exec(CORE .. " status 2>/dev/null"))
end

function action_log()
    http.prepare_content("text/plain; charset=utf-8")
    http.write(luci.sys.exec("tail -n 150 /var/log/shucampus.log 2>/dev/null"))
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
