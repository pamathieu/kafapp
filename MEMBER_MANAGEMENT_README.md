# KAFA Member Management

## Project Overview

The KAFA Member Management system is a Flutter-based admin application that connects directly to the KAFA Certificate Platform backend on AWS. It allows authorized administrators to view, search, edit, and manage the status of all cooperative members.

The system:

- Authenticates the admin with a username and password
- Displays a searchable, filterable list of all members
- Shows full member details pulled live from DynamoDB via API Gateway
- Allows the admin to edit member data and confirm changes with an Update action
- Allows the admin to activate or deactivate individual members

There is no public-facing portal. Access is restricted to authenticated admins only.

---

# System Architecture

Admin (Flutter App) → API Gateway → Lambda → DynamoDB

All API calls are signed with AWS SigV4 and routed through the existing `certplatform-prod-certificate-handler` Lambda.

---

# Phase 1 — Requirements & Architecture Definition

## Key Requirements

### Admin Authentication
- Username and password login screen
- Session held in memory for the duration of the app session
- All API calls signed with AWS credentials on behalf of the admin

### Member List View
- Display all members for company KAFA-001
- Show: full name, member ID, phone number, active/inactive status
- Real-time search by name, ID, phone, email, or address
- Filter chips: All / Active / Inactive
- Stats banner: total, active, and inactive counts

### Member Detail View
- Display all member fields from DynamoDB
- Show linked certificate metadata if present

### Edit & Update
- Admin clicks **Edit** to enter edit mode
- All fields become editable inline
- Admin clicks **Update** to persist changes via API
- Admin can cancel to discard changes

### Activate / Deactivate
- Toggle button in the app bar on the detail screen
- Requires confirmation before applying
- Updates the `status` boolean attribute in DynamoDB

---

# Phase 2 — Infrastructure (AWS Backend)

The Flutter app consumes existing API Gateway endpoints. Two new routes and one new DynamoDB attribute were added to support this feature.

## New API Gateway Routes

### GET /members/list
- Returns all members for a given `companyId`
- Used to populate the member list screen

### POST /members/edit
- Accepts `memberId` + `companyId`
- Returns the full member record ready for editing

### POST /members/update
- Accepts updated member fields including `status`
- Persists changes to DynamoDB via `update_item`
- Returns the updated member record

## New DynamoDB Attribute

### status (Boolean)
- Added to `kopera-member` table
- `true` = member is active
- `false` = member is inactive
- Default: `true` for all existing members

Run the one-time migration script to backfill this attribute:

```
python add_status_attribute.py
```

## CORS Configuration

When the Flutter app runs in a browser (Chrome), the browser enforces CORS and will block API Gateway responses that do not include the correct headers. The following changes were made to support browser-based access:

### Lambda (handler.py)
- All responses now include `Access-Control-Allow-Origin: *`
- All responses now include `Access-Control-Allow-Headers` and `Access-Control-Allow-Methods`
- An `OPTIONS` preflight handler was added to the Lambda router

### API Gateway (main.tf)
- An `OPTIONS` method with a MOCK integration was added to each of the three new routes
- Each OPTIONS method returns the required CORS response headers

After updating `handler.py`, redeploy the Lambda:

```
cd ~/Projects/kafapp
cp handler.py lambda/package/handler.py
cd lambda/package && zip -r ../certificate_handler.zip . && cd ../..
aws s3 cp lambda/certificate_handler.zip s3://kopera-asset/lambda/certificate_handler.zip
aws lambda update-function-code \
  --function-name certplatform-prod-certificate-handler \
  --s3-bucket kopera-asset \
  --s3-key lambda/certificate_handler.zip
```

## Terraform

`main.tf` in `~/Projects/kafapp` was updated to include:
- Three new API Gateway routes: `GET /members/list`, `POST /members/edit`, `POST /members/update`
- Three OPTIONS CORS methods (one per new route)
- Updated deployment triggers

Run from `~/Projects/kafapp`:

```
terraform apply
```

Note: `main.tf` lives in `kafapp` only. The `member_management` Flutter project does not contain any Terraform files.

---

# Phase 3 — Database Design

## kopera-member Table (existing, extended)

- memberId (PK)
- companyId (SK)
- full_name
- date_of_birth
- address
- phone
- email
- identification_number
- identification_type
- status ← **new Boolean attribute**
- notes
- issued_date
- certificate (nested map)

### Nested Certificate Object

```json
{
  "certificate": {
    "certificate_id": "CERT-86146139",
    "issued_date":    "07 / 03 / 2026",
    "pdf_s3_url":     "s3://kopera-certificate/certificates/KAFA-001/MBR-004/CERT-86146139.pdf",
    "jpeg_s3_url":    "s3://kopera-certificate/certificates/KAFA-001/MBR-004/CERT-86146139.jpeg",
    "whatsapp_sent":  false,
    "timestamp":      "2026-03-07T00:00:00Z"
  }
}
```

---

# Phase 4 — Flutter App Structure

## Technology Stack

- Flutter (Dart)
- `http` — HTTP client for API calls
- `aws_signature_v4` — SigV4 request signing for API Gateway
- `provider` — State management for auth session

## Project Structure

```
member_management/
├── pubspec.yaml
└── lib/
    ├── main.dart                          # App entry point + theme
    ├── models/
    │   └── member.dart                    # Member data model
    ├── providers/
    │   └── auth_provider.dart             # Login state + ApiService wiring
    ├── services/
    │   └── api_service.dart               # SigV4-signed API Gateway calls
    └── screens/
        ├── login_screen.dart              # Admin login
        ├── members_screen.dart            # Member list + search + filter
        └── member_detail_screen.dart      # Detail view + Edit + Update
```

---

# Phase 5 — Authentication

## Admin Credentials (Default)

- Username: `admin`
- Password: `kafa2026`

Credentials are defined in `lib/providers/auth_provider.dart`. For production, replace with AWS Cognito or a backend auth endpoint.

## AWS Credentials

The app uses AWS SigV4 signing for all API Gateway calls. Credentials are set in `auth_provider.dart`:

```dart
static const String _awsAccessKeyId     = 'YOUR_ACCESS_KEY_ID';
static const String _awsSecretAccessKey = 'YOUR_SECRET_ACCESS_KEY';
```

For production, replace with Cognito Identity Pool temporary credentials or a secure secrets manager.

---

# Phase 6 — Member Edit & Update Flow

## Workflow

1. Admin taps a member from the list
2. Detail screen loads — all fields displayed in read-only mode
3. Admin taps **Edit** — all fields become editable inline
4. Admin modifies one or more fields
5. Admin taps **Update** — app calls `POST /members/update`
6. Lambda runs `update_item` on DynamoDB with allowed fields only
7. Updated record is returned and displayed
8. Success banner confirms the change

## Activate / Deactivate Flow

1. Admin opens any member's detail screen
2. Taps the person icon in the app bar
3. Confirmation dialog appears
4. Admin confirms — app calls `POST /members/update` with `status: true/false`
5. Status badge updates immediately on screen

## Allowed Editable Fields

- full_name
- date_of_birth
- address
- phone
- email
- identification_number
- identification_type
- status
- notes

---

# Phase 7 — Testing & Deployment

## Testing

- Validate admin login accepts correct credentials and rejects incorrect ones
- Validate member list loads all 52 members from DynamoDB
- Validate search filters results correctly across all fields
- Validate member detail screen displays all DynamoDB attributes
- Validate Edit mode populates all fields correctly
- Validate Update persists changes to DynamoDB
- Validate Activate / Deactivate toggles status correctly
- Validate cancel discards changes without saving

## Deployment

### 1. Backfill DynamoDB status attribute

```
python add_status_attribute.py
```

### 2. Deploy new API Gateway routes

```
terraform apply
```

### 3. Install Flutter dependencies

```
cd member_management
flutter pub get
```

### 4. Run the app

```
flutter run                  # development
flutter build apk            # Android release
flutter build ios            # iOS release (requires Mac + Xcode)
```

---

# Security Considerations

- All API Gateway routes (except `/retrieve`) require AWS_IAM authorization
- API calls are signed with SigV4 — unsigned requests are rejected by API Gateway
- Admin credentials should be moved to Cognito or a backend auth service before production
- AWS credentials should be scoped to minimum required permissions
- No member data is stored locally on the device — all reads are live from DynamoDB

---

# Project Completion Criteria

The project is considered complete when:

- Admin can log in and view all 52 KAFA members
- Search and filter work correctly across all fields
- Member detail screen displays all DynamoDB data accurately
- Edit and Update flow persists changes to DynamoDB
- Activate and Deactivate correctly toggle the `status` attribute
- Infrastructure changes are fully reproducible via Terraform
- All 52 members have the `status` attribute backfilled

---

# Future Enhancements (Optional)

- Replace hardcoded credentials with AWS Cognito authentication
- Add role-based access control (read-only vs. admin roles)
- Add audit trail — log who changed what and when
- Certificate regeneration button from within the detail screen
- Bulk activate / deactivate from the list screen
- Push notifications when a member's certificate is ready
- Offline mode with local caching

---

# Status

Phases 1–7 Fully Defined
Implementation: Complete
