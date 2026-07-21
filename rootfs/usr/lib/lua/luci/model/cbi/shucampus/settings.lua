local uci = require "luci.model.uci".cursor()
local sys = require "luci.sys"

m = Map("shucampus", translate("SHUCampus"),
    translate("Manage Shanghai University Ruijie SAM+ portal login and keepalive."))

sb = m:section(SimpleSection)
sb.template = "shucampus/status_bar"

t = m:section(TypedSection, "campus")
t.anonymous = true

t:tab("basic", translate("Basic Settings"))

login_status = t:taboption("basic", DummyValue, "_login_status", translate("Login Status"))
login_status.rawhtml = true
function login_status.cfgvalue(self, section)
    return "<span id=\"shu_login_status\"><em>" .. translate("Collecting data ...") .. "</em></span>"
end

iface_status = t:taboption("basic", DummyValue, "_iface_status", translate("Interface Info"))
iface_status.rawhtml = true
function iface_status.cfgvalue(self, section)
    return "<span id=\"shu_iface_value\"><em>" .. translate("Collecting data ...") .. "</em></span>"
end

username = t:taboption("basic", Value, "username", translate("Username"),
    translate("Campus network portal login username"))
username.rmempty = true

password = t:taboption("basic", Value, "password", translate("Password"),
    translate("Campus network portal login password"))
password.password = true
password.rmempty = true

service = t:taboption("basic", ListValue, "service", translate("ISP"),
    translate("Select the ISP/operator for this connection"))
service:value("shu", translate("Campus Network"))
service:value("dx", translate("China Telecom"))
service:value("lt", translate("China Unicom"))
service:value("yd", translate("China Mobile"))
service.default = "shu"

-- ---- Tab: network ----
t:tab("network", translate("Network Settings"))

portal = t:taboption("network", Value, "portal", translate("Portal URL"),
    translate("Base URL of the Ruijie portal server"))
portal.rmempty = false

gateway = t:taboption("network", Value, "gateway", translate("Campus Gateway"),
    translate("IP of the campus network gateway for routing"))
gateway.rmempty = false
gateway.datatype = "ip4addr"

ifname = t:taboption("network", Value, "interface", translate("Interface Name"),
    translate("Network interface name created in /etc/config/network"))
ifname.rmempty = false

cidr = t:taboption("network", Value, "cidr", translate("Campus CIDR"),
    translate("Campus network route prefix (e.g. 10.0.0.0/8)"))
cidr.rmempty = false

keepalive = t:taboption("network", Value, "keepalive", translate("Keepalive Interval"),
    translate("Seconds between keepalive requests (60-600). Setting it too low may trigger server-side rate limiting."))
keepalive.rmempty = false
keepalive.datatype = "and(uinteger,min(60),max(600))"
keepalive.default = "120"

-- Apply immediately on save:
--   enable  -> (re)start the daemon (it resumes/adopts/logs in)
--   disable -> log the portal session out, then stop the daemon,
--              so "disabled" really means offline, not just unmanaged.
-- Read via @campus[0] to stay correct even if the section is unnamed.
function m.on_after_commit(self)
    local enabled = uci:get("shucampus", "@campus[0]", "enabled")
    if enabled == "1" then
        sys.call("/etc/init.d/shucampus restart >/dev/null 2>&1 &")
    else
        sys.call("/usr/bin/shucampus_core.sh logout >/dev/null 2>&1; /etc/init.d/shucampus stop >/dev/null 2>&1 &")
    end
end

return m
