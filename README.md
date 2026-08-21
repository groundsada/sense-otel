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
| issuers | each SiteRM frontend, 20 enrolled of 27 known — `sites/registry.yaml` |
| audience | `sense-otlp` |

## The one property that matters

**Site identity comes from the credential, never from the payload.**

There is no separate identity provider. Every SiteRM frontend is already an OIDC
issuer: it publishes `/.well-known/openid-configuration` and
`/.well-known/jwks.json`, and mints short-lived RS256 tokens from an X509
challenge-response against the host certificate. The gateway trusts all of them,
because the collector's `oidc` extension takes `providers` as a list.

Identity is the token's `iss`, via `username_claim: iss`. A site cannot forge it:
the collector fetches the signing keys from that issuer URL, so claiming to be
someone else means signing with a key published at *their* JWKS endpoint. The
`sitename` claim in the token is never read. `transform/sitename` resolves the
issuer URL to a name centrally, from the same registry that decided which
issuers to trust at all.

Verified, not assumed — a second issuer minting `sitename: I_AM_LYING_ABOUT_MY_SITE`
for a valid certificate produced `sitename: T2_US_CALTECH` at the gateway. Ten
negative cases are rejected with 401, including certificate replay with an
attacker key, a self-signed certificate forging an enrolled DN, a trusted CA with
an unenrolled DN, challenge replay, a token signed by a key absent from JWKS,
expiry, wrong audience, and an `alg=none` downgrade.

This is the same guarantee the autogole Prometheus gets by applying `sitename`
centrally in `relabel_configs` at scrape time. Push has no relabeller, so the
gateway has to be the thing that does it.

## Layout

| Path | |
|---|---|
| `collector/config.yaml` | the gateway pipeline — receivers, auth, sampling, exporters |
| `collector/registry.yaml` | generated. Trusted issuers and the issuer→sitename map |
| `sites/registry.yaml` | **source of truth.** One line per frontend |
| `sites/generated/site-env.txt` | generated. The env block each frontend pastes |
| `scripts/gen-registry.py` | regenerates both. `--check` fails when stale |
| `k8s/01-secrets.example.yaml` | template only. Never filled in and committed |
| `k8s/10-mimir.yaml` | metrics |
| `k8s/11-tempo.yaml` | traces |
| `k8s/12-loki.yaml` | logs |
| `k8s/20-gateway.yaml` | gateway Deployment and Service |
| `k8s/21-gateway-ingress.yaml` | public HTTPS ingest |
| `k8s/30-grafana.yaml` | Grafana, datasources wired for the trace↔log pivot |
| `k8s/31-grafana-ingress.yaml` | public HTTPS UI |
| `k8s/40-backup.yaml` | nightly mirror of the primary buckets to the fallback RGW |

## Deploying

Secrets first, once, by hand. Nothing in this repository creates them, so
applying it can never be the thing that puts a credential into the cluster:

```sh
kubectl create secret generic obs-s3 -n sense-viz \
  --from-literal=AWS_ACCESS_KEY_ID=... \
  --from-literal=AWS_SECRET_ACCESS_KEY=... \
  --from-literal=S3_ENDPOINT=rook-ceph-rgw-nautiluss3.rook

kubectl create secret generic grafana-admin -n sense-viz \
  --from-literal=admin-user=... --from-literal=admin-password=...
```

There is no credential secret for OTLP auth. Trust is a list of public issuer
URLs in `collector/registry.yaml`, so it belongs in git rather than in a Secret.

Then `kubectl apply -k .`

`collector/config.yaml` and `collector/registry.yaml` become the gateway
ConfigMap via a `configMapGenerator`, which appends a content hash to the name
and rewrites the Deployment's reference — so editing either one rolls the gateway
on the next apply rather than waiting for an unrelated restart to pick it up.
Both are passed with `--config` and merged; they hold disjoint keys, so the merge
is a plain map union and never depends on how lists are resolved.

## Onboarding a site

No credential is issued, because the site already has one: its host certificate.
Enrolling is telling the gateway which issuer URL belongs to which site.

```sh
$EDITOR sites/registry.yaml      # add sitename + issuer
./scripts/gen-registry.py        # regenerate both artifacts
kubectl apply -k .               # content hash rolls the gateway
```

Then give the site its block from `sites/generated/site-env.txt`, which goes in
the frontend's `/etc/environment`:

```
OIDC_ISSUER=https://sense-t2-us-sdsc.nrp-nautilus.io
OIDC_SITENAME=T2_US_SDSC
OIDC_EXTRA_AUDIENCE=sense-otlp
OTLP_AUTH_URL=https://sense-t2-us-sdsc.nrp-nautilus.io
OTLP_ENDPOINT=https://sense-otlp.nrp-nautilus.io
```

`OIDC_ISSUER` must be byte-identical on both sides. go-oidc compares the
discovery document's `issuer` field to the configured `issuer_url` exactly, and
a mismatch is a 401 with nothing in the payload to explain it — which is the
whole reason both sides are generated from one file rather than maintained
twice. `gen-registry.py --check` fails when the generated copies are stale, so CI
can hold that.

Two of the 29 frontends cannot enroll yet and are `issuer: null` in the registry:
`T2_US_Wisconsin` is a `<yet to be added>` placeholder in the scrape config, and
`T3_US_FAB_Bluefield3` is reachable only by IPv6 literal, which needs a DNS name
before it can have a matching certificate.

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
and is not. `username_claim: iss` is what puts the issuer URL there, and
`transform/sitename` turns it into a name afterwards. Reading `sitename` from the
token instead would be one config line shorter and would hand every site the
ability to write as any other.

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

**There is no IdP, deliberately.** An earlier version of this ran on a keycloak
realm with 29 confidential clients. That meant 29 secrets to distribute, rotate
and survive a database rebuild — the `sense-dev` keycloak was in fact rebuilt
once during this work and took the whole realm with it. Every one of those
secrets was a second name for an identity the grid PKI already establishes, so
the frontends now issue their own tokens from the host certificate and the
gateway trusts their JWKS. No shared secret exists anywhere in this path.

That is only possible because the `oidc` extension's `providers` is a list. A
single-issuer extension would have forced either one issuer for the fleet — which
is the IdP again — or one receiver and one port per site.

**One bad issuer stops the whole gateway.** The oidc extension's `Start()`
accumulates errors across every configured provider with `multierr.Append` and
returns non-nil if *any* one of them failed, so the collector exits. Enrolling a
site therefore makes fleet-wide ingest depend on that site being reachable at
gateway-restart time — an availability inversion worth knowing about before
adding issuers. Two consequences are baked into `sites/registry.yaml`:

- `enrolled: false` keeps a site in the probe target list but out of the oidc
  providers, so an unreachable frontend is still watched without being able to
  prevent startup. Seven of the 27 are currently in that state.
- `issuer` must be **byte-identical** to what the frontend publishes in its
  discovery document, and this is not derivable by a rule. Most frontends
  publish the explicit `:443`; `sense-nrp-internet2` and `sense-fe` publish
  without it. Getting this wrong is not a per-site failure — it stops the
  gateway. `scripts/gen-registry.py --verify` reads every enrolled frontend's
  discovery document and diffs it against the registry:

```
$ ./scripts/gen-registry.py --verify
20 enrolled issuers match their discovery documents
```

**Probes stay an outside observation.** `probe_*` and `up` are produced by the
observer, not the target — a site that has fallen over cannot push a metric
saying so — so they are the one thing that cannot migrate to the push path. A
blackbox exporter and a tiny second collector (`k8s/50-blackbox.yaml`) scrape the
27 frontends from here and remote-write `probe_success`, `probe_http_status_code`
and `probe_ssl_earliest_cert_expiry` into Mimir under the same `sitename` label
the push path carries. The target list is `collector/probes.yaml`, generated from
the same `sites/registry.yaml` that decides which issuers the gateway trusts, so
a site cannot be enrolled for OTLP and silently left unprobed. The probe list is
deliberately the wider of the two — every frontend with a known URL, including
the seven that are not enrolled — because a site the gateway cannot reach is
exactly the one worth probing.

The 67 autogole alert rules are loaded into Mimir's ruler verbatim
(`k8s/51-alert-rules.yaml`), so `ALERTS` and `ALERTS_FOR_STATE` keep existing in
Mimir and the dashboards that read them stay useful during the dual-path period.
Rule-group limit: Mimir's default allows 20 rules per group, the port has 67, so
`ruler_max_rules_per_rule_group: 200` is set in `k8s/10-mimir.yaml`.

Measured on deploy: 20 of the 27 frontends probe green, and the seven that do
not are all about the observer's network rather than the sites.

- The six FABRIC frontends (`*.exp.fabric-testbed.net`) publish **AAAA records
  only**, and pods in `sense-viz` get a link-local `fe80::` address and no
  global IPv6 — the cluster has no v6 egress, so they cannot be reached from
  here at all. Autogole probes them from a dual-stack network with paired
  `*_V4`/`*_V6` jobs. A v6 module here would have nothing to route over, so
  only the v4 half is reproduced.
- `T1_US_FNAL`'s `:8443` is TCP-filtered from this namespace (connection
  refused at the transport, before any TLS negotiation) while open to
  `opennsa`.

Both need a network change, not a config change, so `ProbeFailed` fires for
those seven until then — worth knowing before treating the alerts as real.

Separately, `MonitoringUnavailable` and the disk/inode rules read
`up{software="SiteRM-NodeExporter"}` and `disk_usage`, which are produced by a
node_exporter on the polling host and reach autogole through the frontend's
`/api/<SITE>/monitoring/prometheus/passthrough/<host>` endpoint. No
node_exporter series exist here yet, so those rules stay silent until the
site-side push path (#26) lands.
