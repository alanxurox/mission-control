#!/usr/bin/env bash
# Discord API helper functions for Mission Control
# Requires: MC_DISCORD_BOT_TOKEN

DISCORD_API="https://discord.com/api/v10"

# Get Discord user ID from @mention handle
# The handle format is @Username (without the @)
get_user-id() {
    local handle="${1#@}"
    # Try to resolve the user by searching guild members
    # This requires the bot to be in a shared guild with the user
    curl -s -H "Authorization: Bot $MC_DISCORD_BOT_TOKEN" \
        "${DISCORD_API}/users/@me" 2>/dev/null || echo ""
}

# Send a DM to a Discord user by their user ID
discord-send-dm() {
    local user_id="$1"
    local message="$2"
    local username="${3:-Mission Control}"
    
    # Create DM channel
    local dm_channel
    dm_channel=$(curl -s -X POST \
        -H "Authorization: Bot $MC_DISCORD_BOT_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"recipient_id\": \"$user_id\"}" \
        "${DISCORD_API}/users/@me/channels" 2>/dev/null)
    
    local channel_id
    channel_id=$(echo "$dm_channel" | grep -o '"id":"[^"]*' | head -1 | cut -d'"' -f4)
    
    if [[ -z "$channel_id" ]] || [[ "$channel_id" == "null" ]]; then
        echo "[ERROR] Failed to create DM channel for user $user_id" >&2
        return 1
    fi
    
    # Send message to DM channel
    local result
    result=$(curl -s -X POST \
        -H "Authorization: Bot $MC_DISCORD_BOT_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$(printf '{"content": "%s", "username": "%s"}' "$message" "$username")" \
        "${DISCORD_API}/channels/$channel_id/messages" 2>/dev/null)
    
    local msg_id
    msg_id=$(echo "$result" | grep -o '"id":"[^"]*' | head -1 | cut -d'"' -f4)
    
    if [[ -n "$msg_id" ]] && [[ "$msg_id" != "null" ]]; then
        echo "[OK] Message sent to user $user_id"
        return 0
    else
        echo "[ERROR] Failed to send message: $result" >&2
        return 1
    fi
}

# Send a message to a Discord channel by ID
discord-send-channel() {
    local channel_id="$1"
    local message="$2"
    local username="${3:-Mission Control}"
    
    curl -s -X POST \
        -H "Authorization: Bot $MC_DISCORD_BOT_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$(printf '{"content": "%s", "username": "%s"}' "$message" "$username")" \
        "${DISCORD_API}/channels/$channel_id/messages" > /dev/null 2>&1
    
    return $?
}

# Test if bot token is valid
discord-test-token() {
    local response
    response=$(curl -s -w "\n%{http_code}" \
        -H "Authorization: Bot $MC_DISCORD_BOT_TOKEN" \
        "${DISCORD_API}/users/@me")
    
    local http_code
    http_code=$(echo "$response" | tail -1)
    
    if [[ "$http_code" == "200" ]]; then
        local username
        username=$(echo "$response" | grep -o '"username":"[^"]*' | cut -d'"' -f4)
        echo "[OK] Bot authenticated as: $username"
        return 0
    else
        echo "[ERROR] Invalid token (HTTP $http_code)" >&2
        return 1
    fi
}
