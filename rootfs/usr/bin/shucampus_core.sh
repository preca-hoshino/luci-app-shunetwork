#!/bin/sh

LOGFILE=/var/log/shucampus.log
PIDFILE=/var/run/shucampus_index
UPTIME_FILE=/var/run/shucampus_uptime
STATE_FILE=/var/run/shucampus_state
MSG_FILE=/var/run/shucampus_msg

_uci() {
    uci -q get shucampus.@campus[0]."$1" 2>/dev/null || echo ""
}

# Persist daemon state for the status API. $1=state, optional $2=portal message
set_state() {
    echo "$1" > "$STATE_FILE"
    [ $# -ge 2 ] && echo "$2" > "$MSG_FILE"
    return 0
}

json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

USERNAME=$(_uci username)
PASSWORD=$(_uci password)
SERVICE=$(_uci service)
PORTAL=$(_uci portal)
GATEWAY=$(_uci gateway)
KEEPALIVE=$(_uci keepalive)
[ -z "$KEEPALIVE" ] && KEEPALIVE=120

# log [LEVEL] message...  (LEVEL defaults to INFO)
# Rotates the log at ~64KB, keeping the last 200 lines.
log() {
    local level=INFO sz
    case "${1:-}" in
        INFO|WARN|ERROR) level=$1; shift ;;
    esac
    sz=$(wc -c < "$LOGFILE" 2>/dev/null || echo 0)
    if [ "${sz:-0}" -gt 65536 ]; then
        tail -n 200 "$LOGFILE" > "$LOGFILE.tmp" 2>/dev/null && mv "$LOGFILE.tmp" "$LOGFILE"
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" >> "$LOGFILE"
}

get_query_string() {
    local resp qs i
    for i in 1 2 3; do
        ip route replace default via "$GATEWAY" dev wan metric 5 2>/dev/null
        resp=$(curl -s --connect-timeout 5 "http://1.1.1.1/" 2>/dev/null)
        ip route del default via "$GATEWAY" dev wan metric 5 2>/dev/null
        qs=$(echo "$resp" | grep -o "index\.jsp?\(.*\)'" | sed "s/index.jsp?//;s/'//")
        [ -n "$qs" ] && { echo "$qs"; return 0; }
        [ "$i" -lt 3 ] && sleep 5
    done
    return 1
}

do_login() {
    local qs="$1"
    curl -s --connect-timeout 10 -X POST "$PORTAL/InterFace.do?method=login" \
        --data-urlencode "userId=$USERNAME" \
        --data-urlencode "password=$PASSWORD" \
        --data-urlencode "service=$SERVICE" \
        --data-urlencode "queryString=$qs" \
        --data-urlencode "operatorPwd=" \
        --data-urlencode "operatorUserId=" \
        --data-urlencode "validcode=" \
        --data-urlencode "passwordEncrypt=false"
}

do_keepalive() {
    local idx="$1"
    curl -s --connect-timeout 5 -X POST "$PORTAL/InterFace.do?method=keepalive" \
        --data-urlencode "userIndex=$idx"
}

do_logout() {
    local idx="$1"
    curl -s --connect-timeout 5 -X POST "$PORTAL/InterFace.do?method=logout" \
        --data-urlencode "userIndex=$idx"
}

# Query portal for the session bound to our current WAN IP.
# Prints userIndex and returns 0 when an active session for USERNAME exists.
recover_online_session() {
    local resp uid uidx
    ip route replace default via "$GATEWAY" dev wan metric 5 2>/dev/null
    resp=$(curl -s --connect-timeout 5 -X POST "$PORTAL/InterFace.do?method=getOnlineUserInfo" \
        --data-urlencode "userIndex=" 2>/dev/null)
    ip route del default via "$GATEWAY" dev wan metric 5 2>/dev/null
    echo "$resp" | grep -q '"result":"success"' || return 1
    uid=$(echo "$resp" | grep -o '"userId":"[^"]*"' | head -1 | cut -d'"' -f4)
    uidx=$(echo "$resp" | grep -o '"userIndex":"[^"]*"' | head -1 | cut -d'"' -f4)
    # When USERNAME is configured, only adopt sessions that belong to us
    if [ -n "$uidx" ] && { [ -z "$USERNAME" ] || [ "$uid" = "$USERNAME" ]; }; then
        echo "$uidx" > "$PIDFILE"
        [ -s "$UPTIME_FILE" ] || date '+%s' > "$UPTIME_FILE"
        echo "$uidx"
        return 0
    fi
    return 1
}

# Extract "message" field from a portal JSON reply
portal_msg() {
    echo "$1" | grep -o '"message":"[^"]*"' | head -1 | cut -d'"' -f4
}

login_once() {
    local qs resp user_index msg
    set_state "authenticating"
    qs=$(get_query_string)
    if [ -z "$qs" ]; then
        set_state "waiting" "no captive-portal redirect (already online or NAS unreachable)"
        log WARN "cannot get query string"
        return 1
    fi
    resp=$(do_login "$qs")
    user_index=$(echo "$resp" | grep -o '"userIndex":"[^"]*"' | cut -d'"' -f4)
    if [ -n "$user_index" ]; then
        echo "$user_index" > "$PIDFILE"
        date '+%s' > "$UPTIME_FILE"
        set_state "online"
        log INFO "Login OK  userIndex=${user_index}"
        return 0
    else
        msg=$(portal_msg "$resp")
        [ -z "$msg" ] && msg=$(echo "$resp" | tr -d '\r\n' | cut -c1-120)
        set_state "auth_failed" "$msg"
        log ERROR "Login FAIL: $msg"
        return 1
    fi
}

daemon_loop() {
    local idx ka msg
    idx=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "$idx" ]; then
        ka=$(do_keepalive "$idx")
        if echo "$ka" | grep -q "success"; then
            set_state "online"
            log INFO "Resumed session  userIndex=${idx}"
        else
            log WARN "Previous session expired"
            idx=""
            rm -f "$PIDFILE" "$UPTIME_FILE"
        fi
    fi

    # No valid local state: the portal may still hold a live session for
    # this WAN IP (e.g. after a daemon restart). Adopt it instead of
    # hammering the captive-portal redirect which never fires while online.
    if [ -z "$idx" ]; then
        idx=$(recover_online_session)
        if [ -n "$idx" ]; then
            set_state "online"
            log INFO "Adopted portal session  userIndex=${idx}"
        fi
    fi

    while true; do
        if [ -z "$idx" ]; then
            log INFO "Attempting login..."
            if login_once; then
                idx=$(cat "$PIDFILE" 2>/dev/null)
            else
                # Login failed - maybe we are already online and the NAS
                # does not intercept. Re-check before the retry wait.
                idx=$(recover_online_session)
                if [ -n "$idx" ]; then
                    set_state "online"
                    log INFO "Adopted portal session  userIndex=${idx}"
                else
                    sleep 30
                    continue
                fi
            fi
        fi

        sleep "${KEEPALIVE:-120}"
        ka=$(do_keepalive "$idx")
        if echo "$ka" | grep -q "success"; then
            set_state "online"
            log INFO "Keepalive OK"
        else
            msg=$(portal_msg "$ka")
            set_state "offline" "$msg"
            log WARN "Keepalive FAIL: ${msg:-$ka}"
            idx=""
            rm -f "$PIDFILE" "$UPTIME_FILE"
        fi
    done
}

case "${1:-}" in
    daemon)
        # Single-instance guard: a stale/extra procd spawn or manual run
        # must not start a second keepalive loop. flock(1) from BusyBox is
        # unreliable on this platform, so use a plain pid file instead.
        DPIDFILE=/var/run/shucampus_daemon.pid
        if [ -f "$DPIDFILE" ]; then
            oldpid=$(cat "$DPIDFILE" 2>/dev/null)
            if [ -n "$oldpid" ] && [ -d "/proc/$oldpid" ] && \
               tr '\0' ' ' < "/proc/$oldpid/cmdline" 2>/dev/null | grep -q "shucampus_core"; then
                exit 0
            fi
        fi
        echo $$ > "$DPIDFILE"
        daemon_loop
        ;;
    login)
        # If the portal already holds a session for this WAN IP, adopt it
        # instead of forcing a re-auth (which would flap the state to
        # "waiting" until the next keepalive fixes it).
        idx=$(recover_online_session)
        if [ -n "$idx" ]; then
            set_state "online"
            log INFO "Already online, adopted session  userIndex=${idx}"
            exit 0
        fi
        login_once
        ;;
    logout)
        idx=$(cat "$PIDFILE" 2>/dev/null)
        [ -n "$idx" ] && do_logout "$idx" >/dev/null 2>&1
        rm -f "$PIDFILE" "$UPTIME_FILE" "$STATE_FILE" "$MSG_FILE"
        log INFO "Logged out"
        ;;
    online)
        resp=$(get_query_string)
        if [ -z "$resp" ]; then
            echo "online"
        else
            echo "offline"
        fi
        ;;
    status)
        enabled=$(_uci enabled)
        [ -z "$enabled" ] && enabled=0
        idx=""
        msg=""
        state=""
        daemon_running=false
        campus_ip=$(ip -4 addr show dev wan 2>/dev/null | awk '/inet 10\./{print $2}' | cut -d/ -f1)
        pgrep -f "shucampus_core.sh daemon" >/dev/null 2>&1 && daemon_running=true
        [ -s "$PIDFILE" ] && read -r idx < "$PIDFILE"

        # State machine: disabled > stopped > persisted state > inferred
        if [ "$enabled" != "1" ]; then
            state="disabled"
        elif [ "$daemon_running" != "true" ]; then
            state="stopped"
        elif [ -s "$STATE_FILE" ]; then
            read -r state < "$STATE_FILE"
        elif [ -n "$idx" ]; then
            state="online"
        else
            state="authenticating"
        fi

        [ -s "$MSG_FILE" ] && read -r msg < "$MSG_FILE"
        [ -s "$UPTIME_FILE" ] && read -r uptime < "$UPTIME_FILE" && uptime=$(date -d "@$uptime" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)

        printf '{"enabled":"%s","daemon_running":%s,"state":"%s","campus_ip":"%s"' \
            "$enabled" "$daemon_running" "$state" "${campus_ip:-}"
        [ -n "$idx" ] && printf ',"user_index":"%s"' "$idx"
        [ -n "$uptime" ] && printf ',"uptime":"%s"' "$uptime"
        [ -n "$msg" ] && printf ',"state_msg":"%s"' "$(json_escape "$msg")"
        printf '}\n'
        ;;
    *)
        echo "Usage: $0 {daemon|login|logout|status|online}"
        exit 1
        ;;
esac
