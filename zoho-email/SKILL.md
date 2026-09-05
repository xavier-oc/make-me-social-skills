# Zoho Email Skill

Send, read, reply to, and manage emails via the Zoho Mail API.

## Account Details

| Field | Value |
|-------|-------|
| **Account ID** | `2873142000000008002` |
| **Sender Address** | `xavier@makemesocialapp.com` |
| **Display Name** | `xavier` |
| **Inbox Folder ID** | `2873142000000009011` |

## Credentials

All credentials are injected as environment variables at runtime — **no .env file**.

**Required (injected):**
- `ZOHO_CLIENT_ID` — OAuth client ID
- `ZOHO_CLIENT_SECRET` — OAuth client secret
- `ZOHO_REFRESH_TOKEN` — Long-lived refresh token

**Defaults (hardcoded in auth.sh, overridable via env):**
- `ZOHO_ACCOUNT_ID` → `2873142000000008002`
- `ZOHO_FROM_ADDRESS` → `xavier@makemesocialapp.com`
- `ZOHO_INBOX_FOLDER_ID` → `2873142000000009011`

## Scripts

All scripts are in `scripts/zoho/`. Each script sources `auth.sh` for automatic token management.

### auth.sh — Shared Auth Module

Handles OAuth token refresh and caching. **Do not run directly** — sourced by all other scripts.

- Reads credentials from injected environment variables
- Refreshes access token via `https://accounts.zoho.com/oauth/v2/token`
- Caches tokens for ~50 minutes (tokens last 1 hour)
- Cache stored at `scripts/zoho/.zoho_token_cache`

### get_account_id.sh — Retrieve Account ID

```bash
./scripts/zoho/get_account_id.sh
```

Returns JSON with `accountId`, `primaryEmailAddress`, and `accountDisplayName` for all accounts on the authenticated user. Use this if the account ID needs to be re-fetched.

### send_email.sh — Send Email

```bash
./scripts/zoho/send_email.sh \
  --to "recipient@example.com" \
  --subject "Subject line" \
  --body "<p>HTML email body</p>"
```

| Flag | Required | Description |
|------|----------|-------------|
| `--to` | ✅ | Recipient email address |
| `--subject` | ✅ | Email subject |
| `--body` | ✅ | Email body (HTML or plaintext) |
| `--cc` | ❌ | CC address |
| `--bcc` | ❌ | BCC address |
| `--format` | ❌ | `html` (default) or `plaintext` |
| `--account` | ❌ | Override account ID |

Sends from `xavier@makemesocialapp.com` by default.

### get_unread_emails.sh — Retrieve Unread Emails

```bash
# Metadata only (fast)
./scripts/zoho/get_unread_emails.sh --limit 20

# With full email content
./scripts/zoho/get_unread_emails.sh --limit 10 --full
```

| Flag | Required | Description |
|------|----------|-------------|
| `--limit` | ❌ | Max emails to return (default: 20, max: 200) |
| `--folder` | ❌ | Folder ID (default: auto from env/all folders) |
| `--full` | ❌ | Fetch full email content for each message |
| `--account` | ❌ | Override account ID |

**Output fields (metadata mode):** `messageId`, `subject`, `from`, `sender`, `receivedTime`, `summary`, `folderId`, `threadId`, `hasAttachment`

**Output fields (--full mode):** Same plus `content` (full HTML/text body)

### reply_to_email.sh — Reply to an Email

```bash
./scripts/zoho/reply_to_email.sh \
  --message-id "1234567890123456789" \
  --folder-id "9876543210987654321" \
  --to "original-sender@example.com" \
  --body "<p>Reply content here</p>"
```

| Flag | Required | Description |
|------|----------|-------------|
| `--message-id` | ✅ | Message ID to reply to (from get_unread_emails) |
| `--folder-id` | ✅ | Folder ID of the original message (required for correct Zoho thread placement) |
| `--to` | ✅ | Recipient email address |
| `--body` | ✅ | Reply body (HTML or plaintext) |
| `--cc` | ❌ | CC address |
| `--subject` | ❌ | Subject override (defaults to original) |
| `--format` | ❌ | `html` (default) or `plaintext` |
| `--account` | ❌ | Override account ID |

### mark_as_read.sh — Mark Emails as Read

```bash
# By message IDs
./scripts/zoho/mark_as_read.sh --message-ids "ID1,ID2,ID3"

# By thread IDs (marks all messages in thread)
./scripts/zoho/mark_as_read.sh --thread-ids "TID1,TID2"
```

| Flag | Required | Description |
|------|----------|-------------|
| `--message-ids` | ⚠️ | Comma-separated message IDs |
| `--thread-ids` | ⚠️ | Comma-separated thread IDs |
| `--account` | ❌ | Override account ID |

At least one of `--message-ids` or `--thread-ids` is required.

## Common Workflows

### Check and process new emails

```bash
# 1. Get unread emails with content
EMAILS=$(./scripts/zoho/get_unread_emails.sh --limit 50 --full)

# 2. Process each email (extract messageId, from, subject, content)

# 3. Reply to relevant ones
./scripts/zoho/reply_to_email.sh --message-id "$MSG_ID" --folder-id "$FOLDER_ID" --to "$FROM" --body "$REPLY"

# 4. Mark processed emails as read
./scripts/zoho/mark_as_read.sh --message-ids "$ID1,$ID2,$ID3"
```

### Send outreach email

```bash
./scripts/zoho/send_email.sh \
  --to "creator@example.com" \
  --subject "Collaboration opportunity" \
  --body "<p>Hi there...</p>"
```

## API Reference

| Action | Method | Endpoint | Scope |
|--------|--------|----------|-------|
| Get accounts | GET | `/api/accounts` | `ZohoMail.accounts.READ` |
| Send email | POST | `/api/accounts/{id}/messages` | `ZohoMail.messages.CREATE` |
| List emails | GET | `/api/accounts/{id}/messages/view` | `ZohoMail.messages.READ` |
| Email content | GET | `/api/accounts/{id}/folders/{fid}/messages/{mid}/content` | `ZohoMail.messages.READ` |
| Reply | POST | `/api/accounts/{id}/messages/{mid}` | `ZohoMail.messages.CREATE` |
| Mark as read | PUT | `/api/accounts/{id}/updatemessage` | `ZohoMail.messages.UPDATE` |

Base URL: `https://mail.zoho.com`

## Notes

- **Token scope:** The current refresh token does NOT have `ZohoMail.folders` scope. Folder IDs are extracted from message metadata instead.
- **Token caching:** Access tokens are cached at `scripts/zoho/.zoho_token_cache` and auto-refreshed after ~50 min.
- **Rate limits:** Zoho Mail API has rate limits. Avoid tight loops — batch where possible.
- **Message IDs are strings:** Always treat message/thread/folder IDs as strings to avoid integer precision issues.
- **Reply action:** Use lowercase `"reply"` not `"Reply"` — the API is case-sensitive here.
- **HTML emails:** Default format is `html`. Pass `--format plaintext` for plain text.
