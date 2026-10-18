# ZouChat Evolution — feuille de route de parité fonctionnelle

## But
Faire évoluer ZouChat vers une messagerie originale offrant progressivement les fonctions attendues d'une application moderne comme WhatsApp, en se basant sur les comportements et documentations publics. Cette feuille de route ne suppose aucun accès aux systèmes internes ou au code privé de WhatsApp.

## Règle de travail de l'IA
Pour chaque évolution, l'assistant doit :
1. inspecter le code actuel et les schémas Supabase concernés ;
2. identifier le problème ou la fonctionnalité et ses risques ;
3. préparer un changement limité, accompagné d'un diff lisible ;
4. lancer les tests disponibles et ajouter des tests pertinents ;
5. signaler clairement ce qui a été vérifié et ce qui reste à tester ;
6. demander une validation avant toute publication en production.

## Priorités proposées

### P0 — Fiabilité et sécurité
- vérifier l'authentification, les règles RLS Supabase et les droits par utilisateur ;
- protéger les clés et jetons exclusivement côté serveur ;
- vérifier les permissions d'accès aux conversations, profils, médias et signalements ;
- traiter les erreurs réseau, les reconnexions et les états de chargement ;
- ajouter des tests pour les flux de connexion et d'envoi/réception de messages.

### P1 — Expérience de messagerie
- conversations triées par activité, aperçu du dernier message et horodatage ;
- états d'envoi, de livraison et de lecture cohérents avec les paramètres de confidentialité ;
- édition/suppression avec règles claires, réponses et transfert si prévu ;
- recherche de conversations et de messages ;
- pièces jointes avec validation du type, de la taille et des droits d'accès.

### P2 — Fonctions sociales
- profils et photos, recherche fiable par nom d'utilisateur ;
- statuts temporaires expirant après 24 heures ;
- groupes avec rôles, invitations, ajout/retrait de membres et contrôles d'accès ;
- signalements et modération réservée aux administrateurs autorisés.

### P3 — Appels et notifications
- appels audio/vidéo WebRTC avec gestion des autorisations, états d'appel et erreurs ;
- notifications push via un service serveur, sans exposer les secrets ;
- tests sur différents réseaux et appareils Android.

### P4 — Confidentialité et performances
- paramètres de confidentialité et de visibilité ;
- stratégie de sauvegarde/récupération clairement documentée ;
- pagination des messages, optimisation des images et limitation des requêtes ;
- évaluation de sécurité indépendante avant un déploiement à grande échelle.

## Limites et critères
- Ne pas promettre le chiffrement de bout en bout tant qu'un protocole éprouvé n'est pas correctement intégré et audité.
- Ne pas annoncer une fonction comme opérationnelle sans test réel.
- Ne pas copier la marque, les logos, les ressources graphiques ou le code propriétaire de WhatsApp.
- Les changements destructifs, les changements de politiques de sécurité et les déploiements de production nécessitent une validation explicite.

## Activation du moteur IA
Le dépôt est hébergé sur GitHub Pages, qui sert des fichiers statiques et ne doit pas contenir de clé API. Pour un moteur IA fonctionnel, déployer un backend HTTPS, configurer les secrets côté serveur, limiter l'accès au propriétaire autorisé, appliquer des limites d'utilisation et tester sur une branche dédiée avant de connecter l'interface.
