# Customer Support Agent Template

Interactive setup wizard that generates **email-support** and **sms-support** skills for your OpenClaw agent.

## What It Creates

1. **COMPANY_KNOWLEDGE_BASE.md** — Central knowledge file with all your business info
2. **email-support** — Checks unread emails, replies using knowledge base, schedules events
3. **sms-support** — Responds to Twilio webhooks, replies using knowledge base, schedules events

## Quick Start

```
Say "start support setup" to begin the wizard
```

## The Wizard Asks For

1. Knowledge base document/link (becomes COMPANY_KNOWLEDGE_BASE.md)
2. Company name
3. Support email address
4. Support phone number (Twilio)
5. Email provider selection
6. Link to email provider API docs
7. Whether to enable calendar booking

## After Setup

Edit `~/.openclaw/workspace/.env` with your credentials:

```bash
# Email Provider (example: Zoho)
ZOHO_CLIENT_ID=xxx
ZOHO_CLIENT_SECRET=xxx
ZOHO_REFRESH_TOKEN=xxx
ZOHO_ACCOUNT_ID=xxx
ZOHO_FROM_ADDRESS=support@yourcompany.com

# Twilio
TWILIO_ACCOUNT_SID=xxx
TWILIO_AUTH_TOKEN=xxx
TWILIO_PHONE_NUMBER=+1234567890
```

## Twilio Webhook Setup

In Twilio console, set your webhook URL to:
```
https://your-openclaw-url/api/twilio/webhook
```

## Calendar Setup (Optional)

If you enabled calendar booking:
1. Go to console.cloud.google.com
2. Create project → Enable Google Calendar API
3. Create OAuth credentials (Desktop app)
4. Download as `google_oauth.json`
5. Place at `~/.openclaw/workspace/credentials/google_oauth.json`
