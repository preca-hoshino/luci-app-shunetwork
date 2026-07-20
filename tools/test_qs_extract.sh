#!/bin/sh
GATEWAY=10.85.16.200
ip route replace default via "$GATEWAY" dev wan metric 5 2>/dev/null
resp=$(curl -s --connect-timeout 5 "http://1.1.1.1/" 2>/dev/null)
ip route del default via "$GATEWAY" dev wan metric 5 2>/dev/null

echo "=== Raw response (first 200 chars) ==="
echo "$resp" | head -c 200
echo ""

echo "=== Core script pattern (grep+sed) ==="
qs1=$(echo "$resp" | grep -o 'index\.jsp?\(.*\)'"'"'' | sed "s/index.jsp?//;s/'//")
echo "[$qs1]"
echo "len=${#qs1}"

echo "=== Debug script pattern (sed -n) ==="
qs2=$(echo "$resp" | sed -n "s/.*index\.jsp?\(.*\)'.*/\1/p")
echo "[$qs2]"
echo "len=${#qs2}"
