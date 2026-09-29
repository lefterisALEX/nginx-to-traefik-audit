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
