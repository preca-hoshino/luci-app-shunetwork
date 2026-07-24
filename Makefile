include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-shunetwork
PKG_VERSION:=1.0
PKG_RELEASE:=5

PKG_LICENSE:=GPL-3.0
PKG_MAINTAINER:=Preca

LUCI_TITLE:=Campus Network Authentication
LUCI_DESCRIPTION:=Ruijie SAM+ Portal login and keepalive daemon with LuCI interface
LUCI_DEPENDS:=+luci-base +curl
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# Automatic install via luci.mk:
#   luasrc/ -> /usr/lib/lua/luci/
#   root/   -> /
#   po/     -> .lmo -> /usr/lib/lua/luci/i18n/

define Package/luci-app-shunetwork/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
    /etc/init.d/shunetwork enable 2>/dev/null || true
}
exit 0
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
