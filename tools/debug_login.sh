#!/bin/sh
GATEWAY=10.85.16.200

get_qs() {
    ip route replace default via $GATEWAY dev wan metric 5 2>/dev/null
    resp=$(curl -s --connect-timeout 5 http://1.1.1.1/ 2>/dev/null)
    ip route del default via $GATEWAY dev wan metric 5 2>/dev/null
    # Extract the query string from the redirect URL
    echo "$resp" | sed -n "s/.*index\.jsp?\(.*\)'.*/\1/p"
}

echo "=== QS ==="
QS=$(get_qs)
echo "len=${#QS}"
echo "QS=$QS"
echo ""

if [ -n "$QS" ]; then
    echo "=== Login ==="
    resp=$(curl -s --connect-timeout 10 -X POST "http://10.10.9.9/eportal/InterFace.do?method=login" \
        -d "userId=25123368" \
        -d "password=MurphyNeveu#34494=" \
        -d "service=shu" \
        --data-urlencode "queryString=$QS" \
        -d "passwordEncrypt=false")
    echo "$resp"
    echo ""
    uid=$(echo "$resp" | sed -n 's/.*"userIndex":"\([^"]*\)".*/\1/p')
    echo "userIndex=$uid"
    
    if [ -n "$uid" ]; then
        echo ""
        echo "=== Keepalive ==="
        curl -s --connect-timeout 5 "http://10.10.9.9/eportal/InterFace.do?method=keepalive" \
            -d "userIndex=$uid"
    fi
else
    echo "FAILED to get query string"
fi
