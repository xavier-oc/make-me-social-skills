#!/usr/bin/env bash
# Google OAuth Helper for Outreach Agent
# Generates authorization URLs and exchanges codes for tokens.
#
# Usage:
#   ./google_oauth.sh authorize-url    # Generate authorization URL
#   ./google_oauth.sh exchange CODE     # Exchange auth code for tokens
#   ./google_oauth.sh status           # Check current token status

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CRED_FILE="$WORKSPACE_DIR/credentials/google_oauth.json"

GOOGLE_AUTH_URL="https://accounts.google.com/o/oauth2/auth"
GOOGLE_TOKEN_URL="https://oauth2.googleapis.com/token"
GOOGLE_REVOKE_URL="https://oauth2.googleapis.com/revoke"

# Required OAuth scopes
SCOPES=(
  "https://www.googleapis.com/auth/calendar"
  "https://www.googleapis.com/auth/spreadsheets"
  "https://www.googleapis.com/auth/drive.readonly"
)

# Redirect URI for desktop app
REDIRECT_URI="http://localhost:8080"

generate_auth_url() {
  local client_id="${1:-}"
  
  if [[ -z "$client_id" ]]; then
    if [[ -f "$CRED_FILE" ]]; then
      client_id=$(jq -r '.client_id' "$CRED_FILE")
    else
      echo "ERROR: No client_id provided and no credentials file found" >&2
      return 1
    fi
  fi
  
  # Build scope string
  local scope_string=""
  for scope in "${SCOPES[@]}"; do
    if [[ -n "$scope_string" ]]; then
      scope_string="${scope_string}+"
    fi
    scope_string="${scope_string}${scope}"
  done
  
  # URL encode scope string
  scope_string=$(echo "$scope_string" | sed 's/ /%20/g' | sed 's/+/%20/g')
  
  local auth_url="${GOOGLE_AUTH_URL}?client_id=${client_id}&redirect_uri=${REDIRECT_URI}&scope=${scope_string}&response_type=code&access_type=offline&prompt=consent"
  
  echo "$auth_url"
}

exchange_code() {
  local code="$1"
  local client_id client_secret
  
  if [[ ! -f "$CRED_FILE" ]]; then
    echo "ERROR: credentials/google_oauth.json not found" >&2
    return 1
  fi
  
  client_id=$(jq -r '.client_id' "$CRED_FILE")
  client_secret=$(jq -r '.client_secret' "$CRED_FILE")
  
  if [[ -z "$client_id" || "$client_id" == "null" ]]; then
    echo "ERROR: No client_id in credentials file" >&2
    return 1
  fi
  
  echo "Exchanging authorization code for tokens..." >&2
  
  local response
  response=$(curl -s --max-time 20 -X POST "$GOOGLE_TOKEN_URL" \
    -d "code=${code}" \
    -d "client_id=${client_id}" \
    -d "client_secret=${client_secret}" \
    -d "redirect_uri=${REDIRECT_URI}" \
    -d "grant_type=authorization_code")
  
  local access_token refresh_token expires_in
  
  access_token=$(echo "$response" | jq -r '.access_token // empty')
  refresh_token=$(echo "$response" | jq -r '.refresh_token // empty')
  expires_in=$(echo "$response" | jq -r '.expires_in // empty')
  
  if [[ -z "$access_token" || "$access_token" == "null" ]]; then
    echo "ERROR: Failed to get access token. Response: $response" >&2
    return 1
  fi
  
  # Calculate expiry timestamp
  local now
  now=$(date +%s)
  local expiry_date=$(( now + expires_in ))
  
  # Create updated credentials JSON
  local tmp_file
  tmp_file=$(mktemp)
  
  jq -n \
    --arg access_token "$access_token" \
    --arg refresh_token "${refresh_token:-$(
      # Preserve existing refresh token if not returned
      jq -r '.refresh_token // empty' "$CRED_FILE"
    )}" \
    --argjson expiry_date "$expiry_date" \
    --arg client_id "$client_id" \
    --arg client_secret "$client_secret" \
    '{
      access_token: $access_token,
      refresh_token: $refresh_token,
      expiry_date: $expiry_date,
      client_id: $client_id,
      client_secret: $client_secret
    }' > "$tmp_file"
  
  # Validate before replacing
  if ! jq -e '.access_token' "$tmp_file" > /dev/null 2>&1; then
    echo "ERROR: Generated invalid credentials file" >&2
    rm -f "$tmp_file"
    return 1
  fi
  
  mv "$tmp_file" "$CRED_FILE"
  
  echo "✓ Tokens saved to $CRED_FILE"
  echo "  Access token expires in: $expires_in seconds"
  
  # Test the token by checking calendar access
  echo "Testing token with Calendar API..." >&2
  local test_response
  test_response=$(curl -s --max-time 15 -X GET "${GOOGLE_TOKEN_URL}/tokeninfo?access_token=${access_token}" 2>&1)
  local token_error
  token_error=$(echo "$test_response" | jq -r '.error // empty')
  
  if [[ -n "$token_error" && "$token_error" != "null" ]]; then
    echo "⚠️  Warning: Token test failed: $test_response" >&2
  else
    echo "✓ Token validation successful"
  fi
}

refresh_token_cli() {
  local refresh_tok client_id client_secret response access_token expires_in
  
  if [[ ! -f "$CRED_FILE" ]]; then
    echo "ERROR: credentials/google_oauth.json not found" >&2
    return 1
  fi
  
  refresh_tok=$(jq -r '.refresh_token' "$CRED_FILE")
  client_id=$(jq -r '.client_id' "$CRED_FILE")
  client_secret=$(jq -r '.client_secret' "$CRED_FILE")
  
  if [[ -z "$refresh_tok" || "$refresh_tok" == "null" ]]; then
    echo "ERROR: No refresh_token available" >&2
    return 1
  fi
  
  response=$(curl -s --max-time 15 -X POST "$GOOGLE_TOKEN_URL" \
    -d "refresh_token=${refresh_tok}" \
    -d "client_id=${client_id}" \
    -d "client_secret=${client_secret}" \
    -d "grant_type=refresh_token")
  
  access_token=$(echo "$response" | jq -r '.access_token // empty')
  expires_in=$(echo "$response" | jq -r '.expires_in // empty')
  
  if [[ -z "$access_token" ]]; then
    echo "ERROR: Token refresh failed: $response" >&2
    return 1
  fi
  
  local now expiry_date
  now=$(date +%s)
  expiry_date=$(( now + expires_in ))
  
  local tmp_file
  tmp_file=$(mktemp)
  
  jq -n \
    --arg access_token "$access_token" \
    --arg refresh_token "$refresh_tok" \
    --argjson expiry_date "$expiry_date" \
    --arg client_id "$client_id" \
    --arg client_secret "$client_secret" \
    '{
      access_token: $access_token,
      refresh_token: $refresh_token,
      expiry_date: $expiry_date,
      client_id: $client_id,
      client_secret: $client_secret
    }' > "$tmp_file"
  
  mv "$tmp_file" "$CRED_FILE"
  echo "✓ Token refreshed successfully"
}

check_status() {
  if [[ ! -f "$CRED_FILE" ]]; then
    echo "No credentials file found at $CRED_FILE"
    return 1
  fi
  
  local expiry access_token
  expiry=$(jq -r '.expiry_date' "$CRED_FILE")
  access_token=$(jq -r '.access_token' "$CRED_FILE")
  
  if [[ -z "$access_token" || "$access_token" == "null" ]]; then
    echo "⚠️  No access token found. Authorization required."
    return 1
  fi
  
  local now
  now=$(date +%s)
  
  if (( now >= expiry )); then
    echo "⚠️  Token expired at $(date -d "@$expiry" 2>/dev/null || echo "$expiry")"
    echo "Run './google_oauth.sh refresh' to refresh"
  else
    local remaining=$(( expiry - now ))
    echo "✓ Token valid"
    echo "  Expires in: $remaining seconds"
    echo "  Expiry: $(date -d "@$expiry" 2>/dev/null || echo "$expiry")"
  fi
  
  if [[ -f "$CRED_FILE" ]]; then
    local has_refresh
    has_refresh=$(jq -r '.refresh_token // "missing"' "$CRED_FILE")
    if [[ "$has_refresh" == "missing" || "$has_refresh" == "null" ]]; then
      echo "⚠️  No refresh token - re-authorization will be required when token expires"
    fi
  fi
}

# CLI
case "${1:-}" in
  authorize-url)
    generate_auth_url "${2:-}"
    ;;
  exchange)
    if [[ -z "${2:-}" ]]; then
      echo "Usage: $0 exchange <authorization_code>" >&2
      exit 1
    fi
    exchange_code "$2"
    ;;
  refresh)
    refresh_token_cli
    ;;
  status)
    check_status
    ;;
  *)
    echo "Usage: $0 <command>" >&2
    echo "" >&2
    echo "Commands:" >&2
    echo "  authorize-url [client_id]  Generate OAuth authorization URL" >&2
    echo "  exchange <code>            Exchange authorization code for tokens" >&2
    echo "  refresh                     Refresh the access token" >&2
    echo "  status                      Check current token status" >&2
    exit 1
    ;;
esac
