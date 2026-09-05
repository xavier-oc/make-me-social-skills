#!/usr/bin/env bash
# Inbox Handler - Main Triage Orchestrator
# Fetches unread emails → triages → mark-read → send replies → book calls → report

set -euo pipefail

MY_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MY_SKILL_DIR="$(cd "$MY_SCRIPT_DIR/.." && pwd)"
MY_WORKSPACE_DIR="$(cd "$MY_SKILL_DIR/../.." && pwd)"

source "$MY_WORKSPACE_DIR/scripts/zoho/auth.sh"
source "$MY_SCRIPT_DIR/calendar_helpers.sh"

# Restore (auth.sh overwrites SCRIPT_DIR)
SCRIPT_DIR="$MY_SCRIPT_DIR"
SKILL_DIR="$MY_SKILL_DIR"
WORKSPACE_DIR="$MY_WORKSPACE_DIR"

# --- Constants ---
readonly CURL_TIMEOUT=15      # seconds per HTTP request
readonly MAX_RETRIES=2        # retry transient failures
readonly RETRY_DELAY=3         # seconds between retries
readonly QUEUE_FILE="/tmp/inbox_handler_queue_$$.json"

# Manual-only addresses — skip (leave unread, no action)
MANUAL_ONLY=(
  "collabs@slogansocial.com"
  "jeremysarter@gmail.com"
  "sacredmotionn@gmail.com"
  "riyahvofficial@gmail.com"
  "katygarciacoaching@gmail.com"
  "edenbraquel@gmail.com"
  "admin@glosskit.co"
  "ellabrthomas@gmail.com"
)

is_manual_only() {
  local addr="$1"
  for m in "${MANUAL_ONLY[@]}"; do
    [[ "${addr,,}" == "${m,,}" ]] && return 0
  done
  return 1
}

# Retry wrapper for curl calls
# Usage: retry_curl "curl args..."
retry_curl() {
  local max_attempts=$MAX_RETRIES
  local attempt=0
  while (( attempt < max_attempts )); do
    local result
    result=$(curl -s --max-time "$CURL_TIMEOUT" "$@" 2>&1)
    local curl_status=$?
    if (( curl_status == 0 )); then
      echo "$result"
      return 0
    fi
    # Transient errors: timeout (28), connection reset (56), SSL issues (35/60)
    if (( curl_status == 28 || curl_status == 56 || curl_status == 35 || curl_status == 60 )); then
      attempt=$(( attempt + 1 ))
      if (( attempt < max_attempts )); then
        echo "Retry $attempt/$max_attempts after ${RETRY_DELAY}s..." >&2
        sleep "$RETRY_DELAY"
      else
        echo "ERROR: curl failed after $max_attempts attempts: $result" >&2
        echo "$result"
        return 1
      fi
    else
      echo "ERROR: curl failed (code $curl_status): $result" >&2
      echo "$result"
      return 1
    fi
  done
}

# Step 1 — Clean up any stale queue from prior runs, then set up fresh queue
rm -f "/tmp/inbox_handler_queue_"*.json 2>/dev/null || true
# Touch empty queue file; entries are appended one per line (NDJSON)
> "$QUEUE_FILE"

# Step 2 — Fetch unread messages
echo "Fetching unread messages..." >&2
# Scan ALL folders for unread — Zoho puts reply threads in the folder of
# the original sent message, so creator replies to outreach emails land in
# Sent, not Inbox. get_unread_emails.sh defaults to all folders.
UNREAD_OUTPUT=$(bash "$WORKSPACE_DIR/scripts/zoho/get_unread_emails.sh" --limit 50 2>&1)
UNREAD_JSON=$(echo "$UNREAD_OUTPUT" | sed -n '/^\[/,$p')  # strip header lines above JSON

# Guard: detect non-JSON responses (auth failures, API errors, etc.)
if ! echo "$UNREAD_JSON" | jq -e '. | type == "array"' > /dev/null 2>&1; then
  echo "ERROR: Failed to fetch unread messages. Response: $UNREAD_JSON" >&2
  echo "ABORT: Could not parse inbox response. Check credentials and API access." >&2
  exit 1
fi

MSG_COUNT=$(echo "$UNREAD_JSON" | jq '. | length')
if [[ "$MSG_COUNT" == "0" || "$MSG_COUNT" == "null" ]]; then
  echo "NO_UNREAD"
  rm -f "$QUEUE_FILE"
  exit 0
fi
echo "Found $MSG_COUNT unread message(s)" >&2

# Step 2 — Load instructions (already in memory from skill context, but verify file exists)
if [[ ! -f "$SKILL_DIR/instructions.md" ]]; then
  echo "ERROR: instructions.md not found at $SKILL_DIR/instructions.md" >&2
  exit 1
fi

RESULTS_JSON="[]"
PROCESSED=0
SKIPPED=0
MANUAL=0

while IFS= read -r msg; do
  msg_id=$(echo "$msg" | jq -r '.messageId // empty')
  subject=$(echo "$msg" | jq -r '.subject // empty')
  from=$(echo "$msg" | jq -r '.from // empty')
  sender=$(echo "$msg" | jq -r '.sender // empty')
  thread_id=$(echo "$msg" | jq -r '.threadId // empty')
  folder_id=$(echo "$msg" | jq -r '.folderId // empty')

  # Guard against malformed message objects
  if [[ -z "$msg_id" || "$msg_id" == "null" ]]; then
    echo "WARN: Skipping malformed message (no messageId): $msg" >&2
    continue
  fi

  echo "Processing: $subject from $from (ID: $msg_id)" >&2

  # Manual-only check
  if is_manual_only "$from"; then
    echo "SKIP (manual-only): $from" >&2
    MANUAL=$((MANUAL + 1))
    continue
  fi

  # Safety guard: skip messages from Xavier (replying to own emails = noise)
  if [[ "${from,,}" == *"xavier@makemesocialapp.com"* ]]; then
    echo "SKIP (from Xavier — no action needed): $from" >&2
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Fetch full content (with retry)
  token=$(get_access_token)
  CONTENT_JSON=$(retry_curl -X GET \
    "${ZOHO_MAIL_API}/accounts/${ZOHO_ACCOUNT_ID}/folders/${folder_id}/messages/${msg_id}/content?includeBlockContent=true" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    -H "Authorization: Zoho-oauthtoken ${token}")

  if ! echo "$CONTENT_JSON" | jq -e '.data.content' > /dev/null 2>&1; then
    echo "WARN: Could not fetch content for $msg_id — skipping message" >&2
    continue
  fi
  content=$(echo "$CONTENT_JSON" | jq -r '.data.content // empty')

  # Prompt injection detection — flag suspicious content
  # v2 (2026-07-21): tightened to reduce creator-side false positives.
  #   - "forward" only matches as an imperative at the start of a line/paragraph
  #     (catches "forward this to me", misses "looking forward to hearing from you")
  #   - "send" / "reveal" only fire when a real credential word appears within
  #     80 chars (catches "send me the API key", misses "send me some key deliverables")
  #   - "key" alone removed from alternations — too ambiguous in normal English
  #   - "act as" wrapped in word boundaries to avoid partial matches
  is_suspicious=false
  if echo "$content" | grep -qiE '(ignore (previous|all|prior|above) (instructions|prompts|rules)|you are now|\bact as\b|new instructions|system prompt|reveal[^<>]{0,80}(credential|api[ _-]?key|password|\bsecret\b|\btoken\b)|^\s*forward\s+(this|that|it|to[ ]+me|to[ ]+them|to[ ]+us)\b|send[^<>]{0,80}(credential|api[ _-]?key|password|\bsecret\b|\btoken\b)|change your (role|behavior|persona)|pretend you are|jailbreak|override|bypass)'; then
    echo "SUSPICIOUS: Email from $from contains potential injection pattern" >&2
    is_suspicious=true
  fi

  # Step 4 — Mark as read FIRST (idempotency) — non-fatal on failure
  mark_result=$(bash "$WORKSPACE_DIR/scripts/zoho/mark_as_read.sh" \
    --message-ids "$msg_id" 2>&1)

  if echo "$mark_result" | grep -q "marked as read successfully"; then
    echo "Marked as read: $msg_id" >&2
  else
    echo "WARN: Failed to mark as read (continuing): $mark_result" >&2
  fi

  # Write entry to queue file directly
  # Stream the potentially large HTML body via stdin instead of --arg; large
  # newsletter bodies can exceed the OS command-line argument-size limit.
  printf '%s' "$content" | jq -n --rawfile content /dev/stdin \
    --arg id "$msg_id" \
    --arg subject "$subject" \
    --arg from "$from" \
    --arg sender "$sender" \
    --arg threadId "${thread_id:-null}" \
    --arg folderId "$folder_id" \
    --argjson suspicious "$is_suspicious" \
    '{
      messageId: $id,
      subject: $subject,
      from: $from,
      sender: $sender,
      content: $content,
      threadId: $threadId,
      folderId: $folderId,
      needsReply: (if $suspicious then false else true end),
      suspicious: $suspicious,
      caseType: null
    }' >> "$QUEUE_FILE"

  PROCESSED=$((PROCESSED + 1))
done <<< "$(echo "$UNREAD_JSON" | jq -c '.[]')"

# Output summary for agent to continue processing
if [[ -s "$QUEUE_FILE" ]]; then
  entries=$(jq -s '.' "$QUEUE_FILE" 2>/dev/null || echo "[]")
else
  entries="[]"
fi

jq -n \
  --argjson processed "$PROCESSED" \
  --argjson skipped "$SKIPPED" \
  --argjson manual "$MANUAL" \
  --argjson total "$MSG_COUNT" \
  --arg queueFile "$QUEUE_FILE" \
  --argjson entries "$entries" \
  '{
    total: $total,
    processed: $processed,
    skipped: $skipped,
    manual: $manual,
    queueFile: $queueFile,
    entries: $entries
  }'
