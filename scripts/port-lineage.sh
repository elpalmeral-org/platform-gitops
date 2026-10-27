#!/usr/bin/env bash
# Linaje de lo APROBADO en Port (F3.4a · ADR 0020 del agentic-platform-lab).
#
#   scripts/port-lineage.sh state [entorno…]   sincroniza build y workload (sin eventos)
#   scripts/port-lineage.sh deployment         además registra un deployment "Pending" por cada
#                                             entorno que cambió en el último commit de main
#
# Para cada imagen fijada en un overlay:
#   build     meridian-orders-<componente>-<hex del digest>   firma verificada AQUÍ con cosign
#   workload  meridian-orders-<componente>-<entorno>          version, approved_digest, url → build
# Y por cada promoción (modo deployment):
#   deployment meridian-orders-<entorno>-<tag>                Pending; lo cierra Argo CD (F3.4d)
#
# Lo lanza .github/workflows/port-lineage.yml. Requisitos: git, jq, gh; cosign opcional.
# Credenciales: PORT_CLIENT_ID / PORT_CLIENT_SECRET · GH_TOKEN para leer PR y aprobaciones.
set -euo pipefail

MODE="${1:?Uso: $0 <state|deployment> [entorno…]}"
shift || true
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OVERLAYS="apps/meridian-orders/overlays"
SERVICE="meridian-orders"
APP_REPO="elpalmeral-org/meridian-orders"
SIGNER="https://github.com/$APP_REPO/.github/workflows/publish.yml@refs/heads/main"
PORT_ENTITY="$ROOT/.github/actions/port-entity/port-entity.sh"

dora_label() { case "$1" in dev) echo Development ;; staging) echo Staging ;; prod) echo Production ;; *) echo "" ;; esac; }

# nombre<TAB>tag<TAB>digest de cada imagen fijada (sin yq: vale igual en el Mac y en el runner)
images_tsv() {
  sed -n '/^images:/,$p' "$OVERLAYS/$1/kustomization.yaml" | awk '
    /^- /    { if (n != "") print n "\t" t "\t" d; n = ""; t = ""; d = ""; sub(/^- /, "  ") }
    /^  digest:/ { d = $2 }
    /^  name:/   { n = $2 }
    /^  newTag:/ { t = $2 }
    END      { if (n != "") print n "\t" t "\t" d }'
}

host_of() { awk '/path: \/spec\/rules\/0\/host/ { getline; print $2; exit }' "$OVERLAYS/$1/kustomization.yaml"; }

gh_q() { gh api "$@" 2>/dev/null || true; } # lecturas de contexto: si fallan, el campo queda vacío

case "$MODE" in
  state)
    if (( $# > 0 )); then envs="$*"; else envs="$(ls "$OVERLAYS")"; fi ;;
  deployment)
    envs="$(git diff --name-only HEAD~1 HEAD -- "$OVERLAYS" | cut -d/ -f4 | sort -u | tr '\n' ' ')" ;;
  *) echo "Modo no válido: $MODE" >&2; exit 1 ;;
esac

for env in $envs; do
  [[ -f "$OVERLAYS/$env/kustomization.yaml" ]] || continue
  tsv="$(images_tsv "$env")"
  if [[ -z "$tsv" ]]; then echo "· $env: sin imágenes fijadas, se omite"; continue; fi
  host="$(host_of "$env")"
  echo "== $env ($host)"

  builds="[]" workloads="[]" build_ids="[]" env_tag=""
  while IFS=$'\t' read -r name tag digest; do
    env_tag="$tag" # el read final (EOF) vacía las variables: se guarda aquí
    component="${name##*/meridian-orders-}"
    build_id="$SERVICE-$component-${digest#sha256:}"
    signed=null
    if command -v cosign >/dev/null; then
      if cosign verify "$name@$digest" --certificate-identity "$SIGNER" \
        --certificate-oidc-issuer https://token.actions.githubusercontent.com >/dev/null 2>&1; then
        signed=true
      else
        signed=false
      fi
    fi
    builds="$(jq -c --arg id "$build_id" --arg img "$name@$digest" --arg tag "$tag" --arg c "$component" \
      --argjson signed "$signed" --arg svc "$SERVICE" \
      '. + [{identifier: $id, title: ($c + " " + $tag),
             properties: ({image: $img, tag: $tag, component: $c} + (if $signed == null then {} else {signed: $signed} end)),
             relations: {service: $svc}}]' <<<"$builds")"
    workloads="$(jq -c --arg id "$SERVICE-$component-$env" --arg tag "$tag" --arg digest "$digest" \
      --arg url "https://$host" --arg b "$build_id" --arg env "$env" --arg svc "$SERVICE" --arg c "$component" \
      '. + [{identifier: $id,
             properties: {version: $tag, approved_digest: $digest, component: $c, url: $url},
             relations: {build: $b, service: $svc, environment: $env}}]' <<<"$workloads")"
    build_ids="$(jq -c --arg b "$build_id" '. + [$b]' <<<"$build_ids")"
  done <<<"$tsv"

  "$PORT_ENTITY" build "$builds"
  "$PORT_ENTITY" workload "$workloads" --create-missing

  [[ "$MODE" == "deployment" ]] || continue

  # --- el evento de promoción ---
  tag="$env_tag"
  repo="${GITHUB_REPOSITORY:-elpalmeral-org/platform-gitops}"
  sha="${GITHUB_SHA:-$(git rev-parse HEAD)}"
  pr="$(gh_q "repos/$repo/commits/$sha/pulls" --jq '.[0].number // empty')"
  merged_by="" approved_by="" pr_url="" code_pr=""
  if [[ -n "$pr" ]]; then
    pr_json="$(gh_q "repos/$repo/pulls/$pr")"
    [[ -n "$pr_json" ]] || pr_json='{}'
    merged_by="$(jq -r '.merged_by.login // empty' <<<"$pr_json")"
    pr_url="$(jq -r '.html_url // empty' <<<"$pr_json")"
    run_id="$(jq -r '.body // ""' <<<"$pr_json" | grep -oE 'actions/runs/[0-9]+' | head -1 | cut -d/ -f3 || true)"
    if [[ "$env" == "prod" && -n "$run_id" ]]; then
      approved_by="$(gh_q "repos/$APP_REPO/actions/runs/$run_id/approvals" \
        --jq '[.[] | select(.state == "approved") | .user.login] | unique | join(", ")')"
    fi
  fi
  ref="$tag"; [[ "$tag" =~ ^sha-([0-9a-f]{7})$ ]] && ref="${BASH_REMATCH[1]}"; [[ "$tag" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && ref="v$tag"
  code_sha="$(gh_q "repos/$APP_REPO/commits/$ref" --jq '.sha // empty')"
  [[ -z "$code_sha" ]] || code_pr="$(gh_q "repos/$APP_REPO/commits/$code_sha/pulls" --jq '.[0].number // empty')"

  deployment="$(jq -n --arg id "$SERVICE-$env-$tag" --arg env "$env" --arg dora "$(dora_label "$env")" \
    --arg tag "$tag" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg merged "$merged_by" \
    --arg approved "$approved_by" --arg url "$pr_url" --arg svc "$SERVICE" \
    --arg ppr "${pr:+platform-gitops-$pr}" --arg cpr "${code_pr:+meridian-orders-$code_pr}" --argjson builds "$build_ids" '
    {identifier: $id, title: ($svc + " " + $tag + " → " + $env),
     properties: ({createdAt: $now, deploymentStatus: "Pending", environment: $dora, tag: $tag}
       + (if $merged != "" then {merged_by: $merged} else {} end)
       + (if $approved != "" then {approved_by: $approved} else {} end)
       + (if $url != "" then {promotion_pr_url: $url} else {} end)),
     relations: ({service: $svc, target_environment: $env, builds: $builds}
       + (if $ppr != "" then {promotion_pr: $ppr} else {} end)
       + (if $cpr != "" then {github_pull_request: $cpr} else {} end))}')"
  "$PORT_ENTITY" deployment "$deployment" --create-missing
done
