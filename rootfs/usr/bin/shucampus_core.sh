#!/bin/sh

LOGFILE=/var/log/shucampus.log
PIDFILE=/var/run/shucampus_index
UPTIME_FILE=/var/run/shucampus_uptime
STATE_FILE=/var/run/shucampus_state
MSG_FILE=/var/run/shucampus_msg
FAIL_FILE=/var/run/shucampus_fails
LOGIN_LOCK=/var/run/shucampus_login.lock
DPIDFILE=/var/run/shucampus_daemon.pid
# Written by the 'logout' command: while present the daemon stays offline
# on purpose (manual disconnect). Cleared by login / service start / reboot.
SUPPRESS_FILE=/var/run/shucampus_suppress

_uci() {
    uci -q get shucampus.@campus[0]."$1" 2>/dev/null || echo ""
}

# Persist daemon state for the status API. $1=state, optional $2=portal
# message. A state transition without a message clears the previous one
# (stale messages from an older state are misleading).
set_state() {
    echo "$1" > "$STATE_FILE"
    if [ $# -ge 2 ]; then
        echo "$2" > "$MSG_FILE"
    else
        rm -f "$MSG_FILE"
    fi
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
# Sanitize: non-numeric -> default; floor 60s so we never hammer the portal
case "$KEEPALIVE" in
    ''|*[!0-9]*) KEEPALIVE=120 ;;
esac
[ "$KEEPALIVE" -lt 60 ] && KEEPALIVE=60

# ---- Login failure backoff: 30s,60s,120s,300s then cap at 600s ----
# Protects the account from being rate-limited/banned by the portal when
# e.g. the password is wrong and every retry would fail anyway.
next_backoff() {
    local step="${1:-1}" fails=0
    [ -s "$FAIL_FILE" ] && read -r fails < "$FAIL_FILE"
    fails=$((fails + step))
    echo "$fails" > "$FAIL_FILE"
    case $fails in
        1)   echo 30  ;;
        2)   echo 60  ;;
        3)   echo 120 ;;
        4|5) echo 300 ;;
        *)   echo 600 ;;
    esac
}

reset_backoff() {
    rm -f "$FAIL_FILE"
}

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

# Returns: 0=logged in, 2=no redirect (waiting), 3=portal refused (auth_failed)
login_once() {
    local qs resp user_index msg
    set_state "authenticating"
    qs=$(get_query_string)
    if [ -z "$qs" ]; then
        set_state "waiting" "no captive-portal redirect (already online or NAS unreachable)"
        log WARN "cannot get query string"
        return 2
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
        return 3
    fi
}

daemon_loop() {
    local idx ka msg rc backoff
    idx=""

    # Manual disconnect has priority over any resumable session
    if [ ! -f "$SUPPRESS_FILE" ]; then
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
    fi

    while true; do
        # Manual disconnect: make sure we are really logged out, then idle
        if [ -f "$SUPPRESS_FILE" ]; then
            if [ -n "$idx" ]; then
                do_logout "$idx" >/dev/null 2>&1
                idx=""
                rm -f "$PIDFILE" "$UPTIME_FILE"
            fi
            set_state "suppressed"
            sleep 30
            continue
        fi

        if [ -z "$idx" ]; then
            log INFO "Attempting login..."
            login_once
            rc=$?
            if [ $rc -eq 0 ]; then
                idx=$(cat "$PIDFILE" 2>/dev/null)
                reset_backoff
            else
                # rc=2 (no redirect): maybe we are actually online already -
                # worth one probe. rc=3 (portal refused): asking again is
                # pointless and only adds request pressure, skip the probe.
                if [ $rc -eq 2 ]; then
                    idx=$(recover_online_session)
                    if [ -n "$idx" ]; then
                        set_state "online"
                        reset_backoff
                        log INFO "Adopted portal session  userIndex=${idx}"
                        continue
                    fi
                    backoff=$(next_backoff)
                else
                    # auth_failed: jump ahead in the backoff ladder, wrong
                    # credentials will never start working by retrying fast
                    backoff=$(next_backoff 3)
                fi
                log INFO "retry login in ${backoff}s"
                sleep "$backoff"
                continue
            fi
        fi

        sleep "${KEEPALIVE:-120}"
        ka=$(do_keepalive "$idx")
        if echo "$ka" | grep -q "success"; then
            set_state "online"
            reset_backoff
            log INFO "Keepalive OK"
        else
            msg=$(portal_msg "$ka")
            set_state "offline" "$msg"
            log WARN "Keepalive FAIL: ${msg:-$ka}"
            idx=""
            rm -f "$PIDFILE" "$UPTIME_FILE"
            # loop back to login; the backoff ladder limits request rate
        fi
    done
}

case "${1:-}" in
    daemon)
        # Single-instance guard: a stale/extra procd spawn or manual run
        # must not start a second keepalive loop. flock(1) from BusyBox is
        # unreliable on this platform, so use a plain pid file instead.
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
        # Mutex: repeated clicks on "Login Now" must not spawn parallel
        # logins against the portal. mkdir is atomic (unlike test+touch,
        # which has a TOCTOU race). Lock is valid for 60s.
        if ! mkdir "$LOGIN_LOCK" 2>/dev/null; then
            lock_age=$(( $(date +%s) - $(stat -c%Y "$LOGIN_LOCK" 2>/dev/null || echo 0) ))
            if [ "$lock_age" -lt 60 ]; then
                echo "login already in progress"
                exit 1
            fi
            rm -rf "$LOGIN_LOCK"
            mkdir "$LOGIN_LOCK" 2>/dev/null || exit 1
        fi
        trap 'rm -rf "$LOGIN_LOCK"' EXIT

        # A manual login clears the manual-disconnect suppression
        rm -f "$SUPPRESS_FILE"

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
        date +%s > "$SUPPRESS_FILE"
        set_state "suppressed"
        log INFO "Logged out (manual disconnect, auto-reconnect suppressed)"
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
        # Check via the daemon's own pid file: pgrep -f would match the
        # caller's own shell (its command line contains the pattern too).
        if [ -s "$DPIDFILE" ]; then
            read -r dpid < "$DPIDFILE"
            if [ -n "$dpid" ] && [ -d "/proc/$dpid" ] && \
               tr '\0' ' ' < "/proc/$dpid/cmdline" 2>/dev/null | grep -q "shucampus_core"; then
                daemon_running=true
            fi
        fi
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
