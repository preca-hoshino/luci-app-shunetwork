#!/bin/sh
GATEWAY=10.85.16.200

echo "=== Getting QS ==="
ip route replace default via $GATEWAY dev wan metric 5 2>/dev/null
resp=$(curl -s --connect-timeout 5 http://1.1.1.1/ 2>/dev/null)
ip route del default via $GATEWAY dev wan metric 5 2>/dev/null
QS=$(echo "$resp" | sed -n "s/.*index\.jsp?\(.*\)'.*/\1/p")
echo "QS=$QS"
echo ""

echo "=== Test 1: with queryString ==="
curl -s --connect-timeout 10 -X POST "http://10.10.9.9/eportal/InterFace.do?method=login" \
  -d "userId=25123368" \
  -d "password=MurphyNeveu#34494=" \
  -d "service=shu" \
  --data-urlencode "queryString=$QS" \
  -d "passwordEncrypt=false"
echo ""
echo ""

echo "=== Test 2: no queryString ==="
curl -s --connect-timeout 10 -X POST "http://10.10.9.9/eportal/InterFace.do?method=login" \
  -d "userId=25123368" \
  -d "password=MurphyNeveu#34494=" \
  -d "service=shu" \
  -d "passwordEncrypt=false"
echo ""
echo ""

echo "=== Test 3: URL-encoded queryString ==="
QSENC=$(echo "$QS" | sed 's/&/%26/g; s/=/%3D/g')
curl -s --connect-timeout 10 "http://10.10.9.9/eportal/InterFace.do?method=login&userId=25123368&password=MurphyNeveu%252334494%253D&service=shu&queryString=${QSENC}&passwordEncrypt=false"
echo ""
