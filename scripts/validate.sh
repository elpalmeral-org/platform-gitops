#!/usr/bin/env bash
# Validación de platform-gitops: la ejecuta el check gitops-ok en cada PR y se puede lanzar en local.
#
#   scripts/validate.sh [ref-base]        # ref-base por defecto: origin/main
#
# Reglas (por CADA servicio bajo apps/<servicio>/, ADR 0035 — un solo servicio es el caso N=1):
#   1. Los scripts pasan shellcheck.
#   2. Un entorno ACTIVO en el ApplicationSet (addons/<servicio>.yaml) tiene sus imágenes fijadas
#      POR DIGEST. Un overlay sin imágenes es un entorno aún no dado de alta: se omite.
#   3. staging y prod solo llevan versiones X.Y.Z (nada de sha-<commit>).
#   4. Todos los manifiestos (addons, config, overlays renderizados) son válidos según su esquema
#      (kubeconform, con los CRD del catálogo de Datree).
#   5. Si el PR cambia prod de un servicio, ese prod queda con los MISMOS digests que su staging.
#   6. Cada imagen fijada está firmada por publish.yml en main del repo del servicio (cosign,
#      asume convención repo == nombre de la carpeta en apps/). En local, sin cosign, se avisa y
#      se omite; en CI es obligatorio.
# Requisitos: kustomize, kubeconform; shellcheck y cosign opcionales en local.
set -euo pipefail

BASE_REF="${1:-origin/main}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CATALOG='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

errors=0
ok()   { echo "  ✅ $*"; }
warn() { echo "  ⚠️  $*"; if [[ -n "${CI:-}" ]]; then echo "::warning::$*"; fi; }
fail() { echo "  ❌ $*"; if [[ -n "${CI:-}" ]]; then echo "::error::$*"; fi; errors=$((errors + 1)); }

# Imágenes de un manifiesto renderizado (sin yq: igual en el Mac que en el runner)
rendered_images() {
  grep -E '^[[:space:]-]*image:' "$1" | sed -E 's/^[[:space:]-]*image:[[:space:]]*//; s/["'\'']//g' | sort -u
}

# Imágenes fijadas de un overlay, normalizadas para comparar (digest + tag)
images_of() {
  sed -n '/^images:/,$p' "$1/overlays/$2/kustomization.yaml" \
    | grep -E '^[- ]*(digest|newTag):' | sed -E 's/^[- ]*//' | sort
}

echo "== 1 · shellcheck"
if command -v shellcheck >/dev/null; then
  if shellcheck scripts/*.sh; then ok "scripts/*.sh"; else fail "shellcheck"; fi
else
  warn "shellcheck no instalado: omitido"
fi

# Sin mapfile ni arrays vacíos: el script corre también con el bash 3.2 de macOS
services=""
for dir in apps/*/; do
  services="$services $(basename "$dir")"
done
if [[ -z "${services// /}" ]]; then fail "no encuentro ningún servicio bajo apps/"; fi

for service in $services; do
  echo "== servicio: $service =="
  SERVICE_DIR="apps/$service"
  APPSET="addons/$service.yaml"
  SIGNER="https://github.com/elpalmeral-org/$service/.github/workflows/publish.yml@refs/heads/main"

  if [[ ! -f "$APPSET" ]]; then
    fail "$service: no encuentro $APPSET (todo servicio en apps/ necesita su ApplicationSet)"
    continue
  fi

  echo "== 2·3 · overlays"
  active="$(grep -E '^[[:space:]]*- env:[[:space:]]*[a-z]+' "$APPSET" | awk '{print $3}' | tr '\n' ' ')"
  if [[ -z "${active// /}" ]]; then fail "$service: no encuentro entornos activos en $APPSET"; else ok "$service: activos en el ApplicationSet: $active"; fi

  pinned=""
  for dir in "$SERVICE_DIR/overlays"/*/; do
    env="$(basename "$dir")"
    is_active=false
    if [[ " $active " == *" $env "* ]]; then is_active=true; fi

    if ! grep -q 'digest: sha256:' "$dir/kustomization.yaml"; then
      if $is_active; then fail "$service/$env está activo pero no tiene imágenes fijadas"; else ok "$service/$env: sin imágenes (no dado de alta) · omitido"; fi
      continue
    fi

    if ! kustomize build "$dir" > "$OUT/$service-$env.yaml"; then
      fail "$service/$env: kustomize build falla"; continue
    fi
    pinned="$pinned $env"

    count=0
    while read -r image; do
      count=$((count + 1))
      [[ "$image" == *@sha256:* ]] || fail "$service/$env: imagen sin digest: $image"
    done < <(rendered_images "$OUT/$service-$env.yaml")
    if (( count == 0 )); then fail "$service/$env: el render no contiene imágenes"; fi

    if [[ "$env" =~ ^(staging|prod)$ ]]; then
      while read -r tag; do
        [[ "$tag" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "$service/$env: solo admite X.Y.Z y tiene '$tag'"
      done < <(sed -nE 's/^[[:space:]]*newTag:[[:space:]]*//p' "$dir/kustomization.yaml" | sort -u)
    fi
    ok "$service/$env: renderiza y todo va por digest ($count imágenes)"
  done

  echo "== 5 · prod = staging ($service)"
  if git rev-parse --verify --quiet "$BASE_REF" >/dev/null \
    && git diff --name-only "$BASE_REF"...HEAD | grep -q "^$SERVICE_DIR/overlays/prod/"; then
    if diff <(images_of "$SERVICE_DIR" staging) <(images_of "$SERVICE_DIR" prod); then
      ok "$service: prod lleva exactamente los digests de staging"
    else
      fail "$service: el PR cambia prod con digests que no están en staging"
    fi
  else
    ok "$service: el PR no toca prod"
  fi

  echo "== 6 · firmas ($service, cosign)"
  if command -v cosign >/dev/null; then
    for env in $pinned; do
      while read -r image; do
        if cosign verify "$image" --certificate-identity "$SIGNER" \
          --certificate-oidc-issuer https://token.actions.githubusercontent.com >/dev/null 2>&1; then
          ok "$service/$env: firmada · ${image##*/}"
        else
          fail "$service/$env: firma NO válida · $image"
        fi
      done < <(rendered_images "$OUT/$service-$env.yaml")
    done
  elif [[ -n "${CI:-}" ]]; then
    fail "cosign es obligatorio en CI"
  else
    warn "cosign no instalado: firmas no verificadas"
  fi
done

echo "== 4 · esquemas (kubeconform)"
manifests=()
while read -r f; do manifests+=("$f"); done < <(find addons config bootstrap -name '*.yaml' ! -name 'argocd-values.yaml' | sort)
if kubeconform -summary -ignore-missing-schemas \
  -schema-location default -schema-location "$CATALOG" \
  "${manifests[@]}" "$OUT"/*.yaml; then
  ok "manifiestos válidos"
else
  fail "kubeconform"
fi

echo
if (( errors > 0 )); then echo "❌ $errors error(es)"; exit 1; fi
echo "✅ platform-gitops válido"
