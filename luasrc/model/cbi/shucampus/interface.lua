m = Map("shucampus", translate("SHU Network"),
    translate("Ruijie SAM+ portal authentication client."))
m.pageaction = false

s = m:section(SimpleSection)
s.template = "shucampus/interface-status"

return m
