# Data Model Draft

## Table: Companies

- company_id (PK)
- company_name
- registration_number
- address
- phone
- email
- website
- logo_s3_url

---

## Table: Members

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

---

## Table: Certificates

- certificate_id (PK)
- member_id
- company_id
- issued_date
- pdf_s3_url
- jpeg_s3_url
- whatsapp_sent (boolean)
- timestamp