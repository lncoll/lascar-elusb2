#!/usr/bin/env bash
# subir.sh — añade, commitea y sube los cambios del proyecto a GitHub.
# Uso: ./subir.sh ["mensaje del commit"]
#   Sin mensaje usa "Actualización <fecha>".
set -e
cd "$(dirname "$0")"

MSG="${1:-Actualización $(date '+%Y-%m-%d %H:%M')}"

if [ -z "$(git status --porcelain)" ]; then
  echo "No hay cambios que subir."
  exit 0
fi

echo "--- Cambios detectados:"
git status --short
echo
git add -A
git commit -m "$MSG"
git push
echo
echo "✔ Subido: $(git log -1 --oneline)"
