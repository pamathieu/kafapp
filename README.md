# KAFA Automated WhatsApp Certificate System

## Project Overview

The KAFA Automated WhatsApp Certificate System is a cloud-based solution that generates official membership certificates and delivers them directly to members via WhatsApp.

The system:

- Collects company and member information
- Generates an official certificate (PDF + JPEG)
- Stores certificate data securely in AWS
- Sends the certificate to the member using the Meta WhatsApp Cloud API

There is no login system and no user portal. Delivery is exclusively via WhatsApp.

---

# System Architecture

Admin → API Gateway → Lambda → DynamoDB  
                     ↓  
                     S3  
                     ↓  
                  Meta WhatsApp API → Member  

---

# Phase 1 — Requirements & Architecture Definition

## Objective
Define system scope, data fields, and high-level architecture.

## Key Requirements

### Company Information (Static)
- Company Name
- Registration Number
- Logo
- Address (Siège Social)
- Phone
- Email
- Website
- Authorized Signatories
- Official Seal

### Member Information (Dynamic)
- Full Name
- Date of Birth
- Identification Number
- Identification Type
- Address
- Member Number
- Date of Membership
- WhatsApp Phone Number (Required)

### Certificate Requirements
- Inject dynamic data into official certificate template
- Preserve formatting
- Auto-insert issue date
- Generate:
  - PDF (official version)
  - JPEG (preview version)

### Delivery Requirement
- Send certificate via WhatsApp
- Attach PDF or secure S3 link
- Update delivery status

---

# Phase 2 — Infrastructure Setup (Terraform)

## Objective
Provision all required AWS resources using Terraform.

## Infrastructure Components

### AWS DynamoDB
- Store companies
- Store members
- Store certificate metadata

### AWS S3
- Store generated PDF certificates
- Store generated JPEG versions
- Private bucket by default

### AWS Lambda
- Generate certificates
- Upload to S3
- Update DynamoDB
- Trigger WhatsApp delivery

### AWS API Gateway
- Securely expose backend endpoints
- Invoke Lambda function

### IAM Roles (Least Privilege)
- Lambda access to DynamoDB
- Lambda access to S3
- API Gateway permission to invoke Lambda

> Note: CloudWatch logging is intentionally excluded from this phase.

---

# Phase 3 — Database Design

## DynamoDB Tables

### Companies Table
- company_id (PK)
- company_name
- registration_number
- address
- phone
- email
- website
- logo_s3_url

### Members Table
- member_id (PK)
- company_id
- full_name
- dob
- id_number
- id_type
- address
- member_number
- join_date
- whatsapp_number

### Certificates Table
- certificate_id (PK)
- member_id
- company_id
- issued_date
- pdf_s3_url
- jpeg_s3_url
- whatsapp_sent (boolean)
- timestamp

---

# Phase 4 — Certificate Generation Engine

## Objective
Build backend logic that generates official certificates.

## Process Flow

1. Retrieve member data from DynamoDB
2. Retrieve company data from DynamoDB
3. Inject data into certificate template
4. Generate:
   - PDF version
   - JPEG version
5. Upload files to S3
6. Save certificate metadata in DynamoDB

## Suggested Tools
- Python
- reportlab (PDF generation)
- PIL or Pillow (JPEG generation)
- boto3 (AWS SDK)

---

# Phase 5 — WhatsApp (Meta API) Integration

## Objective
Deliver generated certificates via WhatsApp.

## Steps

1. Create Meta Developer Account
2. Configure WhatsApp Cloud API
3. Generate access token
4. Register phone number
5. Create message template

## Delivery Process

After certificate generation:

- Call Meta WhatsApp API
- Send:
  - PDF attachment OR
  - Secure S3 download link
- Update certificate status in DynamoDB

## Error Handling
- Log failures
- Implement retry mechanism

---

# Phase 6 — Testing & Deployment

## Testing

- Validate DynamoDB operations
- Validate S3 uploads
- Validate Lambda execution
- Validate API Gateway invocation
- Validate WhatsApp message delivery
- Perform full end-to-end test

## Deployment

- Deploy Terraform infrastructure
- Deploy Lambda code
- Configure production environment variables
- Verify complete workflow

---

# Security Considerations

- Least-privilege IAM policies
- Private S3 bucket
- Secure API Gateway configuration
- Controlled access to Meta API tokens

---

# Project Completion Criteria

The project is considered complete when:

- Certificates are generated correctly (PDF + JPEG)
- Certificates are stored in S3
- Metadata is stored in DynamoDB
- WhatsApp delivery is successful
- Infrastructure is fully reproducible via Terraform
- End-to-end system functions without manual intervention

---

# Future Enhancements (Optional)

- Admin dashboard
- Delivery analytics
- Automated certificate numbering
- Multi-language certificate support
- Audit trail logging

---

# Status

Current Phase: Phase 1–6 Structured and Defined  
Deployment: Pending Infrastructure Implementation
