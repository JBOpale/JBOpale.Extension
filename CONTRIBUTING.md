# Contribuer à JBOpale.Extensions

Règles de travail du dépôt, versionnées ici car `CLAUDE.md` est exclu par `.gitignore`. Les règles de tests, de paquets vulnérables et de couverture sont rappelées en en-tête de `.github/workflows/pr-tests.yml`.

## Règle : tout développement part de `dev`, jamais de `main`

- Le dépôt JBOpale.Extension a deux branches permanentes : `dev` (intégration) et `main` (production, publication NuGet par tag). `dev` est la branche par défaut du dépôt.
- Toute branche de travail (`feature/…`, `fix/…`, `claude/…`) est créée depuis `dev` à jour (`git fetch origin dev && git checkout -b <branche> origin/dev`), jamais depuis `main`, et sa PR cible `dev`.
- `main` ne reçoit que des PR `dev` → `main`, sur validation explicite de Jérôme. Aucun commit ni aucune branche de travail ne part de `main` (seule exception : un correctif urgent de production, sur demande explicite, ensuite reporté dans `dev`).
- Si une session démarre sur `main` ou sur une branche qui n'est pas basée sur `dev`, elle se rebase/recrée sur `origin/dev` avant le premier commit.
