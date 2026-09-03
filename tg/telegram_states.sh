#!/bin/bash
# =============================================================================
# Telegram Bot User State Management
# =============================================================================
# Manages interactive sessions for multi-step operations (e.g., adding devices)

declare -A USER_STATES
declare -A USER_DATA

# Optional: persist states to disk so they survive bot restarts
STATE_DIR="${STATE_DIR:-/tmp/telegram_bot_states}"
mkdir -p "$STATE_DIR"

set_user_state() {
    local user_id="$1"
    local state="$2"
    USER_STATES["$user_id"]="$state"
    echo "$state" > "$STATE_DIR/user_${user_id}_state"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] User $user_id state: $state" >> "${LOG_FILE:-/tmp/bot_states.log}"
}

get_user_state() {
    local user_id="$1"
    # Check memory first, fall back to disk
    if [ -n "${USER_STATES[$user_id]}" ]; then
        echo "${USER_STATES[$user_id]}"
    elif [ -f "$STATE_DIR/user_${user_id}_state" ]; then
        USER_STATES["$user_id"]=$(cat "$STATE_DIR/user_${user_id}_state")
        echo "${USER_STATES[$user_id]}"
    else
        echo ""
    fi
}

clear_user_state() {
    local user_id="$1"
    unset USER_STATES["$user_id"]
    unset USER_DATA["${user_id}_device_name"]
    unset USER_DATA["${user_id}_device_ip"]
    unset USER_DATA["${user_id}_device_port"]
    unset USER_DATA["${user_id}_device_user"]
    unset USER_DATA["${user_id}_device_description"]
    rm -f "$STATE_DIR/user_${user_id}_state" "$STATE_DIR/user_${user_id}_data"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] User $user_id state cleared" >> "${LOG_FILE:-/tmp/bot_states.log}"
}

set_user_data() {
    local user_id="$1"
    local key="$2"
    local value="$3"
    USER_DATA["${user_id}_${key}"]="$value"
    # Persist to disk
    echo "${key}=${value}" >> "$STATE_DIR/user_${user_id}_data"
}

get_user_data() {
    local user_id="$1"
    local key="$2"
    if [ -n "${USER_DATA[${user_id}_${key}]}" ]; then
        echo "${USER_DATA[${user_id}_${key}]}"
    else
        echo ""
    fi
}

# Clean up stale states older than 1 hour
cleanup_stale_states() {
    find "$STATE_DIR" -type f -mmin +60 -delete 2>/dev/null
}

