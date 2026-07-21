#!/bin/bash
# Build luci-app-shunetwork .ipk
# Source layout: luasrc/ (LuCI Lua), root/ (filesystem), po/ (translations)
set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd -W 2>/dev/null || pwd)"
LUASRC="$PROJECT_DIR/luasrc"
ROOT="$PROJECT_DIR/root"
PO_SRC="$PROJECT_DIR/po/zh-cn/shunetwork.zh-cn.po"
PKG_NAME="luci-app-shunetwork"
VERSION="1.0"
RELEASE="1"

BUILD_DIR=$(mktemp -d)
WORK_DIR="$BUILD_DIR/work"
DATA_DIR="$BUILD_DIR/data"
CTRL_DIR="$BUILD_DIR/ctrl"

mkdir -p "$WORK_DIR" "$DATA_DIR" "$CTRL_DIR"

echo "=== Build $PKG_NAME ==="

# Step 1: Copy root/ filesystem overlay
echo "[1/5] Copying files..."
find "$ROOT" -type f | while read f; do
    rel="${f#$ROOT}"
    rel="${rel#/}"
    dst="$DATA_DIR/$rel"
    mkdir -p "$(dirname "$dst")"
    cp "$f" "$dst"
done

# Step 2: Copy luasrc/ into LuCI path
find "$LUASRC" -type f | while read f; do
    rel="${f#$LUASRC}"
    rel="${rel#/}"
    dst="$DATA_DIR/usr/lib/lua/luci/$rel"
    mkdir -p "$(dirname "$dst")"
    cp "$f" "$dst"
done

# Set permissions
find "$DATA_DIR/etc/init.d" -type f -exec chmod 755 {} \;
find "$DATA_DIR/usr/bin" -type f -exec chmod 755 {} \;
find "$DATA_DIR" -type f ! -path "*/init.d/*" ! -path "*/usr/bin/*" -exec chmod 644 {} \;

SIZE_KB=$(du -sk "$DATA_DIR" | cut -f1)
[ "$SIZE_KB" -lt 1 ] && SIZE_KB=1

# Step 3: Create control files
echo "[2/5] Writing control files..."
cat > "$CTRL_DIR/control" << 'CTRLEOF'
Package: luci-app-shunetwork
Version: 1.0-1
Depends: luci-base, curl
Source: package/luci-app-shunetwork
Section: luci
Priority: optional
Maintainer: Preca
Architecture: all
Installed-Size: CTRL_PLACEHOLDER
 Description: Ruijie SAM+ Portal login and keepalive daemon with LuCI
  Manage Shanghai University campus network authentication.
CTRLEOF
sed -i "s/CTRL_PLACEHOLDER/$SIZE_KB/" "$CTRL_DIR/control"

cat > "$CTRL_DIR/postinst" << 'POSTEOF'
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] || {
    chmod 755 /etc/init.d/shunetwork 2>/dev/null
    chmod 755 /usr/bin/shunetwork_core.sh 2>/dev/null
    /etc/init.d/shunetwork enable 2>/dev/null || true
}
exit 0
POSTEOF
chmod 755 "$CTRL_DIR/postinst"

# Compile translations (.po → .lmo)
echo "[3/5] Compiling translations..."
mkdir -p "$DATA_DIR/usr/lib/lua/luci/i18n"
if [ -s "$PO_SRC" ]; then
    if python3 "$PROJECT_DIR/tools/po2lmo.py" "$PO_SRC" \
        "$DATA_DIR/usr/lib/lua/luci/i18n/shunetwork.zh-cn.lmo" 2>/dev/null; then
        chmod 644 "$DATA_DIR/usr/lib/lua/luci/i18n/shunetwork.zh-cn.lmo"
        echo "    zh-cn translation compiled"
    else
        echo "    WARNING: po2lmo failed, translation skipped"
    fi
fi

# Step 4: Create tarballs
echo "[4/5] Creating data.tar.gz..."
(cd "$DATA_DIR" && tar --owner=0 --group=0 -czf "$WORK_DIR/data.tar.gz" .)

echo "[5/5] Creating control.tar.gz..."
(cd "$CTRL_DIR" && tar --owner=0 --group=0 -czf "$WORK_DIR/control.tar.gz" control postinst)

# Assemble .ipk
echo "       Assembling .ipk..."
echo "2.0" > "$WORK_DIR/debian-binary"
(cd "$WORK_DIR" && tar --owner=0 --group=0 -czf "$PROJECT_DIR/${PKG_NAME}_${VERSION}-${RELEASE}_all.ipk" \
    debian-binary control.tar.gz data.tar.gz)

# Cleanup
rm -rf "$BUILD_DIR"

echo "=== Done ==="
ls -lh "$PROJECT_DIR/${PKG_NAME}_${VERSION}-${RELEASE}_all.ipk"
