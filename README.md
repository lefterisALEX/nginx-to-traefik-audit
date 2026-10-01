# nginx -> traefik annotation audit

Scans every Ingress in one or more clusters and reports which
`nginx.ingress.kubernetes.io/*` annotations are **unsupported**, which are
**supported with remarks/limitations**, and which are **unknown** (not in the
mapping). Useful when migrating from ingress-nginx to Traefik.

## Files

| File | Purpose |
| --- | --- |
| `check-nginx-annotations.sh` | The scanner. |
| `annotation-map.txt` | Annotation mapping (`status|annotation|note`). |
| `kubeconfigs/` | Put your per-cluster kubeconfig files here (e.g. `dev-cluster.yaml`). |
| `reports/` | Generated reports (created automatically). |
| `test-ingresses.yaml` | 40-Ingress fixture covering every category, for testing. |

## Requirements

- `bash` (works in Git Bash on Windows, bash 4.3+)
- `kubectl` in `PATH`
- a kubeconfig file per cluster

## Usage

Audit a single cluster:

```bash
./check-nginx-annotations.sh kubeconfigs/dev-cluster.yaml
```

Audit every cluster in a directory (all `*.yaml` / `*.yml` inside it):

```bash
./check-nginx-annotations.sh kubeconfigs
```

Audit a directory and also merge all per-cluster reports into one CSV:

```bash
./check-nginx-annotations.sh --merge kubeconfigs
```

Equivalent manual loop, if you prefer:

```bash
for f in kubeconfigs/*.yaml; do
    echo "=== $f ==="
    ./check-nginx-annotations.sh "$f" || echo "FAILED: $f"
done
```

When given a directory the script processes each kubeconfig in turn and
continues past failures, exiting non-zero at the end if any cluster failed.

## Output

For an input `kubeconfigs/dev-cluster.yaml` the script writes
`reports/dev-cluster-annotations-report.csv`. Override the output directory
with `REPORTS_DIR`:

```bash
REPORTS_DIR=out ./check-nginx-annotations.sh kubeconfigs/dev-cluster.yaml
```

### CSV report

`context,namespace,ingress,annotation,status,note`

The `status` column is `unsupported`, `remark`, `supported`, or `unknown`.

With `--values`, an extra `value` column holds each annotation's value:

```bash
./check-nginx-annotations.sh --values kubeconfigs
```

`context,namespace,ingress,annotation,status,note,value`

Fields containing commas, quotes, or newlines are quoted per RFC 4180.

### Merged report

With `--merge`, every per-cluster CSV is concatenated (header written once)
into `reports/all-clusters-annotations-report.csv`. The `context` column keeps
the clusters distinguishable. Override the path with `MERGED_OUT`:

```bash
MERGED_OUT=out/all.csv ./check-nginx-annotations.sh --merge kubeconfigs
```

## Annotation mapping

`annotation-map.txt` is line-based:

```
status|annotation|note
```

- `status` is `unsupported`, `remark`, or `supported`
- `note` is optional free text (e.g. a short clarification)
- lines starting with `#` and blank lines are ignored

`remark` means the annotation is supported by Traefik but has limitations; the
limitation text is intentionally not stored here (refer to the migration
guide). If the same annotation is listed under two different statuses the
script prints a `WARNING` while loading the map.

Override the mapping file with `MAP_FILE`:

```bash
MAP_FILE=/path/to/other-map.txt ./check-nginx-annotations.sh kubeconfigs/dev-cluster.yaml
```

## Testing

Apply the fixture to a cluster and run the scanner:

```bash
kubectl --kubeconfig kubeconfigs/dev-cluster.yaml apply -f test-ingresses.yaml
./check-nginx-annotations.sh kubeconfigs/dev-cluster.yaml
kubectl --kubeconfig kubeconfigs/dev-cluster.yaml delete -f test-ingresses.yaml
```

### Behaviour tests

`tests/proxy-connect-timeout/` verifies how ingress-nginx and Traefik actually
handle the `nginx.ingress.kubernetes.io/proxy-connect-timeout` annotation. It
deploys a "blackhole" backend whose TCP SYNs are dropped and measures how long
each controller waits before returning 504:

```bash
tests/proxy-connect-timeout/run.sh kubeconfigs/dev-cluster.yaml --install
```

Traefik is installed with **only** the Kubernetes Ingress NGINX provider
(`providers.kubernetesIngressNGINX`, controller class `k8s.io/ingress-nginx`),
so it reads the same nginx annotations. Expected outcome: both controllers
honour the annotation and return after the configured timeout.

The defaults differ when no annotation is present: ingress-nginx uses **5s**
per attempt, Traefik's ingress-nginx provider uses **60s** per attempt. Both
retry 3 times by default (`proxy-next-upstream-tries: 3`), so the fixture sets
`proxy-next-upstream: "off"` to measure a single attempt.

#### Manual testing with curl

Deploy the playground (blackhole backend + one ingress-nginx and one Traefik
Ingress, both class `nginx`):

```bash
kubectl --kubeconfig kubeconfigs/dev-cluster.yaml apply -f tests/proxy-connect-timeout/manual.yaml
kubectl -n connect-timeout wait --for=condition=Ready pod -l app=blackhole --timeout=120s
```

Forward both controllers to local ports (two terminals):

```bash
kubectl --kubeconfig kubeconfigs/dev-cluster.yaml -n ingress-nginx port-forward svc/ingress-nginx-controller 8080:80
kubectl --kubeconfig kubeconfigs/dev-cluster.yaml -n traefik port-forward svc/traefik 8081:80
```

Then probe each (the request hangs until the connect timeout fires):

```bash
curl -s -o /dev/null -w 'nginx   http=%{http_code} time=%{time_total}s\n' \
  -H 'Host: nginx-connect.example.com'   http://127.0.0.1:8080/
curl -s -o /dev/null -w 'traefik http=%{http_code} time=%{time_total}s\n' \
  -H 'Host: traefik-connect.example.com' http://127.0.0.1:8081/
```

Change the timeout and re-apply to see the measured time follow:

```bash
kubectl -n connect-timeout annotate ingress blackhole-nginx \
  nginx.ingress.kubernetes.io/proxy-connect-timeout=10 --overwrite
```

#### Relevant nginx annotations

`proxy-connect-timeout`, `proxy-send-timeout`, `proxy-read-timeout`,
`proxy-next-upstream`, `proxy-next-upstream-tries`, `proxy-next-upstream-timeout`
(see `annotation-map.txt` for the full list and status). The Traefik
ingress-nginx provider maps these too.

#### Changing the defaults

- ingress-nginx, global: set the key on the controller ConfigMap
  (`kubectl -n ingress-nginx edit configmap ingress-nginx-controller`, e.g.
  `proxy-connect-timeout: "10"`), or `helm upgrade ... --set
  controller.config.proxy-connect-timeout="10"`. Default is **5s** (v1.15.x,
  `ProxyConnectTimeout: 5`).
- ingress-nginx, per Ingress: the `proxy-connect-timeout` annotation.
- Traefik ingress-nginx provider, global:
  `--providers.kubernetesingressnginx.proxyconnecttimeout` (default **60s**),
  plus the matching `proxyreadtimeout` / `proxysendtimeout` /
  `proxynextupstream` / `proxynextupstreamtries` / `proxynextupstreamtimeout`.
  Helm: `--set providers.kubernetesIngressNGINX.proxyConnectTimeout=10`.
- Traefik ingress-nginx provider, per Ingress: the same
  `nginx.ingress.kubernetes.io/proxy-connect-timeout` annotation.



