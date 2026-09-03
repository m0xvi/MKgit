#!/bin/bash
# =============================================================================
# Telegram API Helper Functions (Proxy-Aware)
# =============================================================================

# --- Proxy Setup (env vars) ---
_setup_proxy_env() {
    local proxy="${TELEGRAM_PROXY:-${HTTPS_PROXY:-${HTTP_PROXY:-${ALL_PROXY:-}}}}"
    if [ -n "$proxy" ]; then
        export https_proxy="$proxy"
        export http_proxy="$proxy"
        export HTTPS_PROXY="$proxy"
        export HTTP_PROXY="$proxy"
        export ALL_PROXY="$proxy"
    fi
}
_setup_proxy_env

# --- Retry Settings ---
TG_MAX_RETRIES="${TG_MAX_RETRIES:-3}"
TG_RETRY_DELAY="${TG_RETRY_DELAY:-2}"
TG_TIMEOUT="${TG_TIMEOUT:-30}"

# --- Logging (stderr) ---
tg_api_log() {
    local level="${1:-}"; shift
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] TG_API [$level]: $*"
    echo "$msg" >&2
    echo "$msg" >> "${LOG_FILE:-/tmp/tg_api.log}"
}

# ==== CORE API CALL ====
tg_api_call() {
    local method="${1:-}" endpoint="${2:-}" data="${3:-}"
    local url="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/${endpoint}"
    local attempt=1
    local tmp_body="/tmp/tg_body_$$"
    local tmp_code="/tmp/tg_code_$$"
    local curl_opts="-s --connect-timeout $TG_TIMEOUT --max-time $((TG_TIMEOUT * 2)) --http1.1"

    while [ $attempt -le $TG_MAX_RETRIES ]; do
        case "$method" in
            GET)
                curl $curl_opts -o "$tmp_body" -w "%{http_code}" "$url" > "$tmp_code" 2>/dev/null ;;
            POST)
                curl $curl_opts -X POST \
                    -H "Content-Type: application/json" -d "$data" \
                    -o "$tmp_body" -w "%{http_code}" "$url" > "$tmp_code" 2>/dev/null ;;
            UPLOAD)
                curl $curl_opts -X POST -F "$data" \
                    -o "$tmp_body" -w "%{http_code}" "$url" > "$tmp_code" 2>/dev/null ;;
            *) tg_api_log "ERROR" "Unknown method: $method"; return 1 ;;
        esac

        local http_code
        http_code=$(tr -d '[:space:]' < "$tmp_code" 2>/dev/null)

        if [ "$http_code" = "200" ]; then
            local is_ok
            is_ok=$(jq -r '.ok // "false"' "$tmp_body" 2>/dev/null)
            if [ "$is_ok" = "true" ]; then
                cat "$tmp_body"
                rm -f "$tmp_body" "$tmp_code"
                return 0
            fi
            local err_desc
            err_desc=$(jq -r '.description // "?"' "$tmp_body" 2>/dev/null)
            tg_api_log "WARN" "API error: $err_desc (attempt $attempt)"
            [ "$err_desc" = "Unauthorized" ] && { rm -f "$tmp_body" "$tmp_code"; return 1; }
        else
            tg_api_log "WARN" "Attempt $attempt/$TG_MAX_RETRIES: HTTP $http_code"
        fi

        [ $attempt -lt $TG_MAX_RETRIES ] && sleep "$TG_RETRY_DELAY"
        ((attempt++))
    done

    rm -f "$tmp_body" "$tmp_code"
    return 1
}

# --- High-Level Wrappers ---
# FIX: printf '%b' converts \n escapes → real newlines before JSON encoding
tg_send_message() {
    local chat_id="${1:-$TELEGRAM_CHAT_ID}" text="${2:-}" pm="${3:-HTML}"
    local json_text
    json_text=$(printf '%b' "$text" | jq -Rs '.' 2>/dev/null)
    [ -z "$json_text" ] && json_text="\"$text\""
    tg_api_call "POST" "sendMessage" \
        "{\"chat_id\":\"$chat_id\",\"text\":$json_text,\"parse_mode\":\"$pm\"}" > /dev/null
}

tg_send_keyboard() {
    local chat_id="${1:-$TELEGRAM_CHAT_ID}" text="${2:-}" kb="${3:-}" pm="${4:-HTML}"
    local json_text
    json_text=$(printf '%b' "$text" | jq -Rs '.' 2>/dev/null)
    [ -z "$json_text" ] && json_text="\"$text\""
    tg_api_call "POST" "sendMessage" \
        "{\"chat_id\":\"$chat_id\",\"text\":$json_text,\"reply_markup\":{\"inline_keyboard\":$kb},\"parse_mode\":\"$pm\"}" > /dev/null
}

tg_send_document() {
    local chat_id="${1:-$TELEGRAM_CHAT_ID}" fp="${2:-}" caption="${3:-}"
    [ ! -f "$fp" ] && { tg_api_log "ERROR" "File not found: $fp"; return 1; }
    local fd="chat_id=$chat_id&document=@$fp"
    [ -n "$caption" ] && fd+="&caption=$caption"
    tg_api_call "UPLOAD" "sendDocument" "$fd" > /dev/null
}

tg_get_updates() {
    tg_api_call "GET" "getUpdates?offset=${1:-0}&timeout=${2:-60}"
}

# --- Connection Test ---
tg_test_connection() {
    tg_api_log "INFO" "========== Testing Telegram API =========="
    tg_api_log "INFO" "https_proxy=${https_proxy:-DIRECT}"
    tg_api_log "INFO" "Token: ${TELEGRAM_BOT_TOKEN:0:12}..."

    # Direct curl test
    local direct_out="/tmp/tg_direct_$$.json"
    local direct_code
    direct_code=$(curl -s --http1.1 --connect-timeout 15 --max-time 30 \
        -o "$direct_out" -w "%{http_code}" \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe" 2>/dev/null)

    if [ "$direct_code" = "200" ] && [ -s "$direct_out" ]; then
        local direct_ok bot_name
        direct_ok=$(jq -r '.ok // "false"' "$direct_out" 2>/dev/null)
        bot_name=$(jq -r '.result.username // "???"' "$direct_out" 2>/dev/null)
        if [ "$direct_ok" = "true" ]; then
            tg_api_log "INFO" "Direct curl: ✅ OK (Bot: @$bot_name)"
        else
            tg_api_log "WARN" "Direct curl: ok=false. Body: $(head -c 100 "$direct_out")"
        fi
        rm -f "$direct_out"
    else
        tg_api_log "ERROR" "Direct curl: HTTP $direct_code. Check proxy."
        rm -f "$direct_out"
        return 1
    fi

    # tg_api_call test
    tg_api_log "INFO" "--- tg_api_call test ---"
    local result
    result=$(tg_api_call "GET" "getMe")
    if [ $? -eq 0 ] && [ -n "$result" ]; then
        local bot_name
        bot_name=$(echo "$result" | jq -r '.result.username // "???"' 2>/dev/null)
        tg_api_log "INFO" "✅ ALL OK! Bot: @$bot_name"
        return 0
    fi

    tg_api_log "ERROR" "❌ FAILED"
    return 1
}

tg_api_log "INFO" "Helpers loaded. https_proxy=${https_proxy:-DIRECT}"
