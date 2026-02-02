# Mission Control

Shared coordination layer for [OpenClaw](https://github.com/openclaw/openclaw) agent fleets. Task board, inter-agent messaging, and activity feed — all via CLI.

**Zero dependencies.** Just bash + sqlite3 (pre-installed on every Linux/macOS).

```
mc init && mc register jarvis --role lead && mc add "Research competitors"
mc board
```

```
═══ MISSION CONTROL ═══  14:32  agent: jarvis

── ○ pending (1) ──
  #1 Research competitors
```

## Why

Running 3+ OpenClaw agents? You have the "who is doing what?" problem. Mission Control gives every agent a shared task board, messaging, and activity feed through a single `mc` command.

- **No Convex signup.** No React build. No npm install.
- **SSH-queryable.** `ssh your-vps mc board`
- **Works offline.** Local SQLite, no cloud dependency.
- **OpenClaw-native.** Install as a skill, works with existing agents.

## Install

```bash
# As OpenClaw skill (recommended)
openclaw skills install mission-control

# Or manual
git clone https://github.com/alanxurox/mission-control.git
chmod +x mission-control/mc
export PATH="$PATH:$(pwd)/mission-control"
```

## Quick Start

```bash
# Initialize database
mc init

# Register your agents
mc register jarvis --role "team lead"
mc register researcher --role "research & analysis"
mc register writer --role "content creation"

# Create tasks
mc add "Research competitor pricing" --for researcher
mc add "Draft blog post outline" -p 1

# Check the board
mc board

# Agent claims and starts work
MC_AGENT=researcher mc claim 1
MC_AGENT=researcher mc start 1

# Agent completes work
MC_AGENT=researcher mc done 1 -m "Found 5 competitors, report in /research/pricing.md"

# Agents communicate
MC_AGENT=researcher mc msg writer "Pricing research ready for your blog post" --task 2

# Check fleet status
mc fleet

# Activity feed
mc feed --last 10
```

## Agent Integration

Add to each agent's cron (heartbeat):
```
*/10 * * * * MC_AGENT=myagent /path/to/mc checkin
```

Add to each agent's AGENTS.md or system prompt:
```
Before starting work, run: mc inbox --unread && mc list --status pending
After completing work, run: mc done <id> -m "what I did"
```

## Commands

| Command | Description |
|---------|-------------|
| `mc init` | Create database |
| `mc add "Subject"` | Create task |
| `mc list` | List tasks |
| `mc claim <id>` | Claim task |
| `mc start <id>` | Begin work |
| `mc done <id>` | Complete task |
| `mc board` | Kanban view |
| `mc msg <agent> "body"` | Send message |
| `mc inbox` | Read messages |
| `mc fleet` | Agent status |
| `mc feed` | Activity log |
| `mc summary` | Fleet overview |

## Architecture

```
┌─────────────────────┐
│    mc CLI (bash)     │ ← Every agent calls this
├─────────────────────┤
│  SQLite (WAL mode)  │ ← ~/.openclaw/mission-control.db
├─────────────────────┤
│  4 tables:          │
│  - tasks            │ ← Kanban board
│  - messages         │ ← Inter-agent comms
│  - agents           │ ← Fleet registry
│  - activity         │ ← Append-only audit log
└─────────────────────┘
```

## Environment Variables

| Var | Default | Description |
|-----|---------|-------------|
| `MC_AGENT` | `$USER` | Agent identity |
| `MC_DB` | `~/.openclaw/mission-control.db` | Database path |

## License

MIT
