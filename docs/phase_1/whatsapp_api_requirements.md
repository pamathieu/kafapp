# WhatsApp API Requirements

## Overview

The system integrates with Meta WhatsApp Cloud API for certificate delivery.

---

## Required Setup

1. Meta Developer Account
2. WhatsApp Business App
3. Phone Number Registration
4. Access Token Generation
5. Message Template Approval

---

## API Requirements

- HTTPS endpoint
- Bearer access token
- Recipient phone number
- Attachment URL or media upload

---

## Delivery Logic

After certificate generation:

- Send PDF attachment OR
- Send secure S3 link

Update delivery status in database.

---

## Error Handling

- Capture API error responses
- Record failure in database
- Enable retry mechanism