#!/usr/bin/env bash
# Fija en un overlay de un servicio las imágenes de backend y frontend POR DIGEST (ADR 0035:
# generalizado a cualquier servicio bajo apps/<servicio>/, antes solo valía para meridian-orders).
# Resuelve el digest de cada tag en GHCR (anónimo: las imágenes son públicas) y lo escribe con
# "kustomize edit". Lo usan las personas (primer despliegue) y el CD de cada servicio.
#
# Uso:  scripts/set-service-images.sh <servicio> <dev|staging|prod> <tag>
#       scripts/set-service-images.sh meridian-orders dev sha-267b8e8
#       scripts/set-service-images.sh meridian-orders staging 0.1.0
# Convención: el repo del servicio es elpalmeral-org/<servicio>, y sus imágenes
# ghcr.io/elpalmeral-org/<servicio>-backend / -frontend.
# Requisitos: curl, jq, kustomize.
set -euo pipefail

SERVICE="${1:?Uso: $0 <servicio> <dev|staging|prod> <tag>}"
ENV="${2:?Uso: $0 <servicio> <dev|staging|prod> <tag>}"
TAG="${3:?Uso: $0 <servicio> <dev|staging|prod> <tag>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OVERLAY="$ROOT/apps/$SERVICE/overlays/$ENV"
[[ -f "$OVERLAY/kustomization.yaml" ]] || { echo "No existe el overlay '$ENV' de '$SERVICE' ($OVERLAY)" >&2; exit 1; }

ACCEPT="application/vnd.oci.image.index.v1+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json"

digest_of() {
  local repo="elpalmeral-org/$SERVICE-$1" token
  token="$(curl -fsSL "https://ghcr.io/token?scope=repository:${repo}:pull" | jq -er .token)"
  curl -fsSI -H "Authorization: Bearer ${token}" -H "Accept: ${ACCEPT}" \
    "https://ghcr.io/v2/${repo}/manifests/${TAG}" \
    | tr -d '\r' | awk -F': ' 'tolower($1)=="docker-content-digest" {print $2}'
}

cd "$OVERLAY"
for app in backend frontend; do
  image="ghcr.io/elpalmeral-org/$SERVICE-${app}"
  digest="$(digest_of "$app")"
  [[ "$digest" == sha256:* ]] || { echo "No encuentro ${image}:${TAG} en GHCR" >&2; exit 1; }
  kustomize edit set image "${image}=${image}:${TAG}@${digest}"
  printf '%-9s %-14s %s\n' "$app" "$TAG" "$digest"
done
