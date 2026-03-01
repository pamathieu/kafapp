# Système Automatisé de Certificat WhatsApp KAFA

## Présentation du Projet

Le Système Automatisé de Certificat WhatsApp KAFA est une solution cloud qui génère des certificats officiels d’adhésion et les envoie directement aux membres via WhatsApp.

Le système :

- Collecte les informations de l’entreprise et du membre
- Génère un certificat officiel (PDF + JPEG)
- Stocke les certificats de manière sécurisée sur AWS
- Envoie le certificat au membre via l’API WhatsApp Cloud de Meta

Il n’y a pas de système de connexion ni de portail utilisateur.  
La livraison se fait exclusivement via WhatsApp.

---

# Architecture du Système

Administrateur → API Gateway → Lambda → DynamoDB  
                     ↓  
                     S3  
                     ↓  
                 API WhatsApp Meta → Membre  

---

# Phase 1 — Définition des Exigences et de l’Architecture

## Objectif

Définir la portée du système, les champs de données et l’architecture générale.

## Exigences Principales

### Informations de l’Entreprise (Statique)

- Nom de l’entreprise
- Numéro d’enregistrement
- Logo
- Adresse (Siège Social)
- Téléphone
- Email
- Site web
- Signataires autorisés
- Sceau officiel

### Informations du Membre (Dynamique)

- Nom complet
- Date de naissance
- Numéro d’identification
- Type d’identification
- Adresse
- Numéro d’adhérent
- Date d’adhésion
- Numéro de téléphone WhatsApp (Obligatoire)

### Exigences du Certificat

- Injecter les données dynamiques dans le modèle officiel
- Préserver la mise en page
- Insérer automatiquement la date d’émission
- Générer :
  - Version PDF (officielle)
  - Version JPEG (aperçu)

### Exigence de Livraison

- Envoyer le certificat via WhatsApp
- Joindre le PDF ou un lien sécurisé S3
- Mettre à jour le statut d’envoi

---

# Phase 2 — Mise en Place de l’Infrastructure (Terraform)

## Objectif

Déployer toutes les ressources AWS nécessaires à l’aide de Terraform.

## Composants d’Infrastructure

### AWS DynamoDB
- Stocker les entreprises
- Stocker les membres
- Stocker les métadonnées des certificats

### AWS S3
- Stocker les certificats PDF générés
- Stocker les versions JPEG
- Bucket privé par défaut

### AWS Lambda
- Générer les certificats
- Télécharger les fichiers vers S3
- Mettre à jour DynamoDB
- Déclencher l’envoi WhatsApp

### AWS API Gateway
- Exposer les endpoints backend de manière sécurisée
- Invoquer la fonction Lambda

### Rôles IAM (Principe du Moindre Privilège)
- Accès Lambda à DynamoDB
- Accès Lambda à S3
- Permission API Gateway pour invoquer Lambda

> Remarque : La journalisation CloudWatch est volontairement exclue de cette phase.

---

# Phase 3 — Conception de la Base de Données

## Tables DynamoDB

### Table Entreprises
- company_id (PK)
- company_name
- registration_number
- address
- phone
- email
- website
- logo_s3_url

### Table Membres
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

### Table Certificats
- certificate_id (PK)
- member_id
- company_id
- issued_date
- pdf_s3_url
- jpeg_s3_url
- whatsapp_sent (booléen)
- timestamp

---

# Phase 4 — Moteur de Génération de Certificats

## Objectif

Développer la logique backend qui génère les certificats officiels.

## Processus

1. Récupérer les données du membre depuis DynamoDB
2. Récupérer les données de l’entreprise depuis DynamoDB
3. Injecter les données dans le modèle de certificat
4. Générer :
   - Version PDF
   - Version JPEG
5. Télécharger les fichiers vers S3
6. Enregistrer les métadonnées dans DynamoDB

## Outils Suggérés

- Python
- reportlab (génération PDF)
- PIL / Pillow (génération JPEG)
- boto3 (SDK AWS)

---

# Phase 5 — Intégration WhatsApp (API Meta)

## Objectif

Envoyer les certificats générés via WhatsApp.

## Étapes

1. Créer un compte développeur Meta
2. Configurer WhatsApp Cloud API
3. Générer un token d’accès
4. Enregistrer le numéro de téléphone
5. Créer un modèle de message

## Processus d’Envoi

Après génération du certificat :

- Appeler l’API WhatsApp de Meta
- Envoyer :
  - Le PDF en pièce jointe OU
  - Un lien sécurisé S3
- Mettre à jour le statut d’envoi dans DynamoDB

## Gestion des Erreurs

- Journaliser les échecs
- Implémenter un mécanisme de nouvelle tentative

---

# Phase 6 — Tests et Déploiement

## Tests

- Validation des opérations DynamoDB
- Validation des téléchargements S3
- Validation de l’exécution Lambda
- Validation de l’invocation API Gateway
- Validation de l’envoi WhatsApp
- Test complet de bout en bout

## Déploiement

- Déployer l’infrastructure via Terraform
- Déployer le code Lambda
- Configurer les variables d’environnement production
- Vérifier le fonctionnement complet

---

# Considérations de Sécurité

- Politiques IAM à privilèges minimaux
- Bucket S3 privé
- Configuration sécurisée d’API Gateway
- Protection des tokens Meta API

---

# Critères de Finalisation du Projet

Le projet est considéré comme terminé lorsque :

- Les certificats sont générés correctement (PDF + JPEG)
- Les certificats sont stockés dans S3
- Les métadonnées sont enregistrées dans DynamoDB
- L’envoi WhatsApp fonctionne correctement
- L’infrastructure est reproductible via Terraform
- Le système fonctionne de bout en bout sans intervention manuelle

---

# Améliorations Futures (Optionnelles)

- Tableau de bord administrateur
- Statistiques de livraison
- Numérotation automatique des certificats
- Support multilingue
- Journal d’audit

---

# Statut

Phase actuelle : Phases 1–6 définies et structurées  
Déploiement : En attente de mise en œuvre de l’infrastructure