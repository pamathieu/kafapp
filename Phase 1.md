\# Phase 1 — Requirements & Architecture Definition

\#\# Project Name  
KAFA Automated WhatsApp Certificate System

\---

\#\# 1\. Project Objective

Build an automated cloud-based system that:

\- Collects Company Information  
\- Collects Member Information  
\- Generates an official KAFA membership certificate (PDF \+ JPEG)  
\- Stores certificate data in AWS  
\- Sends the certificate directly to the member via WhatsApp  
\- Requires a WhatsApp-enabled phone number for delivery

There is \*\*no login system\*\* and no user portal. Delivery is exclusively via WhatsApp.

\---

\#\# 2\. Functional Requirements

\#\#\# 2.1 Company Information (Static Data)

The following data is stored once and reused for all certificates:

\- Company Name (KAFA)  
\- Registration Number  
\- Logo  
\- Siège Social (Address)  
\- Phone  
\- Email  
\- Website  
\- Authorized Signatories  
  \- Secretary of the Board  
  \- Executive Director  
\- Official Seal

\---

\#\#\# 2.2 Member Information (Dynamic Data)

The following data is required for each certificate:

\- Full Name  
\- Date of Birth  
\- Identification Number  
\- Identification Type  
\- Address  
\- Member Number  
\- Date of Membership  
\- WhatsApp Phone Number (REQUIRED)

\> The phone number must be WhatsApp-enabled.

\---

\#\# 3\. Certificate Generation Requirements

The system must:

\- Inject company \+ member data into the official certificate template  
\- Preserve formatting and layout  
\- Automatically insert issue date  
\- Generate:  
  \- 1 PDF version (official certificate)  
  \- 1 JPEG version (preview/shareable format)

\---

\#\# 4\. Data Storage Requirements

\#\#\# AWS DynamoDB  
\- Store member information  
\- Store certificate metadata  
\- Store certificate delivery status

\#\#\# AWS S3  
\- Store generated PDF certificates  
\- Store generated JPEG versions

\---

\#\# 5\. WhatsApp Delivery Requirements

After certificate generation:

1\. Call Meta WhatsApp Cloud API  
2\. Send message to member  
3\. Attach:  
   \- PDF file  
   OR  
   \- Secure S3 link  
4\. Update certificate status to "Sent"

If delivery fails:  
\- Log error  
\- Enable retry mechanism

\---

\#\# 6\. Non-Functional Requirements

\- Secure API endpoints  
\- IAM-based access control  
\- CloudWatch logging  
\- Error handling & retry logic  
\- Infrastructure managed using Terraform  
\- Scalable architecture

\---

\#\# 7\. High-Level System Flow

1\. Admin submits member data  
2\. Data saved to DynamoDB  
3\. Lambda function generates certificate  
4\. Certificate saved to S3  
5\. Certificate record saved in DynamoDB  
6\. Meta API sends WhatsApp message  
7\. Delivery status updated

\---

\#\# 8\. Scope Clarification

Removed from system:

\- ❌ User authentication  
\- ❌ Login system  
\- ❌ Member dashboard  
\- ❌ Web portal access

System operates as:

Admin → AWS Backend → WhatsApp → Member

\---

\#\# 9\. Phase 1 Deliverables

By completion of Phase 1:

\- Finalized data fields  
\- Confirmed certificate variable mapping  
\- Draft DynamoDB schema  
\- Defined system architecture  
\- Confirmed WhatsApp API requirements  
\- Documented functional & non-functional requirements

\---

\*\*Status:\*\* Phase 1 – Requirements & Architecture Definition Complete  
