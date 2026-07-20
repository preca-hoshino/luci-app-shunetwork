local uci = require "luci.model.uci".cursor()

m = Map("shucampus", translate("Campus Network Authentication"),
    translate("Manage Shanghai University Ruijie SAM+ portal login and keepalive. The daemon automatically authenticates and maintains the campus network session."))

-- ========== Account settings ==========
t = m:section(TypedSection, "campus", translate("Account Settings"))
t.anonymous = true

enable = t:option(Flag, "enabled", translate("Enable"),
    translate("Enable campus network auto-authentication at boot"))
enable.rmempty = false

username = t:option(Value, "username", translate("Username"),
    translate("Campus network portal login username"))
username.rmempty = true

password = t:option(Value, "password", translate("Password"),
    translate("Campus network portal login password"))
password.password = true
password.rmempty = true

service = t:option(ListValue, "service", translate("ISP"),
    translate("Select the ISP/operator for this connection"))
service:value("shu", translate("Campus Network"))
service:value("dx", translate("China Telecom"))
service:value("lt", translate("China Unicom"))
service:value("yd", translate("China Mobile"))
service.default = "shu"

-- ========== Network settings ==========
n = m:section(TypedSection, "campus", translate("Network Settings"))
n.anonymous = true

portal = n:option(Value, "portal", translate("Portal URL"),
    translate("Base URL of the Ruijie portal server"))
portal.rmempty = false

gateway = n:option(Value, "gateway", translate("Campus Gateway"),
    translate("IP of the campus network gateway for routing"))
gateway.rmempty = false
gateway.datatype = "ip4addr"

ifname = n:option(Value, "interface", translate("Interface Name"),
    translate("Network interface name created in /etc/config/network"))
ifname.rmempty = false

cidr = n:option(Value, "cidr", translate("Campus CIDR"),
    translate("Campus network route prefix (e.g. 10.0.0.0/8)"))
cidr.rmempty = false

keepalive = n:option(Value, "keepalive", translate("Keepalive Interval"),
    translate("Seconds between keepalive requests"))
keepalive.rmempty = false
keepalive.datatype = "uinteger"
keepalive.default = "120"

function m.on_after_commit(self)
    uci:foreach("shucampus", "campus",
        function(s)
            if s.enabled == "1" then
                luci.sys.call("/etc/init.d/shucampus restart >/dev/null 2>&1 &")
                return false
            end
        end
    )
end

return m
