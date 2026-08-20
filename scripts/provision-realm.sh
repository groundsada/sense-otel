#!/bin/sh
# Provision the sense-telemetry realm and one client per SiteRM frontend.
#
# Idempotent, and safe to re-run after the keycloak stack is rebuilt -- which it
# will be. sd-keycloak lives in sense-dev on an ephemeral database; a rebuild
# there drops the realm and every client with it. Without this script that means
# reissuing credentials to 29 sites by hand.
#
# Client secrets are cached in the `siterm-otlp-clients` Secret in sense-viz and
# pushed back into keycloak on re-provision, so a rebuild does not invalidate
# credentials sites already hold. Delete that Secret to rotate everything.
#
#   ./scripts/provision-realm.sh
set -eu

KC="${KC:-https://sd-keycloak-sense-dev.nrp-nautilus.io}"
REALM="${REALM:-sense-telemetry}"
AUDIENCE="${AUDIENCE:-sense-otlp}"
NS="${NS:-sense-viz}"
CACHE="${CACHE:-siterm-otlp-clients}"
SITES="${SITES:-$(dirname "$0")/../keycloak/sites.txt}"

if [ -z "${KC_ADMIN_PASSWORD:-}" ]; then
  KC_ADMIN_PASSWORD=$(kubectl get secret sd-kc-db -n sense-dev -o jsonpath='{.data.ADMIN_PASSWORD}' | base64 -d)
fi

tok() {
  curl -sf -X POST "$KC/realms/master/protocol/openid-connect/token" \
    -d client_id=admin-cli -d username="${KC_ADMIN:-admin}" \
    --data-urlencode "password=$KC_ADMIN_PASSWORD" -d grant_type=password \
  | jq -r .access_token
}

T=$(tok)
[ -n "$T" ] && [ "$T" != "null" ] || { echo "keycloak admin auth failed" >&2; exit 1; }

code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$KC/admin/realms" \
  -H "Authorization: Bearer $T" -H 'Content-Type: application/json' \
  -d "{\"realm\":\"$REALM\",\"enabled\":true,\"displayName\":\"SENSE fleet telemetry\",\"accessTokenLifespan\":3600}")
case "$code" in
  201) echo "realm $REALM created" ;;
  409) echo "realm $REALM already exists" ;;
  *)   echo "realm create failed: $code" >&2; exit 1 ;;
esac

# Restore previously issued secrets, if we have them.
kubectl get secret "$CACHE" -n "$NS" -o json 2>/dev/null \
  | jq -r '.data // {} | to_entries[] | "\(.key) \(.value)"' > /tmp/.cache.$$ || : > /tmp/.cache.$$

created=0; existed=0
grep -vE '^\s*(#|$)' "$SITES" | while read -r SITE; do
  T=$(tok)
  body=$(SITE="$SITE" AUD="$AUDIENCE" jq -n '
    { clientId: ("siterm-" + env.SITE),
      name: ("SiteRM frontend " + env.SITE),
      enabled: true, publicClient: false, serviceAccountsEnabled: true,
      standardFlowEnabled: false, implicitFlowEnabled: false,
      directAccessGrantsEnabled: false,
      protocolMappers: [
        { name: "sitename", protocol: "openid-connect",
          protocolMapper: "oidc-hardcoded-claim-mapper",
          config: { "claim.name": "sitename", "claim.value": env.SITE,
                    "jsonType.label": "String", "access.token.claim": "true",
                    "id.token.claim": "false", "userinfo.token.claim": "false" } },
        { name: "otlp-audience", protocol: "openid-connect",
          protocolMapper: "oidc-audience-mapper",
          config: { "included.custom.audience": env.AUD,
                    "access.token.claim": "true", "id.token.claim": "false" } } ] }')

  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$KC/admin/realms/$REALM/clients" \
    -H "Authorization: Bearer $T" -H 'Content-Type: application/json' -d "$body")
  case "$code" in
    201) created=$((created+1)) ;;
    409) existed=$((existed+1)) ;;
    *)   echo "  FAIL $SITE -> $code" >&2; continue ;;
  esac

  # Re-pin the cached secret so sites keep working across a keycloak rebuild.
  cached=$(awk -v k="siterm-$SITE" '$1==k{print $2}' /tmp/.cache.$$ | base64 -d 2>/dev/null || true)
  if [ -n "$cached" ]; then
    ID=$(curl -sf -H "Authorization: Bearer $T" "$KC/admin/realms/$REALM/clients?clientId=siterm-$SITE" | jq -r '.[0].id')
    curl -sf -o /dev/null -X PUT "$KC/admin/realms/$REALM/clients/$ID" \
      -H "Authorization: Bearer $T" -H 'Content-Type: application/json' \
      -d "$(jq -n --arg s "$cached" '{secret:$s}')" || echo "  warn: could not re-pin $SITE" >&2
  fi
done
rm -f /tmp/.cache.$$

# Cache whatever keycloak now holds, so the next rebuild can restore it.
T=$(tok)
args=""
for SITE in $(grep -vE '^\s*(#|$)' "$SITES"); do
  ID=$(curl -sf -H "Authorization: Bearer $T" "$KC/admin/realms/$REALM/clients?clientId=siterm-$SITE" | jq -r '.[0].id // empty')
  [ -n "$ID" ] || continue
  S=$(curl -sf -H "Authorization: Bearer $T" "$KC/admin/realms/$REALM/clients/$ID/client-secret" | jq -r .value)
  args="$args --from-literal=siterm-$SITE=$S"
done
# shellcheck disable=SC2086
kubectl create secret generic "$CACHE" -n "$NS" $args --dry-run=client -o yaml | kubectl apply -f - >/dev/null

echo "clients: $(curl -sf -H "Authorization: Bearer $(tok)" "$KC/admin/realms/$REALM/clients?max=200" | jq -r '[.[]|select(.clientId|startswith("siterm-"))]|length') in realm $REALM"
echo "secrets cached in $NS/$CACHE"
