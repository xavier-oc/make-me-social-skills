#!/usr/bin/env bash
# Creator Outreach - Main Orchestrator
# Reads sheet → filters uncontacted → outputs JSON for agent to generate messages
# The agent composes each message and sends via send_email.sh, then calls
# this script again with --update-row to mark the Contacted cell.
#
# Usage:
#   ./send_outreach.sh              # Output uncontacted creators as JSON
#   ./send_outreach.sh --update-row "FILE_ID" "ROW" "DATE"  # Mark row as contacted

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTREACH_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE_DIR="$(cd "$OUTREACH_DIR/../.." && pwd)"

source "$OUTREACH_DIR/scripts/sheet_helpers.sh"

# Handle --update-row mode
if [[ "${1:-}" == "--update-row" ]]; then
  FILE_ID="$2"
  ROW="$3"
  DATE="$4"
  update_cell "$FILE_ID" "$ROW" "$DATE"
  exit $?
fi

FILE_ID="1qxOzRtjTXe3LCoz4_YLgMEZoXTOYB9xOmYndDz3S_iE"

SUBJECTS=(
  "Partnership"
  "Potential Partnership"
  "Potential Collaboration"
  "Paid Partnership"
  "Content Partnership"
)

# Shuffle subjects for this run
shuffle() {
  local arr=("$@")
  local n=${#arr[@]}
  for (( i = n - 1; i > 0; i-- )); do
    local j=$(( RANDOM % (i + 1) ))
    local tmp="${arr[i]}"
    arr[i]="${arr[j]}"
    arr[j]="$tmp"
  done
  printf '%s\n' "${arr[@]}"
}

mapfile -t shuffled_subjects < <(shuffle "${SUBJECTS[@]}")

# Step 1 — Read sheet
echo "Reading spreadsheet..." >&2
SHEET_JSON=$(read_sheet "$FILE_ID")

STATUS_CODE=$(echo "$SHEET_JSON" | jq -r '.status.code // "ok"')
if [[ "$STATUS_CODE" != "ok" && "$STATUS_CODE" != "200" ]]; then
  echo "ERROR: Failed to read sheet. Response: $SHEET_JSON" >&2
  exit 1
fi

# Step 2 — Filter uncontacted (hard gate)
CREATORS=$(parse_uncontacted "$SHEET_JSON" 5)
CREATOR_COUNT=$(echo "$CREATORS" | jq '. | length')

if [[ "$CREATOR_COUNT" == "0" || "$CREATOR_COUNT" == "null" ]]; then
  echo "NO_UNCONTACTED"
  exit 0
fi

echo "Found $CREATOR_COUNT uncontacted creator(s)" >&2

# Output JSON with all data needed for agent to compose messages
# Agent will generate the email body, then call send_email.sh directly
jq -n \
  --argjson count "$CREATOR_COUNT" \
  --arg fileId "$FILE_ID" \
  --argjson subjects "$(printf '%s\n' "${shuffled_subjects[@]}" | jq -R . | jq -s .)" \
  --argjson creators "$CREATORS" \
  '{
    creatorCount: $count,
    fileId: $fileId,
    subjects: $subjects,
    creators: $creators
  }'