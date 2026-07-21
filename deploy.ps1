# Build & Deploy luci-app-shucampus to router
param(
    [string]$Router = "JDCloud-AX1800-Pro"
)

$ProjectDir = Split-Path $PSCommandPath
$IpkFile = Join-Path $ProjectDir "luci-app-shucampus_1.0-1_all.ipk"
$TempScript = Join-Path $env:TEMP "deploy_shucampus.sh"

Write-Host "=== Build ===" -ForegroundColor Cyan
Push-Location $ProjectDir
wsl -- bash ipk-build.sh
if ($LASTEXITCODE -ne 0) { Write-Host "Build failed!" -ForegroundColor Red; exit 1 }

Write-Host "`n=== SCP to router ===" -ForegroundColor Cyan
scp "$IpkFile" "${Router}:/tmp/"

Write-Host "`n=== Write deploy script (LF only) ===" -ForegroundColor Cyan
$scriptContent = @'
#!/bin/sh

echo "=== Step 1: Kill old daemon ==="
/etc/init.d/shucampus stop 2>/dev/null || true
sleep 1
killall shucampus_core.sh 2>/dev/null || true

echo "=== Step 2: Install ipk ==="
opkg install /tmp/luci-app-shucampus_1.0-1_all.ipk --force-reinstall 2>&1

echo "=== Step 3: Set UCI config ==="
# The ipk ships /etc/config/shucampus with a named 'settings' section.
# Only create it when missing (e.g. first install without conffile).
uci -q get shucampus.settings >/dev/null 2>&1 || uci set shucampus.settings=campus
uci set shucampus.settings.enabled=1
uci set shucampus.settings.username=25123368
uci set shucampus.settings.password=MurphyNeveu#34494=
uci -q delete shucampus.settings.logfile
uci commit shucampus

echo "=== Step 4: Clear LuCI cache ==="
rm -rf /tmp/luci-modulecache /tmp/luci-indexcache*

echo "=== Step 5: Logout any active session ==="
GATEWAY=10.85.16.200
ip route replace default via $GATEWAY dev wan metric 5 2>/dev/null || true
IDX=$(cat /var/run/shucampus_index 2>/dev/null)
if [ -n "$IDX" ]; then
  curl -s --connect-timeout 5 -X POST "http://10.10.9.9/eportal/InterFace.do?method=logout" \
    --data-urlencode "userIndex=$IDX" >/dev/null 2>&1 || true
fi
ip route del default via $GATEWAY dev wan metric 5 2>/dev/null || true
rm -f /var/run/shucampus_index /var/run/shucampus_uptime 2>/dev/null

echo "=== Step 6: Start daemon ==="
/etc/init.d/shucampus start
sleep 12

echo ""
echo "=== Status ==="
/usr/bin/shucampus_core.sh status
echo ""
echo "=== Log ==="
tail -5 /etc/shucampus.log 2>/dev/null || tail -5 /var/log/shucampus.log
echo ""
echo "=== Online ==="
/usr/bin/shucampus_core.sh online
'@
# Write with LF-only line endings
$scriptContent -replace "`r`n", "`n" | Set-Content -Path $TempScript -NoNewline -Encoding ASCII

Write-Host "`n=== Execute on router ===" -ForegroundColor Cyan
scp $TempScript "${Router}:/tmp/deploy_run.sh"
ssh $Router "chmod +x /tmp/deploy_run.sh && /tmp/deploy_run.sh"

if ($LASTEXITCODE -eq 0) {
    Write-Host "`n=== Deploy SUCCESS ===" -ForegroundColor Green
    Write-Host "Access: http://192.168.1.1/cgi-bin/luci/ -> Services -> Campus Network" -ForegroundColor Yellow
} else {
    Write-Host "`n=== Deploy FAILED (exit: $LASTEXITCODE) ===" -ForegroundColor Red
}

Remove-Item $TempScript -Force -ErrorAction SilentlyContinue
