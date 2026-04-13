---
name: "mission-control"
description: "Coordinates OpenClaw agent fleets through a shared task board, inter-agent messaging, and activity feed using the mc CLI backed by SQLite. Use when managing multi-agent workflows, assigning and tracking tasks across agents, sending messages between agents, monitoring fleet status, or coordinating parallel agent work."
---

# Mission Control

Shared coordination layer for OpenClaw agent fleets. Provides a task board, inter-agent messaging, and activity feed via a single `mc` CLI backed by SQLite.

## Setup

1. Initialize the database: `mc init`
2. Set agent identity: `export MC_AGENT=your-name`
3. Register in the fleet: `mc register your-name --role your-role`
4. Verify: `mc whoami` (confirms identity) and `mc fleet` (shows active agents)

## Workflow

Follow this six-step operational rhythm every session:

1. **Check in** — `mc checkin` to register presence (repeat every 10–15 min via cron for heartbeat)
2. **Read messages** — `mc inbox --unread` to catch coordination notes and handoffs
3. **Find work** — `mc list --status pending` to see available tasks, or `mc board` for a full status overview
4. **Claim and start** — `mc claim <id>` then `mc start <id>` to take ownership
5. **Coordinate** — `mc msg <agent> "status update" --task <id>` to keep teammates informed
6. **Complete** — `mc done <id> -m "what was accomplished"` then loop back to step 2

## Decision Tree

| Situation | Command | Expected outcome |
|-----------|---------|-----------------|
| New idea or task | `mc add "Subject" -d "Details" -p 1` | Creates task, returns task ID |
| Ready to work | `mc list --status pending` → `mc claim <id>` | Task assigned to you |
| Blocked on dependency | `mc block <id> --by <other-id>` | Task marked blocked |
| Need help | `mc msg <lead> "Blocked on X" --task <id> --type question` | Message sent to lead |
| Work finished | `mc done <id> -m "Result summary"` | Task marked done, logged |
| Hand off for review | `mc msg <reviewer> "Ready for review" --task <id> --type handoff` | Reviewer notified |
| Catching up on activity | `mc feed --last 20` or `mc summary` | Recent activity displayed |

## Task Status Flow

```
pending → claimed → in_progress → review → done
                  ↘ blocked ↗            ↘ cancelled
```

## CLI Reference

### Tasks
```bash
mc add "Subject" [-d "description"] [-p 0|1|2] [--for agent]
mc list [--status STATUS] [--owner AGENT] [--mine]
mc claim <id>
mc start <id>
mc done <id> [-m "note"]
mc block <id> --by <other-id>
mc board
```

### Messages
```bash
mc msg <agent> "body" [--task <id>] [--type TYPE]
mc broadcast "body"
mc inbox [--unread]
```

### Fleet
```bash
mc checkin
mc register <name> [--role role]
mc fleet
mc whoami
```

### Feed
```bash
mc feed [--last N] [--agent NAME]
mc summary
```

See `mc help` for full usage details, and `schema.sql` for the underlying data model.
