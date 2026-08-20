#!/bin/sh
# Print the OTLP config block for one site.
#
#   ./scripts/site-credential.sh T2_US_SDSC
#
# Needs keycloak admin rights. The client secret is fetched, never stored here.
set -eu

SITE="${1:?usage: site-credential.sh <SITENAME>}"
KC="${KC:-https://sd-keycloak-sense-dev.nrp-nautilus.io}"
REALM="${REALM:-sense-telemetry}"
GW="${GW:-https://sense-otlp.nrp-nautilus.io}"

if [ -z "${KC_ADMIN_PASSWORD:-}" ]; then
  KC_ADMIN_PASSWORD=$(kubectl get secret sd-kc-db -n sense-dev -o jsonpath='{.data.ADMIN_PASSWORD}' | base64 -d)
fi

T=$(curl -sf -X POST "$KC/realms/master/protocol/openid-connect/token" \
  -d client_id=admin-cli -d username="${KC_ADMIN:-admin}" \
  --data-urlencode "password=$KC_ADMIN_PASSWORD" -d grant_type=password | jq -r .access_token)

ID=$(curl -sf -H "Authorization: Bearer $T" "$KC/admin/realms/$REALM/clients?clientId=siterm-$SITE" | jq -r '.[0].id // empty')
[ -n "$ID" ] || { echo "no client siterm-$SITE in realm $REALM" >&2; exit 1; }

SECRET=$(curl -sf -H "Authorization: Bearer $T" "$KC/admin/realms/$REALM/clients/$ID/client-secret" | jq -r .value)

cat <<EOF
# /etc/environment on the $SITE frontend
OTEL_ENABLED=true
OTLP_ENDPOINT=$GW/v1/traces
OTLP_AUTH_ISSUER=$KC/realms/$REALM
OTLP_AUTH_CLIENT_ID=siterm-$SITE
OTLP_AUTH_CLIENT_SECRET=$SECRET
EOF
