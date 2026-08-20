# sense-otel

OTLP gateway and LGTM backends for SENSE fleet telemetry, in the `sense-viz`
namespace.

One endpoint that every SiteRM frontend pushes traces, logs and metrics to.
Sites never address Tempo, Loki or Mimir directly, so backends can be moved or
replaced without reconfiguring 29 sites.

```
  SITE                                  sense-viz
  ┌──────────────────────┐
  │  agent ─┐            │
  │  agent ─┼─► SiteRM FE ├── OTLP ──►  otlp-gateway ──┬──► Tempo   traces
  │  switch─┘   (egress)  │   (push)    (authenticates ├──► Loki    logs
  └──────────────────────┘               and stamps    └──► Mimir   metrics
                                          identity)              │
        │                                                        ▼
        └─── metrics also ──► autogole Prometheus ──►  autogole Grafana
             (PULL, 29 jobs, unchanged, still primary)
```

| | |
|---|---|
| OTLP ingest | `https://sense-otlp.nrp-nautilus.io/v1/{traces,metrics,logs}` |
| in-cluster gRPC | `otlp-gateway.sense-viz.svc:4317` |
| Grafana | `https://sense-viz.nrp-nautilus.io` |
| issuer | `https://sd-keycloak-sense-dev.nrp-nautilus.io/realms/sense-telemetry` |
| audience | `sense-otlp` |

## The one property that matters

**Site identity comes from the credential, never from the payload.**

Each site holds a keycloak client whose token carries a `sitename` claim fixed
by a hardcoded mapper at issue time. The gateway uses that claim as the token
subject and stamps it over whatever `sitename` the payload contained. A
misconfigured or hostile site cannot write into another site's data.

Verified, not assumed — a span sent with `sitename=EVIL_SPOOFED_SITE` under the
`T2_US_SDSC` credential lands in Tempo as `sitename=T2_US_SDSC`.

This is the same guarantee the autogole Prometheus gets by applying `sitename`
centrally in `relabel_configs` at scrape time. Push has no relabeller, so the
gateway has to be the thing that does it.

## Layout

| Path | |
|---|---|
| `collector/config.yaml` | the gateway pipeline — receivers, auth, sampling, exporters |
| `k8s/01-secrets.example.yaml` | template only. Never filled in and committed |
| `k8s/10-mimir.yaml` | metrics |
| `k8s/11-tempo.yaml` | traces |
| `k8s/12-loki.yaml` | logs |
| `k8s/20-gateway.yaml` | gateway Deployment and Service |
| `k8s/21-gateway-ingress.yaml` | public HTTPS ingest |
| `k8s/30-grafana.yaml` | Grafana, datasources wired for the trace↔log pivot |
| `k8s/31-grafana-ingress.yaml` | public HTTPS UI |
| `k8s/40-backup.yaml` | nightly mirror of the primary buckets to the fallback RGW |
| `keycloak/sites.txt` | the 29 SiteRM frontends |
| `scripts/provision-realm.sh` | create the realm and one client per site, idempotently |
| `scripts/site-credential.sh` | print one site's OTLP config block |

## Deploying

Secrets first, once, by hand. Nothing in this repository creates them, so
applying it can never be the thing that puts a credential into the cluster:

```sh
kubectl create secret generic obs-s3 -n sense-viz \
  --from-literal=AWS_ACCESS_KEY_ID=... \
  --from-literal=AWS_SECRET_ACCESS_KEY=... \
  --from-literal=S3_ENDPOINT=rook-ceph-rgw-nautiluss3.rook

kubectl create secret generic gateway-oidc -n sense-viz \
  --from-literal=OIDC_ISSUER_URL=https://<issuer>/realms/sense-telemetry \
  --from-literal=OIDC_AUDIENCE=sense-otlp

kubectl create secret generic grafana-admin -n sense-viz \
  --from-literal=admin-user=... --from-literal=admin-password=...
```

Then `kubectl apply -k .`

`collector/config.yaml` becomes the gateway ConfigMap via a
`configMapGenerator`, which appends a content hash to the name and rewrites the
Deployment's reference — so editing the pipeline rolls the gateway on the next
apply rather than waiting for an unrelated restart to pick it up.

## Onboarding a site

Sites are confidential clients in the `sense-telemetry` realm named
`siterm-<SITENAME>`, service accounts only, with two mappers: a hardcoded
`sitename` claim and an audience of `sense-otlp`. The roster is
`keycloak/sites.txt`, taken from the `*_STATE` scrape jobs in the autogole
Prometheus config.

```sh
./scripts/provision-realm.sh              # idempotent; creates realm + 29 clients
./scripts/site-credential.sh T2_US_SDSC   # print one site's config block
```

`provision-realm.sh` exists because `sd-keycloak` runs in `sense-dev` on a
database that gets rebuilt — it happened once during this work and took the
realm and all 29 clients with it. Client secrets are cached in the
`siterm-otlp-clients` Secret in `sense-viz` and pushed back on re-provision, so
a rebuild does not invalidate credentials sites already hold. Verified by
deleting the realm and re-running: same secret, gateway still returns 200.

Delete that Secret to rotate everything.

A site exchanges those for a token by client credentials grant:

```sh
curl -s -X POST "$ISSUER/protocol/openid-connect/token" \
  -d grant_type=client_credentials \
  -d client_id=siterm-T2_US_SDSC \
  --data-urlencode "client_secret=$SECRET" | jq -r .access_token
```

Adding a site later means one client with the same two mappers, and nothing on
the gateway changes.

### Why two protocols

15 of the 29 SiteRM frontends are not on NRP — six on FABRIC
(`cern1-sub1-gw1.exp.fabric-testbed.net` and similar) and nine on site-owned
infrastructure (`cmssense1.fnal.gov`, `red-sense-rm.unl.edu`,
`sense.af.uchicago.edu`, `r740xd4.it.northwestern.edu`). They reach the gateway
only through the public HTTPS ingress.

HAProxy can carry gRPC with a backend-protocol annotation, but gRPC needs HTTP/2
negotiated end to end, and an institutional egress proxy that terminates and
re-originates TLS breaks it — surfacing as an opaque connection error. OTLP/HTTP
is an ordinary POST and survives anything that passes normal HTTPS. Frontends
inside the cluster should still use gRPC on 4317.

## Storage and failover

Primary is `obs-s3` — the in-cluster nautiluss3 RGW, the same one `sense-dev`
uses. Buckets `mfsada-sense-viz-{mimir,tempo,loki}`. Fallback is `obs-s3-central`
on the central RGW, holding same-named buckets, kept current by the nightly
mirror in `k8s/40-backup.yaml`.

**Failover is manual, and that is not a shortcut.** Mimir, Tempo and Loki each
accept exactly one object-storage backend. None supports dual-write or automatic
failover, so "primary with fallback" can only mean "one config, switchable."

Do not fail over for a short outage. Mimir's local TSDB, Tempo's WAL and Loki's
ingester all hold recent data and retry, so a blip is already survived — and
switching buckets mid-outage splits the data across two stores that nothing can
query together, turning a recoverable problem into a permanent one.

For a real loss of the primary RGW:

```sh
# 1. repoint the storage secret at the fallback
kubectl get secret obs-s3-central -n sense-viz -o json \
  | jq '.metadata = {"name":"obs-s3","namespace":"sense-viz"}' \
  | kubectl apply -f -

# 2. restart the backends to pick it up
kubectl rollout restart statefulset/mimir statefulset/tempo statefulset/loki -n sense-viz

# 3. suspend the mirror, or it will replicate back over the fallback
kubectl patch cronjob obs-backup -n sense-viz -p '{"spec":{"suspend":true}}'
```

Step 3 matters: the job mirrors primary→fallback with `--remove`. Leaving it
running after a failover would mirror an empty or broken primary over the only
good copy.

Expect to lose up to 24 hours — whatever was written since the last successful
mirror exists only on the primary. And `--remove` makes this a mirror rather
than a backup with history: it protects against losing the RGW, not against
something deleting the data.

## Decisions worth knowing before changing anything

**Metrics keep their existing names.** The remote-write exporter sets
`translation_strategy: UnderscoreEscapingWithoutSuffixes`. The default
translation appends unit and `_total` suffixes, and 67 existing alert rules plus
every existing dashboard panel match on the current names. During the dual-path
period the same series must be identical whether it arrived by scrape or by
push, or the two cannot be compared and the cutover cannot be verified. A
monotonic sum named `siterm_verify_counter` was confirmed to land in Mimir under
exactly that name.

**Identity comes from `auth.subject` only.** The oidc extension exposes exactly
two context attributes, `subject` and `membership`. `auth.claims.<name>` is not
reachable and resolves silently to nothing, so it looks like a working fallback
and is not. `OIDC_USERNAME_CLAIM=sitename` is what makes the subject the site
name instead of the service account's UUID.

**Sampling is tail, not head.** With no instrumented orchestrator above SiteRM,
every trace is its own root and each site samples independently, so a 10% head
rate yields 10% of *fragments* — a sampled frontend span whose PolicyService span
was dropped. That looks like a complete trace and is not. Deciding at the gateway
after the whole trace has arrived keeps or drops it as a unit. Errors and slow
traces are kept unconditionally.

**One tenant, not 29.** `X-Scope-OrgID: sense` for everything, with `sitename` as
a gateway-stamped attribute. Per-site tenants would mean 29 tenants to provision
and 29 Grafana datasources to maintain — and Loki refuses to merge tenants in a
single query, so the fleet view would fragment. What actually needs to be
unforgeable is attribution, and stamping at the gateway gives that.

**One gateway replica.** Tail sampling buffers a trace's spans in memory until it
decides. With more than one replica, spans of the same trace land on different
replicas and each sees only part of it. Scaling out needs a `loadbalancing`
exporter in front, routing by trace id.

**The autogole stack stays primary.** This runs alongside it, not instead of it.
Metrics still reach Grafana by the existing pull path; Mimir receives a second
copy by push so parity can be proven before anything is switched. Traces and
logs are pure addition — there is nothing to migrate, which is why they go first.

**The issuer is a dev keycloak.** `sd-keycloak` lives in the `sense-dev`
namespace on a database that is rebuilt from time to time. The realm and clients
are isolated from `master` and `StackV`, but this is not production-grade IdP
hosting, which is why provisioning is a committed script rather than something
done by hand. The `providers:` block in the collector
config is a list precisely so a second issuer (CILogon) can be accepted
alongside it during a migration, with no flag day for sites.
