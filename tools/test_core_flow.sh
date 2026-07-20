#!/bin/sh
# Simulate exactly what get_query_string() in the core script does

GATEWAY=10.85.16.200

echo "=== Step 1: check gateway route ==="
ip route show | grep "$GATEWAY"

echo ""
echo "=== Step 2: add temp default via campus ==="
ip route replace default via "$GATEWAY" dev wan metric 5

echo ""
echo "=== Step 3: curl 1.1.1.1 ==="
resp=$(curl -s --connect-timeout 5 "http://1.1.1.1/" 2>/dev/null)
echo "First 300 chars:"
echo "$resp" | head -c 300
echo ""

echo ""
echo "=== Step 4: grep+sed (core script pattern) ==="
qs=$(echo "$resp" | grep -o "index\.jsp?\(.*\)'" | sed "s/index.jsp?//;s/'//")
echo "QS=[$qs]"
echo "len=${#qs}"

echo ""
echo "=== Step 5: cleanup route ==="
ip route del default via "$GATEWAY" dev wan metric 5
echo "done"
