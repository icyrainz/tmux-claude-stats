#!/usr/bin/env bash
# Claude Code rate limit reader — reads cache, applies template, outputs tmux format
# Args: $1 = format template, $2 = default warn threshold, $3 = default crit threshold

FORMAT="${1:-%5h\{60,90\}✦}"
DEFAULT_WARN="${2:-60}"
DEFAULT_CRIT="${3:-90}"

CACHE_FILE="/tmp/claude-stats.json"
STALE_SECONDS=1800

COLOR_WARN="#e5c07b"
COLOR_CRIT="#e06c75"
COLOR_STALE="#5c6370"

# --- Stale / missing cache ---

extract_trailing_icon() {
    # Replace %% with literal %, then strip all template variables and their optional {w,c} blocks
    # What remains after the last variable is the trailing icon
    printf '%s' "$1" | sed -E 's/%%/%/g; s/%(5r|5h|7d[soc]?|7d)(\{[0-9]+,[0-9]+\})?//g'
}

if [ ! -f "$CACHE_FILE" ]; then
    icon=$(extract_trailing_icon "$FORMAT")
    printf '#[fg=%s]--%s#[fg=default]' "$COLOR_STALE" "$icon"
    exit 0
fi

cache=$(cat "$CACHE_FILE" 2>/dev/null) || {
    icon=$(extract_trailing_icon "$FORMAT")
    printf '#[fg=%s]--%s#[fg=default]' "$COLOR_STALE" "$icon"
    exit 0
}

now=$(date +%s)
updated_at=$(printf '%s' "$cache" | jq -r '.updated_at // 0' 2>/dev/null)
age=$((now - ${updated_at:-0}))
stale=false
if [ "$age" -gt "$STALE_SECONDS" ] || [ "${updated_at:-0}" = "0" ]; then
    stale=true
fi

# --- Read all values from cache ---
# If stale, null out utilization values (shows --) but keep resets_at (absolute time)

if [ "$stale" = true ]; then
    five_hour="null"
    seven_day="null"
    seven_day_sonnet="null"
    seven_day_opus="null"
    seven_day_cowork="null"
else
    five_hour=$(printf '%s' "$cache" | jq -r '.five_hour // "null"')
    seven_day=$(printf '%s' "$cache" | jq -r '.seven_day // "null"')
    seven_day_sonnet=$(printf '%s' "$cache" | jq -r '.seven_day_sonnet // "null"')
    seven_day_opus=$(printf '%s' "$cache" | jq -r '.seven_day_opus // "null"')
    seven_day_cowork=$(printf '%s' "$cache" | jq -r '.seven_day_cowork // "null"')
fi
five_hour_resets_at=$(printf '%s' "$cache" | jq -r '.five_hour_resets_at // "null"')

get_value() {
    case "$1" in
        five_hour)        printf '%s' "$five_hour" ;;
        seven_day)        printf '%s' "$seven_day" ;;
        seven_day_sonnet) printf '%s' "$seven_day_sonnet" ;;
        seven_day_opus)   printf '%s' "$seven_day_opus" ;;
        seven_day_cowork) printf '%s' "$seven_day_cowork" ;;
    esac
}

format_value() {
    local value="$1" warn="${2:-$DEFAULT_WARN}" crit="${3:-$DEFAULT_CRIT}"

    if [ "$value" = "null" ]; then
        printf '#[fg=%s]--#[fg=default]' "$COLOR_STALE"
        return
    fi

    [ "$value" -ge 99 ] 2>/dev/null && value=99
    local formatted
    formatted=$(printf "%02d" "$value")

    if [ "$value" -ge "$crit" ]; then
        printf '#[fg=%s]%s#[fg=default]' "$COLOR_CRIT" "$formatted"
    elif [ "$value" -ge "$warn" ]; then
        printf '#[fg=%s]%s#[fg=default]' "$COLOR_WARN" "$formatted"
    else
        printf '%s' "$formatted"
    fi
}

resets_char() {
    local resets_at="$1" warn="${2:-$DEFAULT_WARN}" crit="${3:-$DEFAULT_CRIT}"
    local now char

    now=$(date +%s)

    if [ "$resets_at" = "null" ] || [ "$resets_at" -le "$now" ] 2>/dev/null; then
        printf '#[fg=%s]-#[fg=default]' "$COLOR_STALE"
        return
    fi

    local remaining=$(( resets_at - now ))
    local minutes=$(( remaining / 60 ))

    # Block phase: < 30 min, 5 min per step, evenly spaced blocks
    if [ "$minutes" -lt 5 ]; then
        char="⠀"
    elif [ "$minutes" -lt 10 ]; then
        char="▁"
    elif [ "$minutes" -lt 15 ]; then
        char="▃"
    elif [ "$minutes" -lt 20 ]; then
        char="▅"
    elif [ "$minutes" -lt 25 ]; then
        char="▇"
    elif [ "$minutes" -lt 30 ]; then
        char="█"
    # Braille phase: >= 30 min, N dots = ≤ N×30 min remaining
    elif [ "$minutes" -lt 60 ]; then
        char="⣀"
    elif [ "$minutes" -lt 90 ]; then
        char="⣄"
    elif [ "$minutes" -lt 120 ]; then
        char="⣤"
    elif [ "$minutes" -lt 150 ]; then
        char="⣦"
    elif [ "$minutes" -lt 180 ]; then
        char="⣶"
    elif [ "$minutes" -lt 210 ]; then
        char="⣷"
    else
        char="⣿"
    fi

    # Apply color based on five_hour utilization (same as %5h)
    if [ "$five_hour" != "null" ] && [ "$five_hour" -ge "$crit" ] 2>/dev/null; then
        printf '#[fg=%s]%s#[fg=default]' "$COLOR_CRIT" "$char"
    elif [ "$five_hour" != "null" ] && [ "$five_hour" -ge "$warn" ] 2>/dev/null; then
        printf '#[fg=%s]%s#[fg=default]' "$COLOR_WARN" "$char"
    else
        printf '%s' "$char"
    fi
}

# --- Template parser (longest-prefix-first) ---

output=""
i=0
len=${#FORMAT}

while [ "$i" -lt "$len" ]; do
    char="${FORMAT:$i:1}"

    if [ "$char" = "%" ]; then
        # Literal %% → %
        if [ "${FORMAT:$((i+1)):1}" = "%" ]; then
            output="${output}%"
            i=$((i + 2))
            continue
        fi

        # Longest-prefix-first matching
        matched=false
        for pattern in "7ds:seven_day_sonnet" "7do:seven_day_opus" "7dc:seven_day_cowork" "7d:seven_day" "5r:five_hour_reset" "5h:five_hour"; do
            key="${pattern%%:*}"
            field="${pattern#*:}"
            klen=${#key}

            if [ "${FORMAT:$((i+1)):$klen}" = "$key" ]; then
                pos=$((i + 1 + klen))
                warn="$DEFAULT_WARN"
                crit="$DEFAULT_CRIT"

                # Optional inline thresholds {warn,crit}
                if [ "${FORMAT:$pos:1}" = "{" ]; then
                    end=$((pos + 1))
                    while [ "$end" -lt "$len" ] && [ "${FORMAT:$end:1}" != "}" ]; do
                        end=$((end + 1))
                    done
                    thresholds="${FORMAT:$((pos+1)):$((end-pos-1))}"
                    warn="${thresholds%%,*}"
                    crit="${thresholds#*,}"
                    pos=$((end + 1))
                fi

                if [ "$field" = "five_hour_reset" ]; then
                    output="${output}$(resets_char "$five_hour_resets_at" "$DEFAULT_WARN" "$DEFAULT_CRIT")"
                else
                    value=$(get_value "$field")
                    output="${output}$(format_value "$value" "$warn" "$crit")"
                fi
                i=$pos
                matched=true
                break
            fi
        done

        if [ "$matched" = false ]; then
            output="${output}%"
            i=$((i + 1))
        fi
    else
        output="${output}${char}"
        i=$((i + 1))
    fi
done

printf '%s' "$output"
