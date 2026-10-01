# Test runbook: one-by-one (ingress-nginx vs Traefik)

How to test each proxy behaviour against your own cluster, one test at a time.
You have **one ingress-nginx controller** and **one Traefik** (running the
Kubernetes Ingress NGINX provider). Both read Ingresses of class `nginx`.

Do not change ingress-nginx. Configure Traefik only if you haven't already.

## 0. Set your endpoints

Point these at whatever reaches each controller (LoadBalancer IP, NodePort, or
`kubectl port-forward`). No trailing slash.

```bash
export K=~/.kube/config                       # your kubeconfig
export NGINX=http://192.168.1.10              # ingress-nginx endpoint
export TRAEFIK=http://192.168.1.11            # traefik endpoint
```

Quick sanity check after deploying (see below): each should answer `200`/`404`.

## 1. Configure Traefik (once)

```bash
helm upgrade --install traefik traefik/traefik -n traefik --create-namespace \
  -f tests/proxy-connect-timeout/traefik-values.yaml
```

Confirm the provider is active:

```bash
kubectl --kubeconfig $K -n traefik get deploy traefik \
  -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ' ' '\n' | grep nginx
```

## 2. Deploy all fixtures (once)

```bash
kubectl --kubeconfig $K apply \
  -f tests/proxy-connect-timeout/backend.yaml \
  -f tests/proxy-connect-timeout/backend-read.yaml \
  -f tests/proxy-connect-timeout/backend-send.yaml \
  -f tests/proxy-connect-timeout/backend-hello.yaml \
  -f tests/proxy-connect-timeout/manual.yaml \
  -f tests/proxy-connect-timeout/ingress-read.yaml \
  -f tests/proxy-connect-timeout/ingress-send.yaml \
  -f tests/proxy-connect-timeout/ingress-hello.yaml

kubectl --kubeconfig $K -n connect-timeout wait --for=condition=Ready pod --all --timeout=300s
```

Backends: `blackhole` (connect), `blackhole-read` (read), `blackhole-send`
(send), `hello` (body/buffer). All fixtures start **without** annotations.

For each test below: run it **without** the annotation first, then add the
annotation to both Ingresses, run again, then remove the annotation.

Helper to add/remove an annotation on a test's two Ingresses:

```bash
# set:    add_ann <ingress-suffix> <key=value>
# remove: add_ann <ingress-suffix> <key>-
add_ann() {
  kubectl --kubeconfig $K -n connect-timeout annotate ingress \
    "$1-nginx" "nginx.ingress.kubernetes.io/$2" --overwrite
  kubectl --kubeconfig $K -n connect-timeout annotate ingress \
    "$1-traefik" "nginx.ingress.kubernetes.io/$2" --overwrite
}
```

---

## Test 1 - connect timeout

Backend drops SYNs, so the connect hangs.

```bash
curl -s -o /dev/null -w 'connect nginx   %{http_code} %{time_total}s\n' --max-time 40 \
  -H 'Host: nginx-connect.example.com'   $NGINX/
curl -s -o /dev/null -w 'connect traefik %{http_code} %{time_total}s\n' --max-time 40 \
  -H 'Host: traefik-connect.example.com' $TRAEFIK/
```

With annotation:

```bash
add_ann blackhole proxy-connect-timeout=3
# (wait ~5s, re-run the two curls)
add_ann blackhole proxy-connect-timeout-
```

Expected (retries on): no annotation nginx `5x3=15s`, traefik `5x3=15s`;
with `=3` both `3x3=9s`.

## Test 2 - read timeout

Backend accepts then stalls.

```bash
curl -s -o /dev/null -w 'read nginx   %{http_code} %{time_total}s\n' --max-time 220 \
  -H 'Host: read-nginx.example.com'   $NGINX/
curl -s -o /dev/null -w 'read traefik %{http_code} %{time_total}s\n' --max-time 220 \
  -H 'Host: read-traefik.example.com' $TRAEFIK/
```

With annotation:

```bash
add_ann read proxy-read-timeout=7
# (re-run)
add_ann read proxy-read-timeout-
```

Expected: no annotation nginx ~180s (60x3), traefik ~60s; with `=7` nginx ~21s
(7x3), traefik ~7s. **This is the known difference** (nginx retries read
timeouts, Traefik does not).

## Test 3 - send timeout

Backend accepts but never reads; POST a body so the proxy blocks writing.

```bash
head -c 262144 /dev/zero > /tmp/body.bin
curl -s -o /dev/null -w 'send nginx   %{http_code} %{time_total}s\n' --max-time 120 \
  -X POST --data-binary @/tmp/body.bin -H 'Expect:' \
  -H 'Host: send-nginx.example.com'   $NGINX/
curl -s -o /dev/null -w 'send traefik %{http_code} %{time_total}s\n' --max-time 120 \
  -X POST --data-binary @/tmp/body.bin -H 'Expect:' \
  -H 'Host: send-traefik.example.com' $TRAEFIK/
```

With annotation:

```bash
add_ann send proxy-send-timeout=5
# (re-run)
add_ann send proxy-send-timeout-
```

Expected: no annotation nginx `504` @60s, traefik `502` @60s; with `=5` both
`504` @5s.

## Test 4 - body size

Fast backend; POST > 1m default.

```bash
head -c 2097152 /dev/zero > /tmp/body2m.bin
curl -s -o /dev/null -w 'body nginx   %{http_code}\n' --max-time 30 \
  -X POST --data-binary @/tmp/body2m.bin -H 'Expect:' -H 'Host: hello-nginx.example.com'   $NGINX/
curl -s -o /dev/null -w 'body traefik %{http_code}\n' --max-time 30 \
  -X POST --data-binary @/tmp/body2m.bin -H 'Expect:' -H 'Host: hello-traefik.example.com' $TRAEFIK/
```

With annotation:

```bash
add_ann hello proxy-body-size=10m
# (re-run) -> both accept the 2 MiB body
add_ann hello proxy-body-size-
```

Expected: no annotation both `413`; with `=10m` both `200`.
(Requires `proxyRequestBuffering=true` in Traefik; otherwise Traefik returns
`200` even at default — that is the difference it fixes.)

## Test 5 - response header buffer

Fast backend returns a 16 KiB response header on `/bighdr`.

```bash
curl -s -o /dev/null -w 'buf nginx   %{http_code}\n' --max-time 30 \
  -H 'Host: hello-nginx.example.com'   $NGINX/bighdr
curl -s -o /dev/null -w 'buf traefik %{http_code}\n' --max-time 30 \
  -H 'Host: hello-traefik.example.com' $TRAEFIK/bighdr
```

With annotation:

```bash
add_ann hello proxy-buffer-size=32k
# (re-run)
add_ann hello proxy-buffer-size-
```

Expected: no annotation nginx `502`, traefik `200`; with `=32k` both `200`.
**Known difference** (nginx 4k header buffer vs Traefik tolerates large headers).

---

## Results template

Measured on `homelabs` (2026-09-30):

| Test | Annotation | ingress-nginx | Traefik |
|---|---|---|---|
| connect | none | `504` @ 15.22s | `504` @ 15.15s |
| connect | `proxy-connect-timeout=3` | `504` @ 9.28s | `504` @ 9.04s |
| read | none | `504` @ 180.03s | `504` @ 60.05s |
| read | `proxy-read-timeout=7` | `504` @ 21.04s | `504` @ 7.09s |
| send | none | `504` @ 60.23s | `502` @ 60.20s |
| send | `proxy-send-timeout=5` | `504` @ 5.15s | `504` @ 5.22s |
| body | none | `413` | `413` |
| body | `proxy-body-size=10m` | `200` | `200` |
| buffer | none | `502` | `200` |
| buffer | `proxy-buffer-size=32k` | `200` | `200` |

Summary: connect, send (timing) and body-size match. Read and response header
buffer differ (nginx retries read timeouts and has a 4k header buffer; Traefik
does neither).

## Notes

- `-H 'Host: ...'` selects the Ingress rule; the TCP connection goes to your
  endpoint, independent of the hostname.
- Remove all test annotations when done (each `add_ann ...-` above does this).
- Cleanup: `kubectl --kubeconfig $K delete namespace connect-timeout`.
