# ZouChat Evolution — plan directeur

Version : 1.0  
Statut : conception et préparation technique  
Objectif : construire une messagerie originale visant une qualité supérieure à WhatsApp sur des critères mesurables, sans prétendre que cet objectif est déjà atteint.

## Vision
ZouChat doit viser l'excellence sur la fiabilité, la vitesse, l'accessibilité, la confidentialité, la qualité des appels, l'efficacité réseau, la facilité d'utilisation et la capacité à évoluer. « Dépasser WhatsApp sur tous les points » est une ambition à long terme : chaque domaine doit avoir des objectifs mesurables, des tests et des preuves avant toute affirmation de supériorité.

## Principes non négociables
- Construire un produit original. Utiliser les comportements et documentations publics comme références, sans copier le code, la marque, les logos ou les ressources propriétaires de WhatsApp.
- Ne jamais déclarer une fonction terminée sans test réel.
- Ne jamais exposer de clé API, jeton GitHub ou clé Supabase privilégiée dans l'application cliente.
- Ne jamais laisser l'IA modifier ou publier silencieusement la production.
- Les migrations de base de données, changements RLS, actions destructrices et déploiements nécessitent une validation explicite.
- L'IA doit distinguer faits confirmés, hypothèses et éléments non testés.
- Les conversations privées ne doivent pas servir de données d'entraînement par défaut.

## Architecture cible

### Application
- Application web mobile actuelle et emballage Android.
- Interface accessible, prise en charge des connexions faibles, chargement progressif des conversations et médias.
- Fonctionnalités regroupées par modules afin de réduire les régressions.

### Données et services
- Supabase Auth pour les sessions.
- PostgreSQL avec RLS pour imposer l'accès par propriétaire/membre.
- Supabase Storage avec politiques d'accès pour les médias privés.
- Realtime seulement pour les événements nécessaires.
- Backend HTTPS pour les opérations privilégiées, les notifications et l'IA.
- WebRTC pour les appels, avec signalisation authentifiée et gestion des erreurs réseau.

### Moteur ZouChat Evolution
- Fournir un assistant IA depuis un backend, jamais avec une clé secrète dans index.html.
- Connaissance : documentation publique sélectionnée, documentation technique du dépôt et résultats de tests versionnés.
- Lecture du code avec accès GitHub limité au seul dépôt.
- Modifications dans une branche isolée ; patch/diff affiché ; tests automatisés ; revue et validation avant fusion/déploiement.
- Limites d'usage, authentification, journalisation sans secrets, et garde-fous contre les instructions malveillantes contenues dans les fichiers ou les messages.
- Pas de modification autonome des règles de sécurité, secrets, comptes, messages de production ou paramètres de facturation.

## Plan par phases

### Phase 0 — Audit de base
- Vérifier la structure réelle du dépôt, les scripts de test et le workflow de compilation Android.
- Examiner les tables Supabase, les politiques RLS et les alertes du Security Advisor.
- Établir une liste de fonctions qui marchent réellement, celles qui sont partielles et celles qui manquent.
- Mesurer le poids initial, le temps de chargement, les erreurs et le comportement hors ligne.

Critère de sortie : audit documenté avec preuves, sans toucher aux données de production.

### Phase 1 — Sécurité et fiabilité
- Vérifier que chaque conversation est accessible uniquement à ses membres.
- Contrôler les politiques des profils, messages, statuts, reçus de lecture, groupes et médias.
- Vérifier validation serveur, limitation de débit, gestion d'erreurs et récupération de session.
- Ajouter tests de permissions et tests des flux critiques.

Critère de sortie : aucune fuite de données dans les tests de permissions connus ; alertes restantes documentées.

### Phase 2 — Messagerie solide
- Envoi/réception en temps réel, ordre et horodatages cohérents.
- Accusés d'envoi/livraison/lecture avec paramètres de confidentialité explicites.
- Pagination, recherche, suppression et gestion des erreurs réseau.
- Médias avec validation de format, taille et autorisations.

Critère de sortie : scénarios de bout en bout testés sur au moins deux comptes et plusieurs sessions.

### Phase 3 — Fonctions sociales
- Profils, recherche par nom d'utilisateur, statuts temporaires, groupes et rôles.
- Invitations, gestion des membres, blocage/signalement et modération autorisée.
- Contrôles d'accès vérifiés par tests.

### Phase 4 — Appels et notifications
- Appels audio/vidéo WebRTC, permissions, sonnerie, refus, fin d'appel et reconnexion.
- Notifications push via backend.
- Tests réseau et appareil réels ; documentation des limites.

### Phase 5 — Performance et qualité
- Mesurer latence, consommation de données, taille de l'application, démarrage, consommation mémoire et stabilité.
- Tests de charge réalistes et protection anti-abus.
- Optimiser à partir des mesures, pas des impressions.
- Comparaisons avec des références publiques et des appareils/réseaux comparables.

### Phase 6 — IA d'ingénierie
- Déployer une fonction backend sécurisée.
- Configurer les secrets dans les paramètres serveur.
- Authentifier et autoriser les utilisateurs.
- Connecter un modèle IA et une lecture limitée du dépôt.
- Ajouter génération de patchs dans une branche, tests, résumé de risques et demande de validation.
- Commencer en mode lecture/proposition ; n'autoriser l'écriture qu'après tests de sécurité.

### Phase 7 — Exploitation à grande échelle
- Sauvegardes et procédure de restauration vérifiées.
- Surveillance des erreurs, alertes et réponse aux incidents.
- Déploiement progressif, retour arrière et migrations compatibles.
- Tests de montée en charge avant d'accueillir un grand nombre d'utilisateurs.

## Tableau de mesure
Les valeurs de référence doivent être mesurées avant de fixer les objectifs finaux.

| Domaine | Indicateur |
| --- | --- |
| Fiabilité | taux d'envoi réussi, erreurs, disponibilité |
| Vitesse | temps d'ouverture, latence d'envoi/réception |
| Réseau | données consommées par session, reprise après coupure |
| Appels | taux de connexion, qualité audio/vidéo, interruptions |
| Sécurité | tests RLS, alertes, résultats d'audit |
| Évolutivité | capacité testée, latence sous charge |
| Expérience | taux de réussite des tâches, retours des testeurs |
| Maintenance | tests automatisés, fréquence des régressions, temps de correction |

## État honnête au démarrage
Les documents de conception existent, mais le moteur IA n'est pas encore actif. Aucun score ne prouve que ZouChat dépasse WhatsApp. Les fonctions existantes doivent être auditées et testées avant d'être considérées comme fiables. Le premier livrable est un audit vérifiable du dépôt et de la configuration Supabase, puis les corrections les plus prioritaires.
