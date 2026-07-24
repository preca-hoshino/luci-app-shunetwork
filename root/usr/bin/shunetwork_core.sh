#!/bin/sh

LOGFILE=/etc/shunetwork.log
PIDFILE=/var/run/shunetwork_index
UPTIME_FILE=/var/run/shunetwork_uptime
STATE_FILE=/var/run/shunetwork_state
MSG_FILE=/var/run/shunetwork_msg
FAIL_FILE=/var/run/shunetwork_fails
LOGIN_LOCK=/var/run/shunetwork_login.lock
DPIDFILE=/var/run/shunetwork_daemon.pid
ROUTE_LOCK=/var/run/shunetwork_route.lock
# Written by the 'logout' command: while present the daemon stays offline
# on purpose (manual disconnect). Cleared by login / service start / reboot.
SUPPRESS_FILE=/var/run/shunetwork_suppress

_uci() {
    uci -q get shunetwork.@campus[0]."$1" 2>/dev/null || echo ""
}

_campus_dev() {
    local dev
    dev=$(_uci device)
    echo "${dev:-wan}"
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

reload_config() {
    USERNAME=$(_uci username)
    PASSWORD=$(_uci password)
    SERVICE=$(_uci service)
    PORTAL=$(_uci portal)
    GATEWAY=$(_uci gateway)
    KEEPALIVE=$(_uci keepalive)
    # Defaults for everything non-credential (mirror /etc/config/shunetwork)
    [ -z "$SERVICE" ]   && SERVICE=shu
    [ -z "$PORTAL" ]    && PORTAL=http://10.10.9.9/eportal
    [ -z "$GATEWAY" ]   && GATEWAY=10.85.16.200
    # Sanitize keepalive: non-numeric -> default; floor 60s (anti-hammer)
    case "$KEEPALIVE" in
        ''|*[!0-9]*) KEEPALIVE=120 ;;
    esac
    [ "$KEEPALIVE" -lt 60 ] && KEEPALIVE=60
}

# Missing credentials make every login attempt pointless - report once
# and let the daemon idle in config_error until the config appears.
config_check() {
    local missing=""
    [ -z "$USERNAME" ] && missing="$missing username"
    [ -z "$PASSWORD" ] && missing="$missing password"
    if [ -n "$missing" ]; then
        set_state "config_error" "missing:$missing"
        return 1
    fi
    return 0
}

reload_config

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
# Rotates the log at ~64KB (keeps the last 200 lines). Everything goes to
# the log file; WARN/ERROR and non-routine INFO events are also mirrored
# to syslog so they appear in logread and any configured persistent log.
log() {
    local level=INFO sz
    case "${1:-}" in
        DEBUG|INFO|WARN|ERROR) level=$1; shift ;;
    esac
    sz=$(wc -c < "$LOGFILE" 2>/dev/null || echo 0)
    if [ "${sz:-0}" -gt 65536 ]; then
        tail -n 200 "$LOGFILE" > "$LOGFILE.tmp" 2>/dev/null && mv "$LOGFILE.tmp" "$LOGFILE"
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" >> "$LOGFILE"
    case "$level" in
        ERROR) logger -t shunetwork -p daemon.err -- "$*" 2>/dev/null ;;
        WARN)  logger -t shunetwork -p daemon.warning -- "$*" 2>/dev/null ;;
        INFO)
            case "$*" in
                "Keepalive OK"*|"QS attempt"*|"retry login"*) : ;;
                *) logger -t shunetwork -p daemon.notice -- "$*" 2>/dev/null ;;
            esac
            ;;
    esac
    return 0
}

# First 120 chars of a string with newlines stripped, for one-line logging
short() {
    echo "$1" | tr '\r\n' '  ' | cut -c1-120
}

get_query_string() {
    local resp qs i rc pppoe_default
    for i in 1 2 3; do
        if ! route_lock; then
            log WARN "QS attempt $i: route lock busy, skipped"
            [ "$i" -lt 3 ] && sleep 5 && continue
            return 1
        fi
        pppoe_default=$(ip route show default | grep pppoe-wan | head -1)
        ip route replace default via "$GATEWAY" dev "$(_campus_dev)" 2>/dev/null
        resp=$(curl -sS --connect-timeout 5 "http://1.1.1.1/" 2>&1)
        rc=$?
        ip route flush default 2>/dev/null
        [ -n "$pppoe_default" ] && ip route add $pppoe_default 2>/dev/null
        route_unlock
        if [ $rc -ne 0 ]; then
            log WARN "QS attempt $i: curl failed (rc=$rc): $(short "$resp")"
        else
            qs=$(echo "$resp" | grep -o "index\.jsp?\(.*\)'" | sed "s/index.jsp?//;s/'//")
            if [ -n "$qs" ]; then
                log INFO "QS attempt $i: got redirect query string (${#qs} chars)"
                echo "$qs"
                return 0
            fi
            log WARN "QS attempt $i: no redirect in reply (${#resp} bytes): $(short "$resp")"
        fi
        [ "$i" -lt 3 ] && sleep 5
    done
    return 1
}

do_login() {
    local qs="$1" resp rc
    resp=$(curl -sS --connect-timeout 10 -X POST "$PORTAL/InterFace.do?method=login" \
        --data-urlencode "userId=$USERNAME" \
        --data-urlencode "password=$PASSWORD" \
        --data-urlencode "service=$SERVICE" \
        --data-urlencode "queryString=$qs" \
        --data-urlencode "operatorPwd=" \
        --data-urlencode "operatorUserId=" \
        --data-urlencode "validcode=" \
        --data-urlencode "passwordEncrypt=false" 2>&1)
    rc=$?
    [ $rc -ne 0 ] && log ERROR "login request failed (curl rc=$rc): $(short "$resp")"
    echo "$resp"
    return $rc
}

do_keepalive() {
    local idx="$1" resp rc
    resp=$(curl -sS --connect-timeout 5 -X POST "$PORTAL/InterFace.do?method=keepalive" \
        --data-urlencode "userIndex=$idx" 2>&1)
    rc=$?
    [ $rc -ne 0 ] && log ERROR "keepalive request failed (curl rc=$rc): $(short "$resp")"
    echo "$resp"
    return $rc
}

do_logout() {
    local idx="$1"
    curl -sS --connect-timeout 5 -X POST "$PORTAL/InterFace.do?method=logout" \
        --data-urlencode "userIndex=$idx" 2>&1
}

# Serialize the temporary default-route window between the daemon and
# manual invocations (online/login commands). Concurrent add/del of the
# same route would race. mkdir is atomic; 60s stale recovery included.
route_lock() {
    local n=0 age
    while ! mkdir "$ROUTE_LOCK" 2>/dev/null; do
        age=$(( $(date +%s) - $(stat -c%Y "$ROUTE_LOCK" 2>/dev/null || echo 0) ))
        if [ "$age" -gt 60 ]; then
            rm -rf "$ROUTE_LOCK"
            continue
        fi
        n=$((n+1))
        [ $n -gt 100 ] && return 1
        sleep 1
    done
    return 0
}

route_unlock() {
    rm -rf "$ROUTE_LOCK"
}

# Query portal for the session bound to our current WAN IP.
# Prints userIndex and returns 0 when an active session for USERNAME exists.
recover_online_session() {
    local resp uid uidx rc pppoe_default
    route_lock || { log WARN "adopt check: route lock busy"; return 1; }
    pppoe_default=$(ip route show default | grep pppoe-wan | head -1)
    ip route replace default via "$GATEWAY" dev "$(_campus_dev)" 2>/dev/null
    resp=$(curl -sS --connect-timeout 5 -X POST "$PORTAL/InterFace.do?method=getOnlineUserInfo" \
        --data-urlencode "userIndex=" 2>&1)
    rc=$?
    ip route flush default 2>/dev/null
    [ -n "$pppoe_default" ] && ip route add $pppoe_default 2>/dev/null
    route_unlock
    if [ $rc -ne 0 ]; then
        log WARN "adopt check: getOnlineUserInfo curl failed (rc=$rc): $(short "$resp")"
        return 1
    fi
    if ! echo "$resp" | grep -q '"result":"success"'; then
        log INFO "adopt check: no live session ($(portal_msg "$resp"))"
        return 1
    fi
    uid=$(echo "$resp" | grep -o '"userId":"[^"]*"' | head -1 | cut -d'"' -f4)
    uidx=$(echo "$resp" | grep -o '"userIndex":"[^"]*"' | head -1 | cut -d'"' -f4)
    # When USERNAME is configured, only adopt sessions that belong to us
    if [ -n "$uidx" ] && { [ -z "$USERNAME" ] || [ "$uid" = "$USERNAME" ]; }; then
        echo "$uidx" > "$PIDFILE"
        [ -s "$UPTIME_FILE" ] || date '+%s' > "$UPTIME_FILE"
        echo "$uidx"
        return 0
    fi
    log INFO "adopt check: session belongs to '$uid', not us"
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
    rc=$?
    if [ $rc -ne 0 ] || [ -z "$resp" ]; then
        # Transport problem, not a credential rejection - treat as waiting
        set_state "waiting" "portal unreachable"
        log ERROR "portal unreachable (curl rc=$rc)"
        return 2
    fi
    user_index=$(echo "$resp" | grep -o '"userIndex":"[^"]*"' | cut -d'"' -f4)
    if [ -n "$user_index" ]; then
        echo "$user_index" > "$PIDFILE"
        date '+%s' > "$UPTIME_FILE"
        set_state "online"
        log INFO "Login OK  userIndex=${user_index}"
        return 0
    else
        msg=$(portal_msg "$resp")
        [ -z "$msg" ] && msg=$(short "$resp")
        set_state "auth_failed" "$msg"
        log ERROR "Login FAIL: $msg (raw: $(short "$resp"))"
        return 3
    fi
}

daemon_loop() {
    local idx ka msg rc backoff
    idx=""

    # Idle until credentials exist; the user may fix the config at any
    # time and the daemon picks it up without needing a restart.
    while ! config_check; do
        log ERROR "missing config, idling (fix in LuCI -> Settings)"
        sleep 60
        reload_config
    done

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
            log WARN "Keepalive FAIL: ${msg:-no message} (raw: $(short "$ka"))"
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
               tr '\0' ' ' < "/proc/$oldpid/cmdline" 2>/dev/null | grep -q "shunetwork_core"; then
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
        campus_ip=$(ip -4 addr show dev "$(_campus_dev)" 2>/dev/null | awk '/inet 10\./{print $2}' | cut -d/ -f1)
        # Check via the daemon's own pid file: pgrep -f would match the
        # caller's own shell (its command line contains the pattern too).
        if [ -s "$DPIDFILE" ]; then
            read -r dpid < "$DPIDFILE"
            if [ -n "$dpid" ] && [ -d "/proc/$dpid" ] && \
               tr '\0' ' ' < "/proc/$dpid/cmdline" 2>/dev/null | grep -q "shunetwork_core"; then
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
