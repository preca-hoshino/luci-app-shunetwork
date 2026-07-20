m = Map("shucampus", translate("Campus Network"))
m.pageaction = false

s = m:section(SimpleSection)
s.template = "shucampus/log_view"

return m
