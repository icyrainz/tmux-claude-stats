#!/usr/bin/env bash
# Claude Code rate limit daemon — fetches OAuth usage API and writes cache

INTERVAL="${1:-300}"
CACHE_FILE="/tmp/claude-stats.json"
CACHE_TMP="/tmp/claude-stats.json.tmp"
LOCKDIR="/tmp/claude-stats.lock"

# Acquire lock via mkdir (atomic on all platforms) or exit
if ! mkdir "$LOCKDIR" 2>/dev/null; then
    # Check if the lock holder is still alive
    lock_pid=$(cat "$LOCKDIR/pid" 2>/dev/null)
    if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
        exit 0  # another daemon is running
    fi
    # Stale lock — reclaim
    rm -rf "$LOCKDIR"
    mkdir "$LOCKDIR" 2>/dev/null || exit 0
fi
echo $$ > "$LOCKDIR/pid"

cleanup() { rm -rf "$LOCKDIR"; }
trap cleanup EXIT INT TERM

fetch_usage() {
    local creds token response now

    # macOS: keychain; Linux: flat credentials file
    if command -v security &>/dev/null; then
        creds=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null) || return 1
    elif [ -f "$HOME/.claude/.credentials.json" ]; then
        creds=$(cat "$HOME/.claude/.credentials.json" 2>/dev/null) || return 1
    else
        return 1
    fi

    token=$(printf '%s' "$creds" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
    [ -z "$token" ] && return 1

    response=$(curl -s --max-time 10 \
        -H "Authorization: Bearer $token" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "User-Agent: claude-code/2.1" \
        "https://api.anthropic.com/api/oauth/usage" 2>/dev/null) || return 1

    # Only update cache on successful API response (has five_hour field)
    printf '%s' "$response" | jq -e '.five_hour' > /dev/null 2>&1 || return 1

    now=$(date +%s)

    local new_data old_data
    new_data=$(printf '%s' "$response" | jq --argjson now "$now" '{
        five_hour: (if .five_hour.utilization then (.five_hour.utilization | round) else null end),
        five_hour_resets_at: (if .five_hour.resets_at then (.five_hour.resets_at | sub("\\.[0-9]+.*$"; "Z") | fromdateiso8601) else null end),
        seven_day: (if .seven_day.utilization then (.seven_day.utilization | round) else null end),
        seven_day_sonnet: (if .seven_day_sonnet.utilization then (.seven_day_sonnet.utilization | round) else null end),
        seven_day_opus: (if .seven_day_opus.utilization then (.seven_day_opus.utilization | round) else null end),
        seven_day_cowork: (if .seven_day_cowork.utilization then (.seven_day_cowork.utilization | round) else null end),
        updated_at: $now
    }' 2>/dev/null) || return 1

    # Merge: keep existing cache values for any fields the new fetch returned as null
    if [ -f "$CACHE_FILE" ]; then
        old_data=$(cat "$CACHE_FILE" 2>/dev/null)
        printf '%s\n%s' "$old_data" "$new_data" | jq -s '.[0] as $old | .[1] | to_entries | map(if .value == null then .key as $k | .value = $old[$k] else . end) | from_entries' > "$CACHE_TMP" 2>/dev/null && mv "$CACHE_TMP" "$CACHE_FILE"
    else
        printf '%s' "$new_data" > "$CACHE_TMP" && mv "$CACHE_TMP" "$CACHE_FILE"
    fi
}

while true; do
    fetch_usage
    sleep "$INTERVAL"
done
