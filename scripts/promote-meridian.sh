#!/usr/bin/env bash
# Promociona Meridian Orders a un entorno abriendo un PR en platform-gitops.
#
#   scripts/promote-meridian.sh <dev|staging|prod> <tag> [--merge]
#
#   dev      tag sha-<commit> · con --merge activa el auto-merge y espera a que se fusione
#   staging  tag X.Y.Z        · el PR lo fusiona una persona
#   prod     tag X.Y.Z        · solo si staging tiene YA esos mismos digests; lo fusiona una persona
#
# Pasos: fija los digests (set-meridian-images.sh) → si no cambia nada, sale → rama
# promote/<env>-<tag> → commit → PR → cierra PR anteriores del mismo entorno (el último gana).
#
# Lo lanzan los workflows de meridian-orders con un token de la GitHub App en GH_TOKEN;
# la regla de promoción vive aquí, en la plataforma, no en el pipeline de la app.
# Requisitos: git, gh, curl, jq, kustomize.
set -euo pipefail

usage="Uso: $0 <dev|staging|prod> <tag> [--merge]"
ENV="${1:?$usage}"
TAG="${2:?$usage}"
MERGE="${3:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OVERLAYS="apps/meridian-orders/overlays"
FILE="$OVERLAYS/$ENV/kustomization.yaml"
cd "$ROOT"

die() { echo "::error::$*" >&2; exit 1; }

case "$ENV" in
  dev) [[ "$TAG" =~ ^sha-[0-9a-f]{7}$ ]] || die "dev solo acepta sha-<commit>: $TAG" ;;
  staging | prod) [[ "$TAG" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "$ENV solo acepta versiones X.Y.Z: $TAG" ;;
  *) die "Entorno no válido: $ENV" ;;
esac
[[ -z "$MERGE" || "$MERGE" == "--merge" ]] || die "Tercer argumento no válido: $MERGE"
[[ "$MERGE" != "--merge" || "$ENV" == "dev" ]] || die "Solo dev se fusiona automáticamente"

# Imágenes fijadas de un overlay, normalizadas para comparar (digest + tag)
images_of() {
  sed -n '/^images:/,$p' "$OVERLAYS/$1/kustomization.yaml" \
    | grep -E '^[- ]*(digest|newTag):' | sed -E 's/^[- ]*//' | sort
}

"$ROOT/scripts/set-meridian-images.sh" "$ENV" "$TAG"

if [[ "$ENV" == "prod" ]] && ! diff <(images_of staging) <(images_of prod) >/dev/null; then
  git checkout -- "$FILE"
  die "prod solo recibe lo que ya está en staging, y staging no está en $TAG. Promociona antes a staging."
fi

if git diff --quiet -- "$FILE"; then
  echo "El entorno $ENV ya está en $TAG: nada que promocionar."
  exit 0
fi

branch="promote/${ENV}-${TAG}"
title="chore(${ENV}): meridian-orders ${TAG}"
body="$(cat <<EOF
Promoción de **meridian-orders** a **${ENV}** con \`${TAG}\`.

Imágenes por digest, firmadas con cosign por \`publish.yml\` en \`main\`. El check \`gitops-ok\`
vuelve a verificar las firmas antes de que se pueda fusionar.

\`\`\`diff
$(git diff --unified=0 -- "$FILE" | grep -E '^[+-] ' || true)
\`\`\`

Origen: ${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-local}/actions/runs/${GITHUB_RUN_ID:-0}
EOF
)"

git switch -C "$branch"
git add "$FILE"
git commit -m "$title"
git push --force origin "$branch"

url="$(gh pr list --head "$branch" --state open --json url --jq '.[0].url // empty')"
if [[ -z "$url" ]]; then
  url="$(gh pr create --base main --head "$branch" --title "$title" --body "$body")"
fi
echo "PR: $url"

# El último gana: cierra promociones anteriores del mismo entorno que sigan abiertas
gh pr list --state open --json url,headRefName \
  --jq ".[] | select(.headRefName | startswith(\"promote/${ENV}-\")) | select(.headRefName != \"${branch}\") | .url" \
  | while read -r old; do
      [[ -n "$old" ]] || continue
      gh pr close "$old" --delete-branch --comment "Sustituido por $url"
    done

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  echo "### ${ENV} → \`${TAG}\` · [PR]($url)" >> "$GITHUB_STEP_SUMMARY"
fi

[[ "$MERGE" == "--merge" ]] || exit 0

# dev: se fusiona solo en cuanto pase gitops-ok. Esperamos para que, si la plataforma
# rechaza el cambio, el pipeline de la app se ponga en rojo y lo veas donde trabajas.
gh pr merge "$url" --auto --squash --delete-branch
for _ in $(seq 1 60); do
  state="$(gh pr view "$url" --json state --jq .state)"
  case "$state" in
    MERGED) echo "Fusionado: Argo CD desplegará $TAG en $ENV."; exit 0 ;;
    CLOSED) die "El PR se cerró sin fusionar: $url" ;;
  esac
  sleep 10
done
gh pr checks "$url" || true
die "El PR no se fusionó en 10 minutos (¿gitops-ok en rojo?): $url"
