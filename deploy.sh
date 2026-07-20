#!/bin/bash
# Build & Deploy luci-app-shucampus to router
set -e

ROUTER="${1:-JDCloud-AX1800-Pro}"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
IPK_FILE="$PROJECT_DIR/luci-app-shucampus_1.0-1_all.ipk"

echo "=== Build ==="
bash "$PROJECT_DIR/ipk-build.sh"

echo ""
echo "=== SCP to router ==="
scp "$IPK_FILE" "$ROUTER:/tmp/"

echo ""
echo "=== Write deploy script ==="
cat > /tmp/deploy_shucampus.sh << 'DEPLOYEOF'
#!/bin/sh
set -e

echo "Killing old daemon..."
killall shucampus_core.sh 2>/dev/null || true
/etc/init.d/shucampus stop 2>/dev/null || true
sleep 1

echo "Installing ipk..."
opkg install /tmp/luci-app-shucampus_1.0-1_all.ipk --force-reinstall 2>&1

echo "Setting UCI config..."
touch /etc/config/shucampus 2>/dev/null
uci -q add shucampus campus 2>/dev/null || true
uci set shucampus.settings.enabled=1
uci set shucampus.settings.username=25123368
uci set shucampus.settings.password=MurphyNeveu#34494=
uci commit shucampus

echo "Clearing LuCI cache..."
rm -rf /tmp/luci-modulecache /tmp/luci-indexcache*

echo "Logging out any active session..."
GATEWAY=10.85.16.200
ip route replace default via $GATEWAY dev wan metric 5 2>/dev/null
IDX=$(cat /var/run/shucampus_index 2>/dev/null)
[ -n "$IDX" ] && curl -s --connect-timeout 5 -X POST "http://10.10.9.9/eportal/InterFace.do?method=logout" \
  --data-urlencode "userIndex=$IDX" >/dev/null 2>&1
ip route del default via $GATEWAY dev wan metric 5 2>/dev/null
rm -f /var/run/shucampus_index /var/run/shucampus_uptime 2>/dev/null

echo "Starting daemon..."
/etc/init.d/shucampus start
sleep 12

echo "=== Status ==="
/usr/bin/shucampus_core.sh status
echo ""
echo "=== Log ==="
tail -5 /var/log/shucampus.log
DEPLOYEOF

echo ""
echo "=== Execute on router ==="
scp /tmp/deploy_shucampus.sh "$ROUTER:/tmp/deploy_run.sh"
ssh "$ROUTER" "chmod +x /tmp/deploy_run.sh && /tmp/deploy_run.sh"

rm -f /tmp/deploy_shucampus.sh

echo ""
echo "=== Deploy SUCCESS ==="
echo "Access: http://192.168.1.1/cgi-bin/luci/ -> Services -> Campus Network"
