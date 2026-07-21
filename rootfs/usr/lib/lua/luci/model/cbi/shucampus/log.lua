m = Map("shucampus", translate("SHUCampus"))
m.pageaction = false

s = m:section(SimpleSection)
s.template = "shucampus/log_view"

return m
