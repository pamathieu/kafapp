# Non-Functional Requirements

## Security

- IAM least-privilege access
- Private S3 bucket
- Secure API Gateway configuration
- Protected Meta API tokens

---

## Scalability

- DynamoDB must support scaling
- Lambda must handle concurrent requests
- System should support future member growth

---

## Reliability

- Delivery failure logging
- Retry capability
- Idempotent certificate generation

---

## Performance

- Certificate generation under 5 seconds
- WhatsApp delivery within acceptable API latency

---

## Maintainability

- Infrastructure defined using Terraform
- Clear documentation
- Modular Lambda implementation