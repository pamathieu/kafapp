# System Architecture

## Overview

The system is built using a serverless AWS architecture.

---

## Components

### 1. API Gateway
Receives HTTP requests and triggers Lambda.

### 2. AWS Lambda
Handles:
- Data retrieval
- Certificate generation
- File upload
- WhatsApp API call
- Metadata update

### 3. DynamoDB
Stores:
- Companies
- Members
- Certificates

### 4. Amazon S3
Stores:
- PDF certificates
- JPEG certificates

### 5. Meta WhatsApp Cloud API
Handles certificate delivery.

---

## High-Level Flow

Admin → API Gateway → Lambda  
Lambda ↔ DynamoDB  
Lambda → S3  
Lambda → Meta API  
Meta API → WhatsApp User