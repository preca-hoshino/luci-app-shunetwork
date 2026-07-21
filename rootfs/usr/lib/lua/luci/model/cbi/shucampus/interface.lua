m = Map("shucampus", translate("SHUCampus"),
    translate("Ruijie SAM+ portal authentication client."))
m.pageaction = false

s = m:section(SimpleSection)
s.template = "shucampus/interface_status"

return m
