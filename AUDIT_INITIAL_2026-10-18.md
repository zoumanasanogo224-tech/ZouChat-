# Audit initial de ZouChat — 18 octobre 2026

## Portée
Lecture des métadonnées du projet Supabase, des migrations connues, des fonctions Edge déclarées et des résultats du Security Advisor et du Performance Advisor. Cet audit n'est pas un audit d'intrusion ni un test complet de l'application.

## État observé
- Projet Supabase : `rollxrixddvgpkgidlja`, région `eu-west-1`, statut annoncé `ACTIVE_HEALTHY`.
- Migrations présentes : sécurité médias/appels, signalements/modération/bannissements, fondation du gardien IA, approbation de propositions IA, profils/avatars, groupes, statuts et accusés de lecture.
- Fonction Edge `zouchat-ai-guardian` : déclarée active, JWT requis, mais son code répond actuellement HTTP 410 `feature_disabled`. Elle n'est donc pas un moteur IA utilisable dans cet état.

## Alertes sécurité à examiner avant la croissance
Le Security Advisor rapporte :
- 4 tables avec RLS activé mais sans politique : `zouchat_admins`, `zouchat_bans`, `zouchat_moderation_actions`, `zouchat_reports`.
- 15 fonctions `SECURITY DEFINER` exécutables par des utilisateurs authentifiés. Ce n'est pas automatiquement une vulnérabilité : chaque fonction doit être inspectée pour confirmer qu'elle vérifie les permissions et ne révèle aucune donnée ou action privilégiée.
- Les politiques RLS et les fonctions RPC de groupes, conversations, signalements et modération doivent être testées avec plusieurs comptes et des accès non autorisés.

**Important :** l'absence de politique RLS signifie que les accès directs via les rôles concernés peuvent être refusés, mais il ne faut pas conclure que toutes les données sont exposées. Les fonctions privilégiées peuvent toutefois présenter un risque si elles ne contrôlent pas correctement l'identité et les permissions. Ne pas modifier les politiques à l'aveugle.

## Alertes de performance
Le Performance Advisor signale 12 clés étrangères sans index couvrant et 5 politiques RLS susceptibles de réévaluer des appels d'authentification pour chaque ligne. Cela peut ralentir les requêtes quand les tables grossissent. Il faut vérifier les index existants et les plans de requête avant toute migration, puis mesurer l'amélioration.

## Première liste d'actions
1. Lire les définitions SQL des fonctions `SECURITY DEFINER` et des politiques RLS avant de modifier les permissions.
2. Vérifier le modèle de sécurité de `zouchat_reports`, `zouchat_bans`, `zouchat_admins` et `zouchat_moderation_actions`.
3. Ajouter des tests de permissions : utilisateur A ne doit pas lire les messages, signalements ou reçus privés de B sans autorisation.
4. Examiner les index recommandés et préparer une migration additive, puis mesurer les plans de requête.
5. Concevoir un nouveau moteur IA backend en mode proposition seulement, avec authentification, limitation d'usage, clés côté serveur et tests.
6. Réactiver les capacités IA seulement après configuration et vérification de tous les secrets requis.

## Limites
- Aucun secret n'a été lu ni exposé.
- Aucune politique, table ou donnée de production n'a été modifiée dans cet audit.
- Les alertes proviennent des outils de diagnostic à la date indiquée et doivent être revalidées après les corrections.
- Aucun test de charge ou test de bout en bout Android n'a encore été effectué.
