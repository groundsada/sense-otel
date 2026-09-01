# Access, APIs and smoke tests

Every command here was run against the live cluster on 2026-08-31. Where a
command needs a credential it shows how to *retrieve* it — no secret values are
committed to this repo.

Everything below assumes your kubeconfig points at NRP Nautilus.

---

## 1. GUIs

| What | URL | Auth |
|---|---|---|
| **sense-viz Grafana** (the push path) | https://sense-viz.nrp-nautilus.io | login required |
| **OTLP gateway** (ingest only, no UI) | https://sense-otlp.nrp-nautilus.io | Bearer token |
| sense-viz static web | https://sense-viz-web.nrp-nautilus.io | none |
| autogole Grafana (production, scrape path) | https://autogole-grafana.nrp-nautilus.io | separate |
| autogole Prometheus | https://autogole-prometheus.nrp-nautilus.io | basic auth |
| SENSE-O (sense-dev) | https://sd-senseo-sense-dev.nrp-nautilus.io | Keycloak |
| Keycloak (sense-dev) | https://sd-keycloak-sense-dev.nrp-nautilus.io | admin |

Anonymous access to sense-viz Grafana is **off**
(`GF_AUTH_ANONYMOUS_ENABLED=false`), and signup is off, so you need the admin
credential below.

### Dashboards

| Dashboard | URL |
|---|---|
| SiteRM — Push Path Overview | https://sense-viz.nrp-nautilus.io/d/siterm-push-path |

Provisioned from `dashboards/*.json` into the **SENSE** folder. They are
read-only in the UI on purpose (`allowUiUpdates: false`) — edit the JSON in this
repo and `kubectl apply -k .`.

---

## 2. Credentials

```bash
# sense-viz Grafana admin
kubectl get secret -n sense-viz grafana-admin -o jsonpath='{.data.admin-user}' | base64 -d; echo
kubectl get secret -n sense-viz grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo

# sense-dev Grafana (separate instance, separate stack)
kubectl get secret -n sense-dev grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo
kubectl get secret -n sense-dev grafana-user-mfsada -o jsonpath='{.data.password}' | base64 -d; echo
```

**Three sense-viz datasources are wired but have no credentials yet.** The
secrets `grafana-autogole`, `grafana-esnet` and `grafana-e2e-mysql` are all
absent, so the *Prometheus (autogole)*, *ESnet* and *MySQL-ESnet* datasources
will fail to authenticate. This is by design — the deployment marks them
`optional: true` so Grafana still starts — but any panel using them errors while
the rest of the dashboard works. Create them from
`k8s/01-secrets.example.yaml` when you want those panels live.

---

## 3. Port forwarding

Everything in `sense-viz` is a ClusterIP, so to hit the APIs from a laptop:

```bash
kubectl port-forward -n sense-viz svc/grafana  3000:3000   # Grafana UI/API
kubectl port-forward -n sense-viz svc/mimir    8080:8080   # Mimir  (Prometheus API)
kubectl port-forward -n sense-viz svc/loki     3100:3100   # Loki
kubectl port-forward -n sense-viz svc/tempo    3200:3200   # Tempo
kubectl port-forward -n sense-viz svc/blackbox 9115:9115   # blackbox exporter
kubectl port-forward -n sense-viz svc/otlp-gateway 4318:4318  # OTLP/HTTP direct
```

The sense-dev stack is a *separate* LGTM deployment — do not confuse the two:

```bash
kubectl port-forward -n sense-dev svc/grafana 3001:3000
kubectl port-forward -n sense-dev svc/mimir   8081:8080
kubectl port-forward -n sense-dev svc/dmm       8000:80
kubectl port-forward -n sense-dev svc/sd-senseo 8443:8443
```

**Every LGTM query needs the tenant header.** There is one tenant for the whole
fleet and `sitename` carries attribution, so a query without
`X-Scope-OrgID: sense` returns nothing (Loki/Mimir) or errors with "no org id"
(Tempo).

---

## 4. Query APIs — runnable examples

With `kubectl port-forward -n sense-viz svc/mimir 8080:8080` running:

```bash
H='X-Scope-OrgID: sense'
M=http://localhost:8080/prometheus

# Which sites are pushing, and how stale is each one?
curl -s -H "$H" --data-urlencode \
  'query=round(time() - max by (sitename) (timestamp(service_state)))' \
  $M/api/v1/query | python3 -m json.tool

# service_state is a prometheus_client ENUM: the state is a LABEL and the value
# is a 0/1 flag for which state is live. Filter on == 1 or you count all 204
# possible states instead of the ~34 real services.
curl -s -H "$H" --data-urlencode \
  'query=count by (sitename, service_state) (service_state == 1)' \
  $M/api/v1/query | python3 -m json.tool

# Anything currently failed
curl -s -H "$H" --data-urlencode \
  'query=service_state{service_state="FAILED"} == 1' $M/api/v1/query

# Daemon freshness -- push-path only, the scrape path does not emit this
curl -s -H "$H" --data-urlencode \
  'query=topk(10, time() - siterm_daemon_last_success_timestamp_seconds)' \
  $M/api/v1/query

# Fleet-wide blackbox probe health (all 31 registry targets, enrolled or not)
curl -s -H "$H" --data-urlencode 'query=avg(probe_success)' $M/api/v1/query
curl -s -H "$H" --data-urlencode 'query=probe_success == 0' $M/api/v1/query

# What metric names exist at all
curl -s -H "$H" $M/api/v1/label/__name__/values | python3 -m json.tool | head -40
```

Loki (`kubectl port-forward -n sense-viz svc/loki 3100:3100`):

```bash
H='X-Scope-OrgID: sense'; L=http://localhost:3100
NOW=$(date +%s); ST=$((NOW-3600))

curl -s -H "$H" $L/loki/api/v1/labels                        # -> service_name, sitename, siterm_component
curl -s -H "$H" $L/loki/api/v1/label/sitename/values

# Log volume per site. NOTE: `.*` is a PARSE ERROR in Loki -- it demands at
# least one matcher that is not empty-compatible. Use `.+`.
curl -s -G -H "$H" $L/loki/api/v1/query_range \
  --data-urlencode 'query=sum by (sitename) (count_over_time({sitename=~".+"}[5m]))' \
  --data-urlencode "start=${ST}000000000" --data-urlencode "end=${NOW}000000000" \
  --data-urlencode 'step=300' | python3 -m json.tool | head -30

# Raw lines for one site
curl -s -G -H "$H" $L/loki/api/v1/query_range \
  --data-urlencode 'query={sitename="T9_US_MOHDEV_C"}' --data-urlencode 'limit=5' \
  --data-urlencode "start=${ST}000000000" --data-urlencode "end=${NOW}000000000"
```

Tempo (`kubectl port-forward -n sense-viz svc/tempo 3200:3200`):

```bash
H='X-Scope-OrgID: sense'; T=http://localhost:3200

curl -s -H "$H" "$T/api/search/tags" | python3 -m json.tool | head
curl -s -H "$H" "$T/api/v2/search/tag/resource.sitename/values"

# Recent traces for one site, then fetch one whole trace
curl -s -H "$H" "$T/api/search?tags=sitename%3DT9_US_MOHDEV_C&limit=5" | python3 -m json.tool
curl -s -H "$H" "$T/api/traces/<traceID>" | python3 -m json.tool | head -40
```

Grafana API (`kubectl port-forward -n sense-viz svc/grafana 3000:3000`):

```bash
A="admin:$(kubectl get secret -n sense-viz grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d)"
G=http://localhost:3000

curl -s -u "$A" $G/api/health
curl -s -u "$A" $G/api/search?query= | python3 -m json.tool          # list dashboards
curl -s -u "$A" $G/api/datasources | python3 -m json.tool | grep -E 'name|uid'
curl -s -u "$A" $G/api/dashboards/uid/siterm-push-path | python3 -m json.tool | head

# Query THROUGH grafana, which exercises uid resolution + the tenant header
curl -s -u "$A" -G "$G/api/datasources/proxy/uid/mimir-sense/api/v1/query" \
  --data-urlencode 'query=count(count by (sitename) (service_state))'
```

---

## 5. End-to-end: mint a token and push through the gateway

This is the whole auth chain — client cert → challenge → signature → JWT →
gateway → Mimir. Verified working 2026-08-31.

The frontend is the OIDC issuer; the agent only consumes tokens. `/m2m/token` is
a **challenge-response** flow, not a simple POST — posting to it with no body
returns HTTP 422.

```bash
AG=siterm-agent-conf-f6f6f6f6f6f6f6f6f6f6f6f6f-0     # site C agent
kubectl exec -n sense-dev $AG -c agent -- python3 - <<'EOF'
import base64, json, time
import httpx
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec, padding, rsa
from cryptography.hazmat.primitives.serialization import load_pem_private_key

FE = "http://service-siterm-fe-t9-us-mohdev-c-e5e5e5e5e5e5e5e5e5e5e5e5e5e5.sense-dev.svc.cluster.local:8443"
GW = "https://sense-otlp.nrp-nautilus.io"
cert = open("/etc/secret-mount/tls.crt").read()
key  = open("/etc/secret-mount/tls.key", "rb").read()

c = httpx.Client(timeout=30)
ch = c.post(FE + "/m2m/token", json={"certificate": cert}).json()   # 1. challenge
k, raw = load_pem_private_key(key, password=None), base64.b64decode(ch["challenge"])
sig = (k.sign(raw, padding.PSS(mgf=padding.MGF1(hashes.SHA256()),
                               salt_length=padding.PSS.MAX_LENGTH), hashes.SHA256())
       if isinstance(k, rsa.RSAPrivateKey) else k.sign(raw, ec.ECDSA(hashes.SHA256())))
tok = c.post(ch["ref_url"], json={"signature": base64.b64encode(sig).decode()}).json()["access_token"]

claims = json.loads(base64.urlsafe_b64decode(tok.split(".")[1] + "=="))
print("iss:", claims["iss"]); print("aud:", claims["aud"])   # aud MUST contain sense-otlp

now = int(time.time() * 1e9)
payload = {"resourceMetrics": [{"resource": {"attributes": [
    {"key": "sitename", "value": {"stringValue": "T9_US_MOHDEV_C"}},
    {"key": "service.name", "value": {"stringValue": "smoketest"}}]},
    "scopeMetrics": [{"scope": {"name": "manual-smoketest"}, "metrics": [
        {"name": "sense_viz_smoketest", "unit": "1",
         "gauge": {"dataPoints": [{"asDouble": 1.0, "timeUnixNano": str(now)}]}}]}]}]}
r = c.post(GW + "/v1/metrics", json=payload,
           headers={"Authorization": f"Bearer {tok}", "Content-Type": "application/json"})
print("push:", r.status_code, r.text)     # -> 200 {"partialSuccess":{}}
EOF
```

Then confirm it landed (about 10s later):

```bash
kubectl port-forward -n sense-viz svc/mimir 8080:8080 &
curl -s -H 'X-Scope-OrgID: sense' --data-urlencode 'query=sense_viz_smoketest' \
  http://localhost:8080/prometheus/api/v1/query | python3 -m json.tool
```

Prove the auth is real, not decorative:

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://sense-otlp.nrp-nautilus.io/v1/metrics \
  -H 'Content-Type: application/json' -d '{"resourceMetrics":[]}'                      # 401
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://sense-otlp.nrp-nautilus.io/v1/metrics \
  -H 'Authorization: Bearer nonsense' -H 'Content-Type: application/json' \
  -d '{"resourceMetrics":[]}'                                                          # 401
```

`helpers/token-test.py` in the siterm repo is the upstream version of this flow
and also exercises refresh.

---

## 6. Gateway health and enrollment

```bash
kubectl get pods -n sense-viz | grep otlp-gateway
kubectl logs -n sense-viz deploy/otlp-gateway | grep -i 'everything is ready'

# The enrolled issuer list actually in force (not what the repo says)
CM=$(kubectl get deploy -n sense-viz otlp-gateway \
      -o jsonpath='{.spec.template.spec.volumes[*].configMap.name}' | tr ' ' '\n' | grep otlp-gateway)
kubectl get cm -n sense-viz $CM -o yaml | grep -E 'issuer_url:' | grep -v '#' | sort

# Re-check every enrolled frontend's discovery document before any deploy
python3 scripts/gen-registry.py --verify
```

**The gateway resolves every enrolled issuer at startup and refuses to start if
any one fails.** A site that goes down while the gateway is up changes nothing
until the next restart, and then the new pod crashloops on it while the old pod
keeps serving. So read a crashloop after an unrelated change as "some *other*
enrolled issuer died a while ago", and sweep all issuers from inside sense-viz —
not from a laptop, which cannot resolve the in-cluster dev issuers — before
applying anything that rolls the deployment:

```bash
kubectl run isweep --rm -i --restart=Never -n sense-viz --image=curlimages/curl:8.10.1 \
  --command -- sh -c 'for u in <issuer urls>; do
     c=$(curl -s -m 10 -o /dev/null -w %{http_code} "$u/.well-known/openid-configuration")
     [ "$c" = 200 ] || echo "FAIL $c $u"; done; echo SWEEP-DONE'
```
