---
name: creator-outreach
description: "Run creator outreach from a Google Sheet: filter uncontacted creators, send personalized emails via Zoho, update the sheet."
---

# Creator Outreach

Reads a Google Sheet of creators, emails the first 5 uncontacted ones via Zoho Mail, updates the sheet, and reports via Telegram.

## Spreadsheet
- **File ID:** `1qxOzRtjTXe3LCoz4_YLgMEZoXTOYB9xOmYndDz3S_iE`
- **Sheet name:** `Sheet1`
- **Columns:** Name | Handle | Email | Avg Views | Platform | Contacted

## Hard Gate
**If no rows have a blank `Contacted` cell, stop immediately.** Report "No uncontacted creators — nothing to do."

## Credentials
1. Read `credentials/google_oauth.json`
2. Check `expiry_date` — refresh using `refresh_token` if expired
3. Use the current `access_token` for all Drive/Sheets API calls

## Workflow

### Step 1 — Read sheet
Run `scripts/send_outreach.sh`. It reads the sheet, filters uncontacted creators, and outputs JSON to stdout:

```json
{
  "creatorCount": 3,
  "fileId": "1qxOzRtjTXe3LCoz4_YLgMEZoXTOYB9xOmYndDz3S_iE",
  "subjects": ["Partnership", "Potential Collaboration", "Content Partnership"],
  "creators": [
    {"rowIndex": 45, "name": "Max Pankowski", "email": "maxpanko@maxpanko.com", "handle": "@max_panko5", "platform": "Instagram"}
  ]
}
```

If output is `NO_UNCONTACTED`, stop immediately.

### Step 2 — Compose messages (LLM-generated)
For each creator, generate the email body using the rules in **Step 3** below.

**Assign subject lines** from the `subjects` array in order — no repeats.

**Validate email addresses** — skip and log if:
- `test@test.com`, `example@example.com`, or any placeholder
- Empty or null

### Step 3 — Message composition rules

Template:
> "Hey {{first_name}}, [one sentence they're a fit — NO compliments], [one sentence on what the app is], [one sentence asking about a call]"

Rules:
- `{{first_name}}` = first name from Name. If it looks like a brand (e.g. "Your Wellness Girly"), use "Hey," instead.
- Vary wording — do not copy template verbatim.
- App name: **Make Me Social** (always written as three separate words, never "MakeMeSocial" or "MakeMeSocialApp").
- Pitch: helps people build social skills, confidence and charisma.
- **RULE: Never compliment, or mention avg views, follower count, reach, or any metric/number.**
- Do not elaborate any more about what the app does
- Do not mention anything about growing an audience

Optional:
- Mention finding them on their platform listed in the row as part of the intro sentence explaining why they're a fit. (ex. "Saw you on Instagram and thought you'd be perfect for our app".)

Examples:
1) "Hey Max, saw your content on Instagram and thought you'd be a good fit to represent our app Make Me Social. It teaches social skills and confidence building. Let me know if you're interested in hopping on a call."

2) "Hey Frankie, based on your content I think you're a good fit to reach the target audience we're trying to target with our app Make Me Social. It's an app designed to teach people how to deal with anxiety and learn social skills. Let me know if you'd be interested in jumping on a call to discuss potentially partnering with us."

3) "Hey, I think your content and audience would be a good fit for our app Make Me Social. It helps people learn social skills and build confidence and charisma. Let me know if you want to discuss further on a call." (use when name appears to be a brand)

### Step 4 — Send via Zoho Mail
For each creator with a valid email:
1. Send via `scripts/zoho/send_email.sh --to "$EMAIL" --subject "$SUBJECT" --body "$BODY"`
2. On success, update the Contacted cell via `scripts/send_outreach.sh --update-row "$FILE_ID" "$ROW" "$DATE"`
3. Sleep 60 seconds before next creator (skip after last)

**RULE: Never send a test email. Do NOT send to test@test.com, example@example.com, or any placeholder. If the API call fails, stop — no test sends.**

### Step 5 — Report
Send a Telegram message summarizing:
- How many emails were sent
- Name + Email + Subject for each
- Confirmation that Contacted cells were updated (or note any failures)

## Scripts

- `scripts/sheet_helpers.sh` — read sheet, refresh token, build request JSON, parse rows
- `scripts/send_outreach.sh` — main orchestrator. Without args: outputs creator JSON. With `--update-row`: updates Contacted cell.