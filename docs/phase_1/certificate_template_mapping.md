# Certificate Template Mapping

This document maps certificate template placeholders to database fields.

---

## Company Fields

| Template Field | Database Field |
|---------------|---------------|
| Nom de l'entreprise | company_name |
| Numéro d'enregistrement | registration_number |
| Logo | logo_s3_url |
| Adresse | address |
| Téléphone | phone |
| Email | email |
| Site Web | website |

---

## Member Fields

| Template Field | Database Field |
|---------------|---------------|
| Nom et Prénom | full_name |
| Date de naissance | dob |
| No Identification | id_number |
| Type | id_type |
| Adresse | address |
| Numéro d’adhérent | member_number |
| Date d’adhésion | join_date |
| Date d’émission | issued_date |

---

## System Fields

| Template Field | Generated Value |
|---------------|----------------|
| Date d’émission | Auto-generated (current date) |
| Signature | Static company configuration |