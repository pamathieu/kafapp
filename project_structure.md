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

## Key Requirements

### Company Information (Static)
- Company Name
- Registration Number
- Logo
- Address
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
- Inject dynamic data into official template
- Preserve formatting
- Auto-insert issue date
- Generate PDF + JPEG

---

# Phase 2 — Infrastructure Setup (Terraform)

## AWS Components

### DynamoDB
- Companies table
- Members table (includes certificate object)

### S3
- Store PDF certificates
- Store JPEG certificates
- Private bucket

### Lambda
- Certificate generation
- Upload to S3
- Update member certificate object
- Trigger WhatsApp delivery

### API Gateway
- Secure REST endpoint
- Invokes Lambda

### IAM (Least Privilege)
- Lambda → DynamoDB
- Lambda → S3
- API Gateway → Lambda

---

# Phase 3 — Database Design

## Companies Table

- company_id (PK)
- company_name
- registration_number
- address
- phone
- email
- website
- logo_s3_url

---

## Members Table

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

### Nested Certificate Object

Each member contains a `certificate` map attribute.

Structure:

certificate: {
certificate_id,
issued_date,
pdf_s3_url,
jpeg_s3_url,
whatsapp_sent,
timestamp
}

---

## Example DynamoDB Member Item

```json
{
  "memberId":       { "S": "MBR-001" },
  "companyId":      { "S": "KAFA-001" },
  "certificate": {
    "M": {
      "certificate_id":  { "S": "CERT-001" },
      "issued_date":     { "S": "2025-01-01" },
      "pdf_s3_url":      { "S": "s3://kopera-certificate/certificates/MBR-001.pdf" },
      "jpeg_s3_url":     { "S": "s3://kopera-certificate/certificates/MBR-001.jpeg" },
      "whatsapp_sent":   { "BOOL": false },
      "timestamp":       { "S": "2025-01-01T00:00:00Z" }
    }
  }
}
```
---

# Phase 4 — Certificate Generation Engine

## Workflow

1. Retrieve member data from DynamoDB  
2. Retrieve company data from DynamoDB  
3. Inject values into certificate template  
4. Generate:
   - PDF (reportlab)
   - JPEG (Pillow)
5. Upload files to S3  
6. Update nested `certificate` object in member record  
7. Trigger WhatsApp delivery  

---

## Suggested Technologies

- Python  
- boto3  
- reportlab  
- Pillow (PIL)  

---

# Phase 5 — WhatsApp Integration (Meta Cloud API)

## Setup Requirements

- Meta Developer Account  
- WhatsApp Business App  
- Phone Number Registration  
- Access Token Generation  
- Approved Message Template  

---

## Delivery Logic

After certificate generation:

1. Call Meta WhatsApp API  
2. Send:
   - PDF attachment **OR**
   - Secure S3 link  
3. Update `whatsapp_sent` flag inside certificate object  

---

## Error Handling

- Capture API errors  
- Update failure state  
- Allow retry mechanism  

---

# Phase 6 — Testing & Deployment

## Testing

- Validate DynamoDB reads/writes  
- Validate S3 uploads  
- Validate Lambda execution  
- Validate API Gateway invocation  
- Validate WhatsApp message delivery  
- Perform full end-to-end test  

---

## Deployment

- Deploy infrastructure via Terraform  
- Deploy Lambda code  
- Configure production environment variables  
- Validate end-to-end workflow  

---

# Security Considerations

- IAM least-privilege policies  
- Private S3 bucket  
- Secure API Gateway configuration  
- Protected Meta API tokens  
- Input validation before certificate generation  

---

# Project Completion Criteria

The project is considered complete when:

- Certificate PDF + JPEG are generated correctly  
- Files are stored in S3  
- Certificate object is saved inside member record  
- WhatsApp delivery is successful  
- Infrastructure is fully reproducible via Terraform  
- End-to-end flow is fully automated  

---

# Future Enhancements (Optional)

- Multi-certificate support (change `certificate` → `certificates` list)  
- Admin dashboard  
- Delivery analytics  
- Automated certificate numbering  
- Multi-language certificate support  
- Audit trail logging  

---

# Status

Phases 1–6 Fully Defined  
Implementation: Pending Infrastructure Deployment  