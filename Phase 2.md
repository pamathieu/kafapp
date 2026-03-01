\# Phase 2 — Infrastructure Setup (Terraform)

\#\# Goal  
Provision the AWS infrastructure required to support certificate generation, storage, and WhatsApp delivery.

This phase focuses only on deploying core services and required permissions using Terraform.

\---

\#\# 1\. Infrastructure Components

\#\#\# 1.1 AWS DynamoDB (Database)  
Purpose:  
\- Store company records  
\- Store member records  
\- Store certificate metadata (S3 links, issue date, delivery status)

Deliverable:  
\- DynamoDB tables created and accessible from Lambda

\---

\#\#\# 1.2 AWS S3 (Storage)  
Purpose:  
\- Store generated certificates as:  
  \- PDF (official)  
  \- JPEG (preview/shareable)

Deliverable:  
\- S3 bucket created with:  
  \- A clear folder/key naming strategy (ex: \`certificates/{company\_id}/{member\_id}/...\`)  
  \- Proper access configuration (private by default)

\---

\#\#\# 1.3 AWS Lambda (Compute)  
Purpose:  
\- Core backend function that will:  
  \- Pull company \+ member info from DynamoDB  
  \- Generate certificate outputs (PDF \+ JPEG)  
  \- Upload outputs to S3  
  \- Store certificate metadata back into DynamoDB  
  \- Trigger WhatsApp sending step (Meta API integration occurs in later phase)

Deliverable:  
\- Lambda function deployed with environment variables and IAM permissions (least privilege)

\---

\#\#\# 1.4 AWS API Gateway (Application Integration)  
Purpose:  
\- Provide a secure HTTP interface to trigger backend operations (example):  
  \- Generate a certificate for a specific member  
  \- Retrieve certificate metadata for internal script use

Deliverable:  
\- API Gateway configured to invoke Lambda securely

\---

\#\# 2\. IAM Roles & Permissions (No CloudWatch)

\#\#\# 2.1 Why IAM Is Needed  
AWS services do not automatically have permission to access other AWS services.

IAM roles/policies are required so that:  
\- Lambda can read/write to DynamoDB  
\- Lambda can upload/read objects in S3  
\- API Gateway can invoke Lambda

\---

\#\#\# 2.2 Required IAM Setup

\#\#\#\# A) Lambda Execution Role (Least Privilege)  
Must allow:  
\- \`dynamodb:GetItem\`, \`dynamodb:PutItem\`, \`dynamodb:UpdateItem\`, \`dynamodb:Query\` (as needed)  
\- \`s3:PutObject\`, \`s3:GetObject\` (scoped to the certificate bucket)

Deliverable:  
\- IAM role attached to Lambda with only the permissions required for this project

\#\#\#\# B) API Gateway → Lambda Permission  
Must allow:  
\- API Gateway to invoke the Lambda function

Deliverable:  
\- Lambda permission resource allowing invocation from the API Gateway execution ARN

\> Note: This phase intentionally excludes CloudWatch logging configuration.

\---

\#\# 3\. Terraform Deliverables

By the end of Phase 2, the repo should include:

\- Terraform root module (or environment folder)  
\- Separate Terraform files (recommended):  
  \- \`dynamodb.tf\`  
  \- \`s3.tf\`  
  \- \`lambda.tf\`  
  \- \`apigateway.tf\`  
  \- \`iam.tf\`  
  \- \`variables.tf\`  
  \- \`outputs.tf\`

\---

\#\# 4\. Phase 2 Completion Criteria

Phase 2 is complete when:

\- DynamoDB tables exist and are reachable  
\- S3 bucket exists and accepts uploads (private by default)  
\- Lambda is deployed and can access DynamoDB \+ S3 via IAM  
\- API Gateway can invoke Lambda successfully  
\- All infrastructure is reproducible using Terraform

\---

\*\*Status:\*\* Phase 2 – Infrastructure Setup Ready  
