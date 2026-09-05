# Credential Setup Checklist

This document lists all credentials required for the outreach agent and how to obtain each one.

---

## Email Provider Credentials

### 1. OAuth Client ID

**What it is:** The public identifier for your OAuth application, used to authenticate API requests.

**Where to get it:**
1. Log into your email provider's developer/console portal
2. Find or create an OAuth application
3. Copy the Client ID

**Variable name for .env:** `{PROVIDER}_CLIENT_ID`

---

### 2. OAuth Client Secret

**What it is:** The secret key used to authenticate your OAuth application alongside the Client ID.

**Where to get it:**
1. Same location as Client ID in the developer portal
2. Click to reveal/view the secret
3. Copy the secret value

**⚠️ SECURITY:** Never share this publicly or commit it to version control.

**Variable name for .env:** `{PROVIDER}_CLIENT_SECRET`

---

### 3. Refresh Token

**What it is:** A long-lived token used to obtain new access tokens when they expire. Access tokens typically expire after 1 hour.

**Where to get it:**
1. Complete the OAuth authorization flow:
   - Build the authorization URL with required scopes
   - Visit the URL in a browser
   - Authorize the application
   - Receive a callback with an authorization code
   - Exchange the code for tokens
2. Store the refresh token securely

**Variable name for .env:** `{PROVIDER}_REFRESH_TOKEN`

---

### 4. Account ID / Organization ID

**What it is:** Your unique account identifier in the email provider's system.

**Where to get it:**
1. Check your account settings in the provider portal
2. Often visible in API responses or account details
3. Sometimes called "Organization ID" or "Account Key"

**Variable name for .env:** `{PROVIDER}_ACCOUNT_ID`

---

### 5. Sender Email Address

**What it is:** The email address that outgoing messages will appear to come from.

**Where to get it:** This is typically your email address or an alias in the email system.

**Variable name for .env:** `{PROVIDER}_FROM_ADDRESS`

---

## Google Credentials

Google credentials are stored in a JSON file, not the .env file.

### File Location
```
~/.openclaw/workspace/credentials/google_oauth.json
```

### Required Fields in JSON
```json
{
  "client_id": "...",
  "client_secret": "...",
  "refresh_token": "...",
  "access_token": "...",
  "expiry_date": 1234567890000
}
```

### Where to Get Google Credentials

1. **Create or use a Google Cloud Project**
   - Go to [console.cloud.google.com](https://console.cloud.google.com)
   - Create a new project or select an existing one

2. **Enable Required APIs**
   - Google Calendar API
   - Google Sheets API
   - Google Drive API

3. **Create OAuth Credentials**
   - Go to "Credentials" → "Create Credentials" → "OAuth client ID"
   - Application type: "Desktop app" (recommended for local agent)
   - Download the JSON file

4. **Authorize the Application**
   - The setup wizard will generate an authorization URL
   - Visit the URL with your dedicated Google account
   - Authorize the requested permissions
   - Paste the authorization code back to complete setup

### Required OAuth Scopes

When authorizing, ensure these scopes are granted:
- `https://www.googleapis.com/auth/calendar` - Read and write calendar events
- `https://www.googleapis.com/auth/spreadsheets` - Read and write spreadsheet data
- `https://www.googleapis.com/auth/drive.readonly` - Access spreadsheet files

### Important: Use a Dedicated Account

**Recommendation:** Create a separate Google account specifically for the outreach agent (e.g., "Your Name's Outreach").

Benefits:
- Isolates the agent's calendar access from your personal calendar
- Meeting invites appear professional (from the dedicated account)
- Easier to manage permissions and audit trail
- If compromised, doesn't give access to your main Google account

---

## Provider-Specific Setup Links

### Zoho
- Developer Console: https://accounts.zoho.com/developerconsole
- API Documentation: https://www.zoho.com/mail/api/
- OAuth Scopes: `ZohoMail.messages.CREATE`, `ZohoMail.messages.READ`, `ZohoMail.messages.UPDATE`, `ZohoMail.accounts.READ`

### Gmail / Google Workspace
- Developer Console: https://console.cloud.google.com
- API Documentation: https://developers.google.com/gmail/api
- OAuth Scopes: `gmail.send`, `gmail.readonly`, `gmail.modify`

### SendGrid
- API Keys: https://app.sendgrid.com/settings/api_keys
- API Documentation: https://docs.sendgrid.com/api-reference

### Mailgun
- API Keys: https://app.mailgun.com/app/dashboard
- API Documentation: https://documentation.mailgun.com/en/latest/

### Amazon SES
- IAM Console: https://console.aws.amazon.com/iam/
- API Documentation: https://docs.aws.amazon.com/ses/latest/DeveloperGuide/Welcome.html

---

## Security Best Practices

### ✅ DO:
- Store credentials in `~/.openclaw/workspace/.env`
- Use a dedicated Google account for the agent
- Rotate tokens periodically
- Keep credentials out of version control (.gitignore)

### ❌ DON'T:
- Share credentials in Telegram or other messaging
- Commit credentials to git repositories
- Use the same credentials for production and development
- Store credentials in plaintext files outside the workspace
