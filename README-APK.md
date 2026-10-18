# ZouChat Android APK

Le projet Android se trouve dans `android/`. Il utilise une WebView sécurisée qui charge la version web hébergée ici :

https://zoumanasanogo224-tech.github.io/ZouChat-/

## Compilation automatique

À chaque modification pertinente sur `main`, GitHub Actions compile une APK Android de test et publie :
- un artefact téléchargeable dans l'exécution du workflow ;
- une version téléchargeable dans GitHub Releases.

Le workflow peut aussi être lancé manuellement depuis l'onglet **Actions** avec **Build ZouChat Android APK** puis **Run workflow**.

## Mises à jour

Le contenu web est chargé depuis l'adresse en ligne : les mises à jour de `index.html` deviennent disponibles aux utilisateurs sans nouvelle installation de l'APK. Les modifications du code Android, du nom d'application ou des permissions nécessitent de reconstruire et réinstaller une nouvelle APK.

## Important

Cette APK initiale est une version de test signée avec la clé de débogage fournie par Android Gradle Plugin. Avant une distribution publique durable, il faut configurer une clé de signature de publication privée et la sauvegarder en sécurité. Ne jamais committer la clé de signature ni les mots de passe dans le dépôt.
