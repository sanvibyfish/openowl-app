#!/usr/bin/env python3
"""openOwl Message Bus — shared protocol helpers.

Bus layout (~/.openowl/bus/):
  agents.json            registry: name -> {kind, sessionId?, paneId?, cwd, heartbeat, caps}
  inboxes/{agent}.jsonl  per-agent message queue (append + flock)
  cursors/{agent}.json   read-watermark: highest processed message id
  locks/                 flock lock files

Message (one JSON per line):
  {"id","from","to","ts","kind","body","replyTo","meta"}

Conventions (REQ-009):
  - write: flock on locks/{agent}.lock while appending
  - read:  only messages with id > watermark (cursor), then advance cursor
  - v1: single-machine trust, no auth
"""
import fcntl
import json
import os
import sys
import time
import uuid

HOME = os.path.expanduser("~")
BUS_DIR = os.environ.get("OPENOWL_BUS", os.path.join(HOME, ".openowl", "bus"))
INBOX_DIR = os.path.join(BUS_DIR, "inboxes")
CURSOR_DIR = os.path.join(BUS_DIR, "cursors")
LOCK_DIR = os.path.join(BUS_DIR, "locks")
REGISTRY = os.path.join(BUS_DIR, "agents.json")

KINDS = {"message", "task", "reply"}
MAX_BODY = 2000          # chars; longer bodies are truncated at INJECT time, not at send
MAX_INJECT_MSGS = 5      # per injection batch
MAX_INJECT_BYTES = 8000  # total injected block budget

# Message ids must be globally unique AND strictly time-ordered, because the
# per-agent read watermark is max(id) by string comparison. Random suffixes
# break ordering for messages sent in the same microsecond, silently dropping
# the lexicographically-smaller one. Composition: microseconds + pid + an
# in-process counter. Same-process same-microsecond: counter guarantees order.
# Cross-process same-microsecond: pid disambiguates (concurrent sends have no
# meaningful order anyway). Fixed width keeps string ordering == time ordering.
import itertools as _itertools
_ID_SEQ = _itertools.count()


def _new_id():
    micros = time.strftime("%Y%m%d%H%M%S%f", time.gmtime())
    return f"{micros}{(os.getpid() & 0xFFFF):04x}{next(_ID_SEQ) & 0xFFFF:04x}"


def ensure_bus():
    for d in (BUS_DIR, INBOX_DIR, CURSOR_DIR, LOCK_DIR):
        os.makedirs(d, exist_ok=True)
    if not os.path.exists(REGISTRY):
        _atomic_write(REGISTRY, json.dumps({"agents": {}}, indent=2) + "\n")


def _atomic_write(path, content):
    tmp = path + ".tmp." + str(os.getpid())
    with open(tmp, "w") as f:
        f.write(content)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def lock_for(agent):
    return os.path.join(LOCK_DIR, agent + ".lock")


def send(agent, body, sender="cli", kind="message", reply_to=None, meta=None):
    ensure_bus()
    msg = {
        "id": _new_id(),
        "from": sender,
        "to": agent,
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "kind": kind if kind in KINDS else "message",
        "body": body,
        "replyTo": reply_to,
        "meta": meta or {},
    }
    path = os.path.join(INBOX_DIR, agent + ".jsonl")
    with open(lock_for(agent), "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        with open(path, "a") as f:
            f.write(json.dumps(msg, ensure_ascii=False) + "\n")
        fcntl.flock(lock, fcntl.LOCK_UN)
    _touch_heartbeat(sender, agent)
    return msg["id"]


def _touch_heartbeat(sender, target):
    """Best-effort registry heartbeat for the sender agent."""
    try:
        ensure_bus()
        reg = json.load(open(REGISTRY))
        agents = reg.setdefault("agents", {})
        if sender in agents:
            agents[sender]["heartbeat"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        _atomic_write(REGISTRY, json.dumps(reg, indent=2, ensure_ascii=False) + "\n")
    except Exception:
        pass


def unread(agent, limit=MAX_INJECT_MSGS):
    """Return unread messages for agent, oldest first, capped."""
    ensure_bus()
    cursor = _read_cursor(agent)
    path = os.path.join(INBOX_DIR, agent + ".jsonl")
    msgs = []
    try:
        with open(lock_for(agent), "w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            with open(path) as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        m = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if m.get("id") and m["id"] > cursor:
                        msgs.append(m)
            fcntl.flock(lock, fcntl.LOCK_UN)
    except FileNotFoundError:
        return []
    msgs.sort(key=lambda m: m.get("ts", ""))
    return msgs[:limit]


def advance_cursor(agent, msg_ids):
    """Mark ids as read. Watermark = max id processed."""
    if not msg_ids:
        return
    cursor = _read_cursor(agent)
    new_cursor = max([cursor] + [i for i in msg_ids if i])
    _write_cursor(agent, new_cursor)


def _read_cursor(agent):
    path = os.path.join(CURSOR_DIR, agent + ".json")
    try:
        return json.load(open(path)).get("watermark", "")
    except Exception:
        return ""


def ack_by_id(message_id):
    """Advance the owning agent's watermark to cover `message_id`.

    Agents are told to run `bus-ack <id>` after handling a message; this
    locates which inbox holds the id and raises that agent's cursor to
    max(cursor, id). Safe for out-of-order acks: only already-handled ids are
    ever acked, and any unacked newer id stays above the cursor.
    Returns the agent name, or None if the id was not found.
    """
    if not message_id:
        return None
    ensure_bus()
    try:
        inbox_files = sorted(os.listdir(INBOX_DIR))
    except FileNotFoundError:
        return None
    for fname in inbox_files:
        if not fname.endswith(".jsonl"):
            continue
        agent = fname[: -len(".jsonl")]
        path = os.path.join(INBOX_DIR, fname)
        with open(lock_for(agent), "w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            found = False
            try:
                with open(path) as f:
                    for line in f:
                        line = line.strip()
                        if not line:
                            continue
                        try:
                            if json.loads(line).get("id") == message_id:
                                found = True
                                break
                        except json.JSONDecodeError:
                            continue
            except FileNotFoundError:
                pass
            if found:
                cursor = _read_cursor(agent)
                if message_id > cursor:
                    _write_cursor(agent, message_id)
                fcntl.flock(lock, fcntl.LOCK_UN)
                return agent
            fcntl.flock(lock, fcntl.LOCK_UN)
    return None


def _write_cursor(agent, watermark):
    _atomic_write(os.path.join(CURSOR_DIR, agent + ".json"),
                  json.dumps({"agent": agent, "watermark": watermark}) + "\n")


def register(name, kind, cwd=None, session_id=None, pane_id=None):
    ensure_bus()
    reg = json.load(open(REGISTRY))
    agents = reg.setdefault("agents", {})
    entry = agents.setdefault(name, {})
    entry["kind"] = kind
    entry["cwd"] = cwd or entry.get("cwd")
    if session_id:
        entry["sessionId"] = session_id
    if pane_id:
        entry["paneId"] = pane_id
    entry["heartbeat"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    _atomic_write(REGISTRY, json.dumps(reg, indent=2, ensure_ascii=False) + "\n")
    return name


def list_agents(online_only=False):
    ensure_bus()
    reg = json.load(open(REGISTRY))
    agents = reg.get("agents", {})
    now = time.time()
    out = {}
    for name, info in agents.items():
        hb = info.get("heartbeat")
        age = None
        if hb:
            try:
                age = now - time.mktime(time.strptime(hb, "%Y-%m-%dT%H:%M:%SZ"))
            except Exception:
                age = None
        if online_only and (age is None or age > 300):
            continue
        out[name] = {**info, "heartbeatAgeSec": age}
    return out
