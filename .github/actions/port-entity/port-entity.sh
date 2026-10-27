#!/usr/bin/env bash
# Crea o actualiza entidades en Port (upsert + merge). Es el "golden path" de la plataforma: los
# pipelines de las apps describen QUÉ ha pasado; cómo se habla con Port lo decide la plataforma.
#
#   port-entity.sh <blueprint> <json | -> [--create-missing]
#
#   json  un objeto o un array de objetos con "identifier" (y opcionalmente title, properties,
#         relations). "-" lo lee de la entrada estándar.
#
# Entorno: PORT_CLIENT_ID, PORT_CLIENT_SECRET (obligatorias) · PORT_API (por defecto la región EU)
#          PORT_STRICT=true para fallar si Port falla. Por defecto AVISA y sale con 0: el linaje
#          nunca bloquea una entrega (ADR 0016).
set -euo pipefail

BP="${1:?Uso: $0 <blueprint> <json|-> [--create-missing]}"
DATA="${2:?Uso: $0 <blueprint> <json|-> [--create-missing]}"
CREATE=false
[[ "${3:-}" == "--create-missing" ]] && CREATE=true
API="${PORT_API:-https://api.getport.io/v1}"
[[ "$DATA" == "-" ]] && DATA="$(cat)"

give_up() {
  echo "::warning::port-entity: $*"
  [[ "${PORT_STRICT:-false}" == "true" ]] && exit 1
  exit 0
}

[[ -n "${PORT_CLIENT_ID:-}" && -n "${PORT_CLIENT_SECRET:-}" ]] || give_up "sin credenciales de Port: no se registra nada"
echo "$DATA" | jq -e 'if type == "array" then all(.[]; has("identifier")) else has("identifier") end' >/dev/null \
  || give_up "JSON no válido o sin identifier"

tok="$(jq -n --arg id "$PORT_CLIENT_ID" --arg s "$PORT_CLIENT_SECRET" '{clientId: $id, clientSecret: $s}' \
  | curl -fsS --retry 3 -X POST "$API/auth/access_token" -H 'Content-Type: application/json' -d @- \
  | jq -r '.accessToken // empty')" || true
[[ -n "$tok" ]] || give_up "no se pudo autenticar contra Port"
[[ -z "${GITHUB_ACTIONS:-}" ]] || echo "::add-mask::$tok"

failed=0
while read -r entity; do
  id="$(jq -r .identifier <<<"$entity")"
  resp="$(curl -sS --retry 3 -w '\n%{http_code}' -X POST \
    "$API/blueprints/$BP/entities?upsert=true&merge=true&create_missing_related_entities=$CREATE" \
    -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' -d "$entity")" || resp=$'\n000'
  code="${resp##*$'\n'}"
  if [[ "$code" == 2* ]]; then
    echo "  ✅ $BP/$id"
    [[ -z "${GITHUB_STEP_SUMMARY:-}" ]] || echo "- ✅ Port \`$BP/$id\`" >>"$GITHUB_STEP_SUMMARY"
  else
    body="${resp%$'\n'*}"
    echo "::warning::port-entity: $BP/$id → HTTP $code $(jq -c '.message // .' <<<"$body" 2>/dev/null | head -c 300)"
    failed=$((failed + 1))
  fi
done < <(echo "$DATA" | jq -c 'if type == "array" then .[] else . end')

unset tok
if (( failed > 0 )); then give_up "$failed entidad(es) sin registrar en $BP"; fi
