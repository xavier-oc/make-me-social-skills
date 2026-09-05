#!/usr/bin/env bash
# Inbox Handler - Google Calendar Helpers
# Token refresh, free/busy check, and event creation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CRED_FILE="$WORKSPACE_DIR/credentials/google_oauth.json"

CAL_BASE="https://www.googleapis.com/calendar/v3"
GOOGLE_TOKEN_URL="https://oauth2.googleapis.com/token"

get_calendar_token() {
  if [[ ! -f "$CRED_FILE" ]]; then
    echo "ERROR: credentials/google_oauth.json not found" >&2
    return 1
  fi

  local expiry
  expiry=$(jq -r '.expiry_date' "$CRED_FILE")
  local now
  now=$(date +%s)

  if [[ "$expiry" == "null" || -z "$expiry" ]] || (( now >= expiry )); then
    local refresh_tok client_id client_secret response access_token expires_in new_expiry
    refresh_tok=$(jq -r '.refresh_token' "$CRED_FILE")
    client_id=$(jq -r '.client_id' "$CRED_FILE")
    client_secret=$(jq -r '.client_secret' "$CRED_FILE")

    if [[ -z "$refresh_tok" || "$refresh_tok" == "null" ]]; then
      echo "ERROR: No refresh_token in google_oauth.json" >&2
      return 1
    fi

    # Guard: bail early if client_id/client_secret are missing. Without them
    # the refresh call will return invalid_client and silently strip these
    # fields from the credentials file on the next write.
    if [[ -z "$client_id" || "$client_id" == "null" ]] || [[ -z "$client_secret" || "$client_secret" == "null" ]]; then
      echo "ERROR: google_oauth.json is missing client_id and/or client_secret. Re-authorization required before any Google API call can succeed." >&2
      return 1
    fi

    response=$(curl -s --max-time 15 -X POST "$GOOGLE_TOKEN_URL" \
      -d "refresh_token=${refresh_tok}" \
      -d "client_id=${client_id}" \
      -d "client_secret=${client_secret}" \
      -d "grant_type=refresh_token")

    if ! curl_status=$? && [[ $curl_status -ne 0 ]]; then
      echo "ERROR: curl failed (code $curl_status) while refreshing Google token" >&2
      return 1
    fi

    access_token=$(echo "$response" | jq -r '.access_token // empty')
    expires_in=$(echo "$response" | jq -r '.expires_in // empty')


    # Guard: validate response contains a real access_token before touching the file
    if [[ -z "$access_token" || "$access_token" == "null" ]]; then
      echo "ERROR: Invalid Google token response. Raw: $response" >&2
      return 1  # Do NOT overwrite credentials file — preserve what we have
    fi

    new_expiry=$(( now + expires_in ))


    # Atomic write: temp file + rename to avoid corruption on crash/power-loss.
    # Preserve scope and token_type from the existing file — the refresh
    # response doesn't return them, and dropping them breaks downstream tools
    # that inspect the credentials (e.g. auth.sh).
    local tmp_file existing_scope existing_token_type
    tmp_file=$(mktemp)
    existing_scope=$(jq -r '.scope // ""' "$CRED_FILE")
    existing_token_type=$(jq -r '.token_type // ""' "$CRED_FILE")

    jq -n \
      --arg access_token "$access_token" \
      --arg refresh_token "$refresh_tok" \
      --argjson expiry_date "$new_expiry" \
      --arg client_id "$client_id" \
      --arg client_secret "$client_secret" \
      --arg scope "$existing_scope" \
      --arg token_type "$existing_token_type" \
      '{
        access_token: $access_token,
        refresh_token: $refresh_token,
        expiry_date: $expiry_date,
        client_id: $client_id,
        client_secret: $client_secret,
        scope: $scope,
        token_type: $token_type
      }' > "$tmp_file"

    # Verify the temp file is valid JSON before replacing
    if ! jq -e '.access_token' "$tmp_file" > /dev/null 2>&1; then
      echo "ERROR: jq produced invalid credentials file, aborting write" >&2
      rm -f "$tmp_file"
      return 1
    fi
    mv "$tmp_file" "$CRED_FILE"
  fi

  jq -r '.access_token' "$CRED_FILE"
}

# Check if a time slot is available on the calendar
# Usage: is_slot_free "2026-06-15T13:00:00Z" "2026-06-15T14:00:00Z"
# Returns 0 if free, 1 if busy, 2 on error
is_slot_free() {
  local time_min="$1"
  local time_max="$2"
  local token response calendars busy
  token="$(get_calendar_token)"

  response=$(curl -s --max-time 15 -X POST "${CAL_BASE}/freeBusy?key=" \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    -d "{
      \"timeMin\": \"${time_min}\",
      \"timeMax\": \"${time_max}\",
      \"items\": [{\"id\": \"primary\"}]
    }")

  calendars=$(echo "$response" | jq -r '.calendars // empty')
  if [[ -z "$calendars" || "$calendars" == "null" ]]; then
    echo "ERROR: freeBusy response unexpected: $response" >&2
    return 2
  fi

  busy=$(echo "$calendars" | jq -r '.primary.busy | length')
  if [[ "$busy" == "0" || "$busy" == "null" ]]; then
    return 0  # slot is free
  else
    return 1  # slot is busy
  fi
}

# Create a calendar event with Google Meet link
# Usage: create_calendar_event "2026-06-15T17:00:00Z" "2026-06-15T17:45:00Z" "Creator Name" "creator@example.com"
# Returns JSON {eventId, htmlLink} on success, exits with error on failure
create_calendar_event() {
  local time_min="$1"
  local time_max="$2"
  local creator_name="$3"
  local creator_email="$4"
  local token response error event_id html_link hangout_link
  token="$(get_calendar_token)"

  response=$(curl -s --max-time 15 -X POST "${CAL_BASE}/calendars/primary/events?conferenceDataVersion=1" \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    -d "{
      \"summary\": \"Creator Call — ${creator_name}\",
      \"description\": \"Make Me Social creator partnership call with ${creator_name} (${creator_email})\",
      \"start\": {\"dateTime\": \"${time_min}\", \"timeZone\": \"America/New_York\"},
      \"end\": {\"dateTime\": \"${time_max}\", \"timeZone\": \"America/New_York\"},
      \"conferenceData\": {
        \"createRequest\": {\"requestId\": \"mms-$(date +%s)\", \"conferenceSolutionKey\": {\"type\": \"hangoutsMeet\"}}
      },
      \"attendees\": [{\"email\": \"${creator_email}\"}],
      \"reminders\": {
        \"useDefault\": false,
        \"overrides\": [
          {\"method\": \"email\", \"minutes\": 60},
          {\"method\": \"popup\", \"minutes\": 15}
        ]
      }
    }")

  error=$(echo "$response" | jq -r '.error // empty')
  if [[ -n "$error" && "$error" != "null" && "$error" != "" ]]; then
    echo "ERROR: Failed to create calendar event: $response" >&2
    return 1
  fi

  event_id=$(echo "$response" | jq -r '.id // empty')
  html_link=$(echo "$response" | jq -r '.htmlLink // empty')
  hangout_link=$(echo "$response" | jq -r '.hangoutLink // empty')

  if [[ -z "$event_id" || "$event_id" == "null" ]]; then
    echo "ERROR: No eventId in response: $response" >&2
    return 1
  fi

  jq -n \
    --arg eventId "$event_id" \
    --arg htmlLink "$html_link" \
    --arg hangoutLink "$hangout_link" \
    '{eventId: $eventId, htmlLink: $htmlLink, hangoutLink: $hangoutLink}'
}

# Build ISO 8601 UTC timestamp for a given date + hour:minute in a named timezone.
# Usage: build_utc_times "2026-06-15" "13:00" "14:00" "America/New_York"
# Returns {timeMin, timeMax} in UTC (Z suffix).
build_utc_times() {
  local date_str="$1"
  local start_time="$2"
  local end_time="$3"
  local tz="${4:-America/New_York}"

  # Validate inputs
  if ! echo "$date_str" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
    echo "ERROR: Invalid date format: $date_str (expected YYYY-MM-DD)" >&2
    return 1
  fi
  if ! echo "$start_time" | grep -qE '^[0-9]{2}:[0-9]{2}$'; then
    echo "ERROR: Invalid start_time: $start_time (expected HH:MM)" >&2
    return 1
  fi
  if ! echo "$end_time" | grep -qE '^[0-9]{2}:[0-9]{2}$'; then
    echo "ERROR: Invalid end_time: $end_time (expected HH:MM)" >&2
    return 1
  fi

  # Use date with timezone to get proper DST-aware conversion
  local time_min time_max

  # Build local datetime in the target timezone, then convert to UTC
  local start_local="${date_str}T${start_time}:00"
  local end_local="${date_str}T${end_time}:00"

  # Get the active timezone abbreviation for this date (handles DST automatically)
  # e.g. "EDT" or "EST" for America/New_York
  local tz_abbr
  tz_abbr=$(TZ="${tz}" date -d "$date_str 12:00" '+%Z' 2>/dev/null || echo "UTC")

  # Convert to UTC using explicit TZ in input datetime (the -d flag interprets input in that TZ)
  time_min=$(TZ="${tz}" date -d "$start_local $tz_abbr" -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)
  time_max=$(TZ="${tz}" date -d "$end_local $tz_abbr" -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)

  # Fallback if datecmd fails (e.g. BSD/macOS): parse manually with offset
  if [[ -z "$time_min" || "$time_min" == *"invalid"* ]]; then
    local sh sm eh em offset ts_min ts_max
    sh=$(echo "$start_time" | cut -d: -f1)
    sm=$(echo "$start_time" | cut -d: -f2)
    eh=$(echo "$end_time" | cut -d: -f1)
    em=$(echo "$end_time" | cut -d: -f2)

    # Determine EST vs EDT offset using zonedname
    local zname
    zname=$(date +"%z")  # e.g. "-0400" for EDT, "-0500" for EST
    offset=$(echo "$zname" | sed 's/^-//; s/\(..\)\(..\)/\1*60+\2/' | xargs expr 2>/dev/null || echo 300)

    # Convert to minutes in day, add offset, wrap back
    ts_min=$(( (sh * 60 + sm + offset) % 1440 ))
    ts_max=$(( (eh * 60 + em + offset) % 1440 ))

    printf -v time_min "%sT%02d:%02d:00Z" "$date_str" $(( ts_min / 60 )) $(( ts_min % 60 ))
    printf -v time_max "%sT%02d:%02d:00Z" "$date_str" $(( ts_max / 60 )) $(( ts_max % 60 ))
  fi

  jq -n --arg tm "$time_min" --arg tx "$time_max" '{timeMin: $tm, timeMax: $tx}'
}
