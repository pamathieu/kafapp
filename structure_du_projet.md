
---

# 📘 VERSION FRANÇAISE COMPLÈTE (MISE À JOUR)

```markdown
# Système Automatisé de Certificat WhatsApp KAFA

## Présentation du Projet

Solution cloud permettant de générer des certificats officiels d’adhésion et de les envoyer directement aux membres via WhatsApp.

Aucun système de connexion.  
Livraison exclusivement via WhatsApp.

---

# Architecture du Système

Administrateur → API Gateway → Lambda → DynamoDB  
                     ↓  
                     S3  
                     ↓  
                 API WhatsApp Meta → Membre  

---

# Phase 3 — Conception de la Base de Données

## Table Entreprises

- company_id (PK)
- company_name
- registration_number
- address
- phone
- email
- website
- logo_s3_url

---

## Table Membres

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

### Objet Certificat Imbriqué

Chaque membre contient un attribut `certificate` de type Map.

Structure :

---

## Exemple d’Item DynamoDB

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

# Phase 4 — Moteur de Génération de Certificats

## Flux de Travail

1. Récupérer les données du membre depuis DynamoDB  
2. Récupérer les données de l’entreprise depuis DynamoDB  
3. Injecter les valeurs dans le modèle de certificat  
4. Générer :
   - PDF (reportlab)
   - JPEG (Pillow)  
5. Télécharger les fichiers vers Amazon S3  
6. Mettre à jour l’objet `certificate` imbriqué dans l’enregistrement du membre  
7. Déclencher l’envoi via WhatsApp  

---

## Technologies Suggérées

- Python  
- boto3  
- reportlab  
- Pillow (PIL)  

---

# Phase 5 — Intégration WhatsApp (API Cloud Meta)

## Exigences de Configuration

- Compte Développeur Meta  
- Application WhatsApp Business  
- Enregistrement du Numéro de Téléphone  
- Génération du Token d’Accès  
- Modèle de Message Approuvé  

---

## Logique de Livraison

Après la génération du certificat :

1. Appeler l’API WhatsApp de Meta  
2. Envoyer :
   - Le PDF en pièce jointe **OU**
   - Un lien sécurisé S3  
3. Mettre à jour le champ `whatsapp_sent` dans l’objet certificat  

---

## Gestion des Erreurs

- Capturer les erreurs de l’API  
- Mettre à jour l’état d’échec  
- Autoriser un mécanisme de nouvelle tentative  

---

# Phase 6 — Tests et Déploiement

## Tests

- Validation des lectures/écritures DynamoDB  
- Validation des téléchargements S3  
- Validation de l’exécution Lambda  
- Validation de l’invocation API Gateway  
- Validation de l’envoi WhatsApp  
- Test complet de bout en bout  

---

## Déploiement

- Déployer l’infrastructure via Terraform  
- Déployer le code Lambda  
- Configurer les variables d’environnement en production  
- Valider le flux complet de bout en bout  

---

# Considérations de Sécurité

- Politiques IAM à privilèges minimaux  
- Bucket S3 privé  
- Configuration sécurisée d’API Gateway  
- Protection des tokens d’accès Meta  
- Validation des entrées avant génération du certificat  

---

# Critères de Finalisation du Projet

Le projet est considéré comme terminé lorsque :

- Les certificats PDF + JPEG sont générés correctement  
- Les fichiers sont stockés dans S3  
- L’objet certificat est enregistré dans le dossier du membre  
- L’envoi WhatsApp est réussi  
- L’infrastructure est entièrement reproductible via Terraform  
- Le flux complet fonctionne de manière automatisée  

---

# Améliorations Futures (Optionnelles)

- Support multi-certificats (remplacer `certificate` par une liste `certificates`)  
- Tableau de bord administrateur  
- Statistiques de livraison  
- Numérotation automatique des certificats  
- Support multilingue  
- Journal d’audit  

---

# Statut

Phases 1–6 entièrement définies  
Implémentation : En attente du déploiement de l’infrastructure  