#!/usr/bin/env bash
# Mission Control v0.2 — Coordination layer for OpenClaw agent fleets
# Zero dependencies beyond bash + sqlite3
set -euo pipefail

DB="${MC_DB:-$HOME/.openclaw/mission-control.db}"
AGENT="${MC_AGENT:-$(whoami)}"
SCHEMA_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="${MC_LIB_DIR:-$SCHEMA_DIR/lib}"
CHANNELS_CONF="${MC_CHANNELS_CONF:-$SCHEMA_DIR/agent-channels.conf}"
HOOKS_DIR="${MC_HOOKS_DIR:-$SCHEMA_DIR/hooks/message-received}"

# Push notification settings
PUSH_ENABLED="${MC_PUSH_ENABLED:-false}"
DISCORD_BOT_TOKEN="${MC_DISCORD_BOT_TOKEN:-}"

# Load Discord API library if available
if [[ -f "$LIB_DIR/discord-api.sh" ]]; then
    source "$LIB_DIR/discord-api.sh"
fi

# Colors
R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' C='\033[0;36m' B='\033[1m' N='\033[0m'

sql() { sqlite3 -batch -separator '|' "$DB" "$1"; }
sql_col() { sqlite3 -batch -header -column "$DB" "$1"; }
log_activity() { sql "INSERT INTO activity(agent,action,target_type,target_id,detail) VALUES('$AGENT','$1','$2',$3,'$4');"; }

# Get Discord handle for an agent from channels config (backwards compatibility)
get_discord_handle() {
    local agent="$1"
    grep "^${agent}|" "$CHANNELS_CONF" 2>/dev/null | cut -d'|' -f2 || echo ""
}

# Send Discord DM to an agent using the Discord API
send_discord_dm() {
    local user_id="$1"
    local sender="$2"
    local body="$3"
    
    if [[ -z "$DISCORD_BOT_TOKEN" ]]; then
        return 1
    fi
    
    if [[ -z "$user_id" ]]; then
        return 1
    fi
    
    local formatted_msg="**$sender** sent you a message:\n\n$body"
    discord-send-dm "$user_id" "$formatted_msg" "Mission Control"
    return $?
}

# Dispatch push notifications to all configured channels
dispatch_push() {
    local to_agent="$1"
    local body="$2"
    local push_mode="${3:-hook}"  # hook, discord, both
    
    # Skip if push is disabled
    [[ "$PUSH_ENABLED" != "true" ]] && return 0
    
    # Get the user ID for this agent from config
    # Config format: agent_name|discord_user_id|description
    local user_id
    user_id=$(grep "^${to_agent}|" "$CHANNELS_CONF" 2>/dev/null | cut -d'|' -f2)
    
    [[ -z "$user_id" ]] && return 0
    
    # Export for hook scripts
    export MC_EVENT_TYPE="message_received"
    export MC_FROM_AGENT="$AGENT"
    export MC_TO_AGENT="$to_agent"
    export MC_BODY="$body"
    export MC_TIMESTAMP="$(date -Iseconds)"
    
    # Call hook scripts (async)
    if [[ -d "$HOOKS_DIR" ]]; then
        for hook in "$HOOKS_DIR"/*; do
            [[ -x "$hook" && "$hook" != *.sample ]] && "$hook" &
        done
    fi
    
    # If Discord bot token is available, send direct DM
    if [[ -n "$DISCORD_BOT_TOKEN" && "$push_mode" != "hook" ]]; then
        send_discord_dm "$user_id" "$AGENT" "$body"
    fi
}

cmd_init() {
  mkdir -p "$(dirname "$DB")"
  sqlite3 "$DB" < "$SCHEMA_DIR/schema.sql"
  sqlite3 "$DB" "PRAGMA journal_mode=WAL;"
  echo -e "${G}Initialized${N} $DB"
}

cmd_register() {
  local name="${1:?Usage: mc register <name> [--role role]}" role=""
  shift
  while [[ $# -gt 0 ]]; do case "$1" in --role) role="$2"; shift 2;; *) shift;; esac; done
  sql "INSERT OR REPLACE INTO agents(name,role,last_seen,status) VALUES('$name','$role',datetime('now'),'idle');"
  log_activity "agent_registered" "agent" 0 "$name ($role)"
  echo -e "${G}Registered${N} $name${role:+ as $role}"
}

cmd_checkin() {
  sql "INSERT OR REPLACE INTO agents(name,role,last_seen,status,session_id,registered_at)
    VALUES('$AGENT',
      COALESCE((SELECT role FROM agents WHERE name='$AGENT'),''),
      datetime('now'),
      COALESCE((SELECT CASE WHEN (SELECT COUNT(*) FROM tasks WHERE owner='$AGENT' AND status='in_progress')>0 THEN 'busy' ELSE 'idle' END),'idle'),
      COALESCE((SELECT session_id FROM agents WHERE name='$AGENT'),''),
      COALESCE((SELECT registered_at FROM agents WHERE name='$AGENT'),datetime('now')));"
  log_activity "checkin" "agent" 0 ""
  # Show unread count
  local unread
  unread=$(sql "SELECT COUNT(*) FROM messages WHERE to_agent='$AGENT' AND read_at IS NULL;")
  if [[ "$unread" -gt 0 ]]; then
    echo -e "${Y}${unread} unread messages${N} — run: mc inbox --unread"
  else
    echo -e "${G}HEARTBEAT_OK${N} ($AGENT)"
  fi
}

cmd_add() {
  local subject="" desc="" priority=0 assignee=""
  subject="${1:?Usage: mc add \"Subject\" [-d desc] [-p 0|1|2] [--for agent]}"
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d) desc="$2"; shift 2;;
      -p) priority="$2"; shift 2;;
      --for) assignee="$2"; shift 2;;
      *) shift;;
    esac
  done
  local status="pending"
  [[ -n "$assignee" ]] && status="claimed"
  local id
  id=$(sql "INSERT INTO tasks(subject,description,status,owner,created_by,priority,claimed_at)
    VALUES('$(echo "$subject" | sed "s/'/''/g")','$(echo "$desc" | sed "s/'/''/g")','$status','$assignee','$AGENT',$priority,$([ -n "$assignee" ] && echo "datetime('now')" || echo "NULL"))
    RETURNING id;")
  log_activity "task_created" "task" "$id" "$subject"
  echo -e "${G}#$id${N} $subject${assignee:+ → $assignee}"
}

cmd_list() {
  local where="1=1"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --status) where="$where AND status='$2'"; shift 2;;
      --owner) where="$where AND owner='$2'"; shift 2;;
      --mine) where="$where AND owner='$AGENT'"; shift;;
      *) shift;;
    esac
  done
  sql_col "SELECT id, subject,
    CASE status WHEN 'done' THEN '✓' WHEN 'in_progress' THEN '▶' WHEN 'claimed' THEN '◉' WHEN 'blocked' THEN '✗' WHEN 'review' THEN '⟳' ELSE '○' END || ' ' || status AS st,
    COALESCE(owner,'-') AS owner,
    CASE priority WHEN 2 THEN '!!!' WHEN 1 THEN '!' ELSE '' END AS pri
    FROM tasks WHERE $where ORDER BY priority DESC, id;"
}

cmd_claim() {
  local id="${1:?Usage: mc claim <id>}"
  local current
  current=$(sql "SELECT owner FROM tasks WHERE id=$id;")
  if [[ -n "$current" && "$current" != "$AGENT" ]]; then
    echo -e "${R}Already claimed by $current${N}"; return 1
  fi
  sql "UPDATE tasks SET owner='$AGENT', status='claimed', claimed_at=datetime('now'), updated_at=datetime('now') WHERE id=$id;"
  log_activity "task_claimed" "task" "$id" ""
  echo -e "${G}Claimed #$id${N}"
}

cmd_start() {
  local id="${1:?Usage: mc start <id>}"
  sql "UPDATE tasks SET status='in_progress', updated_at=datetime('now') WHERE id=$id AND owner='$AGENT';"
  sql "UPDATE agents SET status='busy' WHERE name='$AGENT';"
  log_activity "task_started" "task" "$id" ""
  echo -e "${C}▶ Working on #$id${N}"
}

cmd_done() {
  local id="${1:?Usage: mc done <id> [-m note]}" note=""
  shift
  while [[ $# -gt 0 ]]; do case "$1" in -m) note="$2"; shift 2;; *) shift;; esac; done
  sql "UPDATE tasks SET status='done', completed_at=datetime('now'), updated_at=datetime('now') WHERE id=$id;"
  sql "UPDATE agents SET status='idle' WHERE name='$AGENT';"
  log_activity "task_completed" "task" "$id" "$(echo "$note" | sed "s/'/''/g")"
  [[ -n "$note" ]] && sql "INSERT INTO messages(from_agent,task_id,body,msg_type) VALUES('$AGENT',$id,'$(echo "$note" | sed "s/'/''/g")','status');"
  echo -e "${G}✓ Done #$id${N}${note:+ — $note}"
}

cmd_block() {
  local id="${1:?Usage: mc block <id> --by <other-id>}" by=""
  shift
  while [[ $# -gt 0 ]]; do case "$1" in --by) by="$2"; shift 2;; *) shift;; esac; done
  [[ -z "$by" ]] && { echo "Usage: mc block <id> --by <other-id>"; return 1; }
  sql "UPDATE tasks SET status='blocked', updated_at=datetime('now'),
    blocked_by=json_insert(blocked_by, '$[#]', $by) WHERE id=$id;"
  log_activity "task_blocked" "task" "$id" "by #$by"
  echo -e "${R}✗ #$id blocked by #$by${N}"
}

cmd_board() {
  echo -e "${B}═══ MISSION CONTROL ═══${N}  $(date '+%H:%M')  agent: ${C}$AGENT${N}"
  echo ""
  for status in pending claimed in_progress review blocked done; do
    local count
    count=$(sql "SELECT COUNT(*) FROM tasks WHERE status='$status';")
    [[ "$count" -eq 0 ]] && continue
    local icon
    case $status in pending) icon="○";; claimed) icon="◉";; in_progress) icon="▶";; review) icon="⟳";; blocked) icon="✗";; done) icon="✓";; esac
    echo -e "${B}── $icon $status ($count) ──${N}"
    sql "SELECT '  #' || id || ' ' || subject || CASE WHEN owner IS NOT NULL THEN ' [' || owner || ']' ELSE '' END FROM tasks WHERE status='$status' ORDER BY priority DESC, id LIMIT 10;"
    echo ""
  done
}

cmd_msg() {
  local to="${1:?Usage: mc msg <agent> \"body\" [--task id] [--type TYPE] [--push]}" body="${2:?}" task_id="NULL" msg_type="comment" do_push="false"
  shift 2
  while [[ $# -gt 0 ]]; do
    case "$1" in --task) task_id="$2"; shift 2;; --type) msg_type="$2"; shift 2;; --push) do_push="true"; shift;; *) shift;; esac
  done
  sql "INSERT INTO messages(from_agent,to_agent,task_id,body,msg_type) VALUES('$AGENT','$to',$task_id,'$(echo "$body" | sed "s/'/''/g")','$msg_type');"
  log_activity "message_sent" "message" 0 "to:$to type:$msg_type"
  echo -e "${G}→ $to${N}: $body"
  
  # Dispatch push notification
  if [[ "$do_push" == "true" ]] || [[ "$PUSH_ENABLED" == "true" ]]; then
    dispatch_push "$to" "$body" "both"
    echo -e "${C}   [push notification sent]${N}"
  fi
}

cmd_broadcast() {
  local body="${1:?Usage: mc broadcast \"body\"}"
  sql "INSERT INTO messages(from_agent,to_agent,body,msg_type) VALUES('$AGENT',NULL,'$(echo "$body" | sed "s/'/''/g")','alert');"
  log_activity "broadcast" "message" 0 "$body"
  echo -e "${Y}📢 Broadcast:${N} $body"
}

cmd_inbox() {
  local where="(to_agent='$AGENT' OR to_agent IS NULL)"
  [[ "${1:-}" == "--unread" ]] && where="$where AND read_at IS NULL"
  sql_col "SELECT id, from_agent AS 'from', body, msg_type AS type,
    CASE WHEN read_at IS NULL THEN '●' ELSE '' END AS new,
    substr(created_at,1,16) AS at
    FROM messages WHERE $where ORDER BY created_at DESC LIMIT 20;"
  # Auto-mark as read
  sql "UPDATE messages SET read_at=datetime('now') WHERE to_agent='$AGENT' AND read_at IS NULL;"
}

cmd_fleet() {
  echo -e "${B}═══ FLEET STATUS ═══${N}"
  sql_col "SELECT name, role,
    CASE status WHEN 'busy' THEN '▶ busy' WHEN 'idle' THEN '○ idle' ELSE '✗ offline' END AS status,
    COALESCE((SELECT subject FROM tasks WHERE owner=agents.name AND status='in_progress' LIMIT 1), '-') AS working_on,
    substr(last_seen,1,16) AS last_seen
    FROM agents ORDER BY status, name;"
}

cmd_feed() {
  local limit=20 agent_filter=""
  while [[ $# -gt 0 ]]; do
    case "$1" in --last) limit="$2"; shift 2;; --agent) agent_filter="AND agent='$2'"; shift 2;; *) shift;; esac
  done
  sql_col "SELECT substr(created_at,1,16) AS at, agent, action, detail
    FROM activity WHERE 1=1 $agent_filter ORDER BY id DESC LIMIT $limit;"
}

cmd_summary() {
  echo -e "${B}═══ SUMMARY ═══${N}"
  echo ""
  echo -e "${C}Fleet:${N}"
  sql "SELECT '  ' || name || ' (' || status || ')' || CASE WHEN role != '' THEN ' — ' || role ELSE '' END FROM agents;"
  echo ""
  echo -e "${C}Open tasks:${N} $(sql 'SELECT COUNT(*) FROM tasks WHERE status NOT IN ("done","cancelled");')"
  echo -e "${C}In progress:${N} $(sql 'SELECT COUNT(*) FROM tasks WHERE status="in_progress";')"
  echo -e "${C}Blocked:${N} $(sql 'SELECT COUNT(*) FROM tasks WHERE status="blocked";')"
  echo ""
  echo -e "${C}Last 5 events:${N}"
  sql "SELECT '  [' || substr(created_at,1,16) || '] ' || agent || ': ' || action || CASE WHEN detail != '' THEN ' — ' || detail ELSE '' END FROM activity ORDER BY id DESC LIMIT 5;"
}

cmd_whoami() {
  echo -e "Agent: ${C}$AGENT${N}"
  echo -e "DB:    $DB"
  local role
  role=$(sql "SELECT role FROM agents WHERE name='$AGENT';" 2>/dev/null || echo "unregistered")
  echo -e "Role:  ${role:-unregistered}"
}

cmd_push_status() {
  echo -e "${B}═══ PUSH STATUS ═══${N}"
  echo ""
  echo -e "Push enabled:    ${C}$PUSH_ENABLED${N}"
  echo -e "Discord token:   ${C}${DISCORD_BOT_TOKEN:+set}${DISCORD_BOT_TOKEN:+ }${DISCORD_BOT_TOKEN:+$(echo "$DISCORD_BOT_TOKEN" | cut -c1-8)...}${DISCORD_BOT_TOKEN:-not set}${N}"
  echo -e "Channels conf:  ${C}$CHANNELS_CONF${N}"
  echo -e "Hooks dir:      ${C}$HOOKS_DIR${N}"
  echo ""
  echo -e "${C}Configured agents:${N}"
  if [[ -f "$CHANNELS_CONF" ]]; then
    while IFS='|' read -r agent user_id desc; do
      [[ "$agent" =~ ^# ]] && continue
      [[ -z "$agent" ]] && continue
      # Mask user ID for display
      local masked_id="${user_id:0:4}...${user_id: -4}"
      echo -e "  ${G}$agent${N} → $masked_id ($desc)"
    done < "$CHANNELS_CONF"
  else
    echo -e "  ${Y}No channels.conf found${N}"
  fi
}

cmd_help() {
  cat <<'EOF'
Mission Control v0.2 — Coordination for OpenClaw agent fleets (with direct push support)

USAGE: mc <command> [args]

TASKS:
  add "Subject" [-d desc] [-p 0|1|2] [--for agent]   Create task
  list [--status S] [--owner A] [--mine]              List tasks
  claim <id>                                           Claim a task
  start <id>                                           Begin work
  done <id> [-m "note"]                                Complete task
  block <id> --by <other-id>                           Mark blocked
  board                                                Kanban view

MESSAGES:
  msg <agent> "body" [--task id] [--type TYPE] [--push] Send message (--push for direct notification)
  broadcast "body"                                     Message all
  inbox [--unread]                                     Read messages

FLEET:
  register <name> [--role role]                        Add agent
  checkin                                              Heartbeat
  fleet                                                Show fleet
  whoami                                               Show identity

FEED:
  feed [--last N] [--agent NAME]                       Activity log
  summary                                              Fleet summary

ENV:
  MC_AGENT    Your agent name (default: $USER)
  MC_DB       Database path (default: ~/.openclaw/mission-control.db)

QUICK START:
  mc init
  mc register jarvis --role lead
  mc register researcher --role research
  mc add "Research competitors" --for researcher
  mc board
EOF
}

# Ensure DB exists for all commands except init and help
case "${1:-help}" in
  init|help|-h|--help) ;;
  *)
    if [[ ! -f "$DB" ]]; then
      echo -e "${Y}No database found. Run: mc init${N}" >&2
      exit 1
    fi
    ;;
esac

case "${1:-help}" in
  init)         cmd_init ;;
  register)     shift; cmd_register "$@" ;;
  checkin)      cmd_checkin ;;
  add)          shift; cmd_add "$@" ;;
  list)         shift; cmd_list "$@" ;;
  claim)        shift; cmd_claim "$@" ;;
  start)        shift; cmd_start "$@" ;;
  done)         shift; cmd_done "$@" ;;
  block)        shift; cmd_block "$@" ;;
  board)        cmd_board ;;
  msg)          shift; cmd_msg "$@" ;;
  broadcast)    shift; cmd_broadcast "$@" ;;
  inbox)        shift; cmd_inbox "$@" ;;
  fleet)        cmd_fleet ;;
  feed)         shift; cmd_feed "$@" ;;
  summary)      cmd_summary ;;
  whoami)       cmd_whoami ;;
  push-status)  cmd_push_status ;;
  help|-h|--help) cmd_help ;;
  *)            echo "Unknown: $1"; cmd_help ;;
esac
