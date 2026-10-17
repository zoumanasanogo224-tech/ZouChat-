# ZouChat AI Guardian

## Ce qui est en place

- Fonction Edge Supabase `zouchat-ai-guardian`, protégée par une session valide et un contrôle administrateur pour les actions privilégiées.
- Résumés d'erreurs JavaScript envoyés sans collecter le contenu des messages ni les mots de passe.
- Historique des événements et propositions IA stockés dans des tables protégées par RLS.
- Contrôles GitHub sur chaque changement, pull request et exécution planifiée quotidienne : syntaxe du JavaScript et détection simple de secrets accidentellement committés.
- L'IA peut préparer une proposition sous forme de patch. Après ton approbation dans le panneau Gardien IA, elle peut créer une branche et une pull request **brouillon** sur GitHub.
- La PR n'est jamais fusionnée ni déployée automatiquement. Tu dois examiner le diff, vérifier les tests, puis décider séparément de la fusion.

## Activer les services externes

Les clés ne sont pas incluses dans le dépôt et ne doivent jamais être publiées dans `index.html`, le SQL ou cette conversation.

1. Dans le tableau de bord Supabase du projet `rollxrixddvgpkgidlja`, ouvre **Edge Functions → Secrets**.
2. Ajoute `OPENAI_API_KEY) avec une clé de l'API OpenAI. Les appels API peuvent générer des frais distincts de ChatGPT.
3. Crée un jeton GitHub fine-grained limité au dépôt `zoumanasanogo224-tech/ZouChat-`, avec **Contents: Read and write** et **Pull requests: Read and write**.
4. Ajoute ce jeton comme secret Supabase nommé `GITHUB_TOKEN`.
5. Dans ZouChat, déconnecte-toi/reconnecte-toi si nécessaire, puis ouvre **Gardien IA**. Clique sur **Vérifier** pour confirmer la configuration.
6. Clique sur **Analyser les erreurs**. Examine le résumé et le patch. Le bouton d'approbation crée uniquement une branche et une PR brouillon.
7. Vérifie la PR et les contrôles GitHub. Aucun changement ne doit être fusionné ou déployé sans ton accord.

## Limites et sécurité

- Sans `OPENAI_API_KEY`, le suivi technique et les contrôles GitHub fonctionnent, mais l'analyse IA est désactivée.
- Sans `GITHUB_TOKEN`, l'IA peut proposer un patch mais ne peut pas créer de PR après approbation.
- Les propositions de code sont limitées au fichier `index.html` dans cette première version. Les patchs qui ne s'appliquent plus au code actuel sont rejetés.
- Le workflow GitHub vérifie la syntaxe et cherche quelques motifs de clés privées; il ne prouve pas que l'application fonctionne dans un navigateur réel.
- Ce système n'est pas une garantie de surveillance 24 h/24. Les tests d'intégration et la revue humaine restent nécessaires.
