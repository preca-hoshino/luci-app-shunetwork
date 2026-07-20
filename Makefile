include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-shucampus
PKG_VERSION:=1.0
PKG_RELEASE:=1

PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=Preca <preca@example.com>

LUCI_TITLE:=Campus Network Authentication
LUCI_DESCRIPTION:=Ruijie SAM+ Portal login and keepalive daemon with LuCI interface
LUCI_DEPENDS:=+luci-base +curl
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

define Package/luci-app-shucampus/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
    /etc/init.d/shucampus enable 2>/dev/null || true
}
exit 0
endef

$(eval $(call BuildPackage,luci-app-shucampus))
