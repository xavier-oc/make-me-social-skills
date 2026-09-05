#!/usr/bin/env bash
# Creator Outreach - Sheet Helpers
# Token refresh and Google Sheets API helpers.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CRED_FILE="$WORKSPACE_DIR/credentials/google_oauth.json"

SHEETS_BASE="https://sheets.googleapis.com/v4/spreadsheets"
DRIVE_BASE="https://www.googleapis.com/drive/v3"
GOOGLE_TOKEN_URL="https://oauth2.googleapis.com/token"

get_sheets_token() {
  if [[ ! -f "$CRED_FILE" ]]; then
    echo "ERROR: credentials/google_oauth.json not found" >&2
    return 1
  fi

  local expiry
  expiry=$(jq -r '.expiry_date' "$CRED_FILE")
  local now
  now=$(date +%s)

  # Refresh if expired, missing, OR expiry is in the past by more than 5 minutes.
  # The 5-minute window guards against clock skew between this host and Google,
  # which is what produced HTTP 401 with expiry still nominally in the future.
  local skew_tolerance=300
  if [[ "$expiry" == "null" || -z "$expiry" ]] || (( now >= expiry - skew_tolerance )); then
    local refresh_token
    refresh_token=$(jq -r '.refresh_token' "$CRED_FILE")
    if [[ -z "$refresh_token" || "$refresh_token" == "null" ]]; then
      echo "ERROR: No refresh_token in google_oauth.json" >&2
      return 1
    fi

    local client_id client_secret
    client_id=$(jq -r '.client_id' "$CRED_FILE")
    client_secret=$(jq -r '.client_secret' "$CRED_FILE")

    # Guard: bail early if client_id/client_secret are missing. Without them
    # the refresh call will return invalid_client and silently strip these
    # fields from the credentials file on the next write.
    if [[ -z "$client_id" || "$client_id" == "null" ]] || [[ -z "$client_secret" || "$client_secret" == "null" ]]; then
      echo "ERROR: google_oauth.json is missing client_id and/or client_secret. Re-authorization required before any Google API call can succeed." >&2
      return 1
    fi

    local response
    response=$(curl -s --max-time 15 -X POST "$GOOGLE_TOKEN_URL" \
      -d "refresh_token=${refresh_token}" \
      -d "client_id=${client_id}" \
      -d "client_secret=${client_secret}" \
      -d "grant_type=refresh_token")


    if ! curl_status=$? && [[ $curl_status -ne 0 ]]; then
      echo "ERROR: curl failed (code $curl_status) while refreshing Google token" >&2
      return 1
    fi

    local access_token expires_in
    access_token=$(echo "$response" | jq -r '.access_token // empty')
    expires_in=$(echo "$response" | jq -r '.expires_in // empty')

    # Guard: validate response before touching the file
    if [[ -z "$access_token" || "$access_token" == "null" ]]; then
      echo "ERROR: Invalid Google token response. Raw: $response" >&2
      return 1  # Do NOT overwrite credentials file
    fi

    local new_expiry=$(( now + expires_in ))
    local tmp_file
    tmp_file=$(mktemp)

    # Preserve scope and token_type from the existing file — the refresh
    # response doesn't return them, and dropping them breaks downstream tools
    # that inspect the credentials (e.g. auth.sh).
    local existing_scope existing_token_type
    existing_scope=$(jq -r '.scope // ""' "$CRED_FILE")
    existing_token_type=$(jq -r '.token_type // ""' "$CRED_FILE")

    jq -n \
      --arg access_token "$access_token" \
      --arg refresh_token "$refresh_token" \
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

# Force a token refresh regardless of stored expiry, by temporarily clearing
# the cached access_token from the credentials file. Backs up the original
# and restores it if the refresh fails — so we never lose credentials if
# Google returns a bad response.
force_refresh_token() {
  if [[ ! -f "$CRED_FILE" ]]; then
    echo "ERROR: credentials/google_oauth.json not found" >&2
    return 1
  fi

  local backup
  backup=$(mktemp)
  cp "$CRED_FILE" "$backup"

  # Clear cached access_token + expiry so get_sheets_token sees a stale
  # credential and runs the full refresh branch.
  local tmp
  tmp=$(mktemp)
  jq 'del(.access_token) | .expiry_date = 0' "$CRED_FILE" > "$tmp" && mv "$tmp" "$CRED_FILE"

  local new_token
  if ! new_token="$(get_sheets_token)"; then
    # Refresh failed — restore original credentials file so we don't lock
    # ourselves out of further retries.
    mv "$backup" "$CRED_FILE"
    echo "ERROR: force_refresh_token failed; credentials restored" >&2
    return 1
  fi

  rm -f "$backup"
  echo "$new_token"
}

# Read sheet, with one automatic retry on HTTP 401. The retry clears the
# cached token via force_refresh_token, so it actually goes through the
# refresh branch instead of returning the same stale token.
read_sheet() {
  local file_id="$1"
  local token
  token="$(get_sheets_token)"

  local response http_code
  response=$(curl -s --max-time 15 -o - -w "\n%{http_code}" -X GET "${SHEETS_BASE}/${file_id}/values/Sheet1" \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/json")
  http_code=$(echo "$response" | tail -n1)
  response=$(echo "$response" | sed '$d')

  if [[ "$http_code" == "401" ]]; then
    echo "WARN: read_sheet got HTTP 401, forcing token refresh and retrying once" >&2
    token="$(force_refresh_token)" || return 1
    response=$(curl -s --max-time 15 -X GET "${SHEETS_BASE}/${file_id}/values/Sheet1" \
      -H "Authorization: Bearer ${token}" \
      -H "Accept: application/json")
  fi

  echo "$response"
}

# Update a single cell using values:batchUpdate (as documented in SKILL.md)
# Usage: update_cell "FILE_ID" "ROW" "VALUE"
# Returns: JSON response or error message
update_cell() {
  local file_id="$1"
  local row="$2"
  local value="$3"
  local token
  token="$(get_sheets_token)"

  local range="Sheet1!F${row}:F${row}"
  local response http_code
  response=$(curl -s --max-time 15 -o - -w "\n%{http_code}" -X POST "${SHEETS_BASE}/${file_id}/values:batchUpdate" \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    -d "{
      \"valueInputOption\": \"USER_ENTERED\",
      \"data\": [{
        \"range\": \"${range}\",
        \"values\": [[\"${value}\"]]
      }]
    }")
  http_code=$(echo "$response" | tail -n1)
  response=$(echo "$response" | sed '$d')

  if [[ "$http_code" == "401" ]]; then
    echo "WARN: update_cell got HTTP 401, forcing token refresh and retrying once" >&2
    token="$(force_refresh_token)" || return 1
    response=$(curl -s --max-time 15 -X POST "${SHEETS_BASE}/${file_id}/values:batchUpdate" \
      -H "Authorization: Bearer ${token}" \
      -H "Accept: application/json" \
      -H "Content-Type: application/json" \
      -d "{
        \"valueInputOption\": \"USER_ENTERED\",
        \"data\": [{
          \"range\": \"${range}\",
          \"values\": [[\"${value}\"]]
        }]
      }")
  fi

  echo "$response"
}

parse_uncontacted() {
  local json="$1"
  local limit="${2:-5}"

  # Skip header row (row 1), filter rows where col F (index 5) is blank/empty,
  # take first N, output as JSON array
  echo "$json" | jq -c --argjson limit "$limit" '
    .values as $all
    | [range(1; $all | length) as $i
       | $all[$i] as $row
       | {rowIndex: ($i + 1), name: $row[0], handle: $row[1], email: $row[2], avgViews: $row[3], platform: $row[4], contacted: ($row[5] // "")}
       | select(.contacted == "" or .contacted == null)]
    | .[0:$limit]'
}
