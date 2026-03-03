# Functional Requirements

## FR-1: Data Storage

The system shall store:

- Company data
- Member data
- Certificate metadata

in AWS DynamoDB.

---

## FR-2: Certificate Generation

The system shall:

- Retrieve member data
- Retrieve company data
- Inject values into certificate template
- Generate:
  - PDF
  - JPEG

---

## FR-3: File Storage

The system shall upload generated files to Amazon S3.

---

## FR-4: Metadata Recording

The system shall record:

- S3 file URLs
- Issue date
- Delivery status
- Timestamp

in the Certificates table.

---

## FR-5: WhatsApp Delivery

The system shall:

- Call Meta WhatsApp Cloud API
- Send certificate as attachment or link
- Update delivery status accordingly

---

## FR-6: Error Handling

If WhatsApp delivery fails:

- Record failure
- Allow retry mechanism