#!/usr/bin/env node
/**
 * openOwl Message Bus — codex hook adapter (REQ-009).
 *
 * Registered for codex `SessionStart` and `UserPromptSubmit` hooks. The hook
 * reads this codex agent's inbox on the message bus and prints pending
 * messages to stdout; codex appends hook stdout to the prompt as additional
 * context, so the messages arrive at the start of every new session / turn.
 *
 * Protocol (mirrors scripts/message-bus/buslib.py):
 *   inbox   ~/.openowl/bus/inboxes/<agent>.jsonl   (JSONL, one msg per line)
 *   cursor  ~/.openowl/bus/cursors/<agent>.json    {"watermark": "<id>"}
 *   unread  = messages with id > watermark, oldest first
 * After printing the block, the watermark advances to the max id injected so
 * already-delivered messages are never re-injected (idempotent).
 *
 * Token control (REQ-009 §4.2): at most 5 messages, body truncated at 2000
 * chars (+ <truncated> marker), total block capped at 8000 chars.
 *
 * Env:
 *   BUS_AGENT      agent name whose inbox to drain (default: codex)
 *   OPENOWL_BUS    bus root (default: ~/.openowl/bus)
 */
'use strict'

const fs = require('fs')
const path = require('path')
const os = require('os')

const AGENT = process.env.BUS_AGENT || 'codex'
const BUS_DIR = process.env.OPENOWL_BUS || path.join(os.homedir(), '.openowl', 'bus')
const INBOX = path.join(BUS_DIR, 'inboxes', AGENT + '.jsonl')
const CURSOR_FILE = path.join(BUS_DIR, 'cursors', AGENT + '.json')

const MAX_MSGS = 5
const MAX_BODY = 2000
const MAX_TOTAL = 8000

const HEADER =
  'Other agents sent you pending messages through the message bus. Handle each one; ' +
  'after handling, run `openowl bus-ack <id>` per handled id, and reply with `openowl bus-send <agent> "<text>"` when a reply is expected.\n'

function readStdin() {
  try {
    const raw = fs.readFileSync(0, 'utf8').trim()
    return raw ? JSON.parse(raw) : {}
  } catch {
    return {}
  }
}

function readCursor() {
  try {
    return JSON.parse(fs.readFileSync(CURSOR_FILE, 'utf8')).watermark || ''
  } catch {
    return ''
  }
}

function writeCursor(watermark) {
  try {
    fs.mkdirSync(path.dirname(CURSOR_FILE), { recursive: true })
    const tmp = CURSOR_FILE + '.tmp.' + process.pid
    fs.writeFileSync(tmp, JSON.stringify({ agent: AGENT, watermark }) + '\n', { mode: 0o600 })
    fs.renameSync(tmp, CURSOR_FILE)
  } catch (e) {
    console.error('[bus-hook] cursor write failed: ' + e.message)
  }
}

function truncate(s, max) {
  if (s.length <= max) return s
  return s.slice(0, max) + '\n<truncated>'
}

function escAttr(s) {
  return String(s).replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;')
}

function escText(s) {
  return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
}

function collectUnread() {
  if (!fs.existsSync(INBOX)) return []
  const cursor = readCursor()
  const msgs = []
  for (const line of fs.readFileSync(INBOX, 'utf8').split('\n')) {
    const t = line.trim()
    if (!t) continue
    try {
      const m = JSON.parse(t)
      if (m.id && m.id > cursor) msgs.push(m)
    } catch {
      /* skip malformed line */
    }
  }
  msgs.sort((a, b) => String(a.ts || '').localeCompare(String(b.ts || '')))
  return msgs
}

function main() {
  const event = readStdin()
  const eventName = event.hook_event_name || 'unknown'

  const unread = collectUnread()
  if (unread.length === 0) {
    console.error(`[bus-hook] ${AGENT} ${eventName}: no unread messages`)
    return
  }

  let block = HEADER
  let budget = MAX_TOTAL - block.length
  const injected = []

  for (const m of unread.slice(0, MAX_MSGS)) {
    const from = escAttr(m.from || 'unknown')
    const ts = escAttr(m.ts || '')
    const id = escAttr(m.id || '')
    const body = escText(truncate(m.body || '', MAX_BODY))
    const line = `<inbox-message from="${from}" ts="${ts}" id="${id}">${body}</inbox-message>\n`
    if (line.length > budget) break
    block += line
    budget -= line.length
    injected.push(m.id)
  }

  if (injected.length > 0) {
    process.stdout.write(block)
    writeCursor(injected.reduce((max, id) => (id > max ? id : max), readCursor()))
    console.error(`[bus-hook] ${AGENT} ${eventName}: injected ${injected.length} message(s)`)
  }
}

main()
