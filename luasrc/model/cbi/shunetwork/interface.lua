m = Map("shunetwork", translate("SHU Network"),
    translate("Ruijie SAM+ portal authentication client."))
m.pageaction = false

s = m:section(SimpleSection)
s.template = "shunetwork/interface-status"

return m
