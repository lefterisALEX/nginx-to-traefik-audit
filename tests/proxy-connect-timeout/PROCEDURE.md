# Procedure: ingress-nginx -> Traefik proxy behaviour parity

Migrating ingress-nginx -> Traefik. We are the **platform team**: we configure
the controllers globally and do **not** add per-Ingress annotations.

Constraint: **ingress-nginx is frozen**. Its ConfigMap must not be changed
during the migration (the only keys we manage there are
`large-client-header-buffers: "4 32K"` and `strict-validate-path-type: "true"`).
Therefore all tuning is done on the **Traefik** side only.

## Summary

### Changes we must make (Traefik only)

All changes are a single helm override on the Traefik release (full command in
the next section). Required for parity:

| Value | Set to | Why |
|---|---|---|
| `kubernetesIngressNGINX.enabled` | `true` | run the nginx-annotation provider |
| `kubernetesIngress.enabled` / `kubernetesCRD.enabled` | `false` | provider-only mode |
| `proxyConnectTimeout` | `5` | nginx default is 5s, Traefik's is 60s |
| `proxyReadTimeout` / `proxySendTimeout` | `60` | already match nginx |
| `proxyNextUpstream` | `error timeout` | mirror nginx retry policy |
| `proxyNextUpstreamTries` | `3` | mirror nginx retry count |
| `proxyNextUpstreamTimeout` | `0` | mirror nginx |
| `proxyBodySize` | `1048576` | 1m, match nginx |
| `proxyRequestBuffering` | `true` | without it Traefik ignores `proxy-body-size` |
| `service.type` | `NodePort` | lab access only |

**ingress-nginx: no changes.**

### Differences between Traefik and ingress-nginx

| Behaviour | ingress-nginx | Traefik (nginx provider) | Parity after our config? |
|---|---|---|---|
| connect timeout | default 5s; retries connect 3x (`5x3`) | default 60s; retries connect 3x | yes (`proxyConnectTimeout=5`) |
| read timeout | default 60s; **retries read 3x** (`60x3`) | default 60s; **no read retry** (`60x1`) | no — nginx has an x3 ceiling |
| send timeout | default 60s; single attempt | default 60s; single attempt | yes timing (default code: nginx `504`, Traefik `502`) |
| body size | always enforced (`client_max_body_size`) -> `413` | enforced **only** with request buffering | yes (`proxyRequestBuffering=true`) |
| buffer size | 4k header buffer -> `502` on big headers | accepts big headers (`proxyBufferSize` is a *body* buffer) | no — needs an nginx ConfigMap change |
| upstream retries | `proxy-next-upstream: error timeout`, 3 tries | mirrored via provider | yes |
| timeout status code | `504` | `504` (read/annotated), `502` (send default) | minor difference |
| client request header size | `large-client-header-buffers: "4 32K"` (our config) | ~64K (Go server default) | near — ≤32K both accept; >32K differs (`400` vs `431`) |
| strict path type | `strict-validate-path-type: "true"` | `strictValidatePathType` (default `true`) | matches |

Note: the two ingress-nginx ConfigMap values we manage
(`large-client-header-buffers`, `strict-validate-path-type`) do **not** affect
the timeout / body / buffer results. `large-client-header-buffers` only governs
client **request** header size (our buffer-size test used **response** headers,
`proxy_buffer_size`); `strict-validate-path-type` is Ingress admission and
already matches Traefik's default.

Net: **connect, send and body-size can be made equivalent by configuring
Traefik only. Read timeout and buffer size are genuine engine differences** that
cannot be fixed while ingress-nginx is frozen.

## Traefik global configuration

Traefik runs the Kubernetes Ingress NGINX provider only. Config applied:

```bash
export K=~/.kube/homelabs.yaml

helm --kubeconfig $K upgrade traefik traefik/traefik -n traefik --reuse-values \
  --set providers.kubernetesIngress.enabled=false \
  --set providers.kubernetesCRD.enabled=false \
  --set providers.kubernetesIngressNGINX.enabled=true \
  --set providers.kubernetesIngressNGINX.ingressClass=nginx \
  --set providers.kubernetesIngressNGINX.proxyConnectTimeout=5 \
  --set providers.kubernetesIngressNGINX.proxyReadTimeout=60 \
  --set providers.kubernetesIngressNGINX.proxySendTimeout=60 \
  --set-string 'providers.kubernetesIngressNGINX.proxyNextUpstream=error timeout' \
  --set providers.kubernetesIngressNGINX.proxyNextUpstreamTries=3 \
  --set providers.kubernetesIngressNGINX.proxyNextUpstreamTimeout=0 \
  --set providers.kubernetesIngressNGINX.proxyBodySize=1048576 \
  --set providers.kubernetesIngressNGINX.proxyRequestBuffering=true \
  --set service.type=NodePort
```

| Value | Set to | Traefik default | Why |
|---|---|---|---|
| `proxyConnectTimeout` | `5` | `60` | match ingress-nginx default (5s) |
| `proxyReadTimeout` | `60` | `60` | already matches |
| `proxySendTimeout` | `60` | `60` | already matches |
| `proxyNextUpstream` | `error timeout` | `error timeout` | mirror nginx retry policy |
| `proxyNextUpstreamTries` | `3` | `3` | mirror nginx retry count |
| `proxyNextUpstreamTimeout` | `0` | `0` | mirror nginx |
| `proxyBodySize` | `1048576` | `1048576` | 1m, matches nginx |
| `proxyRequestBuffering` | `true` | `false` | required for `proxy-body-size` to be enforced |

ingress-nginx ConfigMap is left as-is (not modified).

## Results

Measured on `homelabs` (2026-09-30), retries on (nginx default 3 tries;
Traefik `proxyNextUpstream=error timeout`).

### proxy-connect-timeout

| Annotation | ingress-nginx | Traefik (nginx provider) | Match |
|---|---|---|---|
| none (default 5s) | `504` @ 15.10s | `504` @ 15.10s | yes |
| `proxy-connect-timeout: "3"` | `504` @ 9.03s | `504` @ 9.03s | yes |

Both retry connect failures 3x, so the time is `value x 3` on both.

### proxy-read-timeout

| Annotation | ingress-nginx | Traefik (nginx provider) | Match |
|---|---|---|---|
| none (default 60s) | `504` @ 180.26s | `504` @ 60.05s | no |
| `proxy-read-timeout: "7"` | `504` @ 21.14s | `504` @ 7.06s | no |

ingress-nginx computes `value x 3` (it retries read timeouts);
Traefik is `value x 1` (it does not retry read timeouts).

### proxy-send-timeout

Triggered with a 256 KiB POST body to a backend that accepts but never reads
(tiny `SO_RCVBUF`), so the proxy blocks while writing the request.

| Annotation | ingress-nginx | Traefik (nginx provider) | Match |
|---|---|---|---|
| none (default 60s) | `504` @ 60.14s | `502` @ 60.03s | timing yes / code differs |
| `proxy-send-timeout: "5"` | `504` @ 5.19s | `504` @ 5.19s | yes |

Both stop at the same time (single attempt — nginx does not multiply send
timeouts by tries). The HTTP status differs on the default (nginx `504`,
Traefik `502`); with an explicit annotation both return `504`.

### proxy-body-size

Fast backend; POST 512 KiB (under default 1m) and 2 MiB (over).

| Annotation | ingress-nginx | Traefik (default) | Traefik (`proxyRequestBuffering=true`) |
|---|---|---|---|
| none (1m), 512 KiB | `200` | `200` | `200` |
| none (1m), 2 MiB | `413` | `200` (not enforced) | `413` |
| `proxy-body-size: "100k"`, 512 KiB | `413` | `200` (not enforced) | `413` |

Traefik's provider only enforces `proxy-body-size` when **request buffering**
is enabled. Fix: `--set providers.kubernetesIngressNGINX.proxyRequestBuffering=true`.

### proxy-buffer-size

Fast backend returning a 16 KiB response header (`GET /bighdr`).

| Annotation | ingress-nginx | Traefik (nginx provider) |
|---|---|---|
| none (nginx default 4k) | `502` (upstream sent too big header) | `200` |
| `proxy-buffer-size: "32k"` | `200` | `200` |

ingress-nginx's default `proxy_buffer_size` is 4k, so response headers larger
than that cause a `502`. Traefik tolerates large response headers (its
`proxyBufferSize` maps to response **body** buffering, not the header buffer),
so it returns `200`. Aligning would require raising nginx's global
`proxy-buffer-size` (a ConfigMap change we must not make).

## Why read differs

`proxy-next-upstream: "error timeout"` makes ingress-nginx retry after a read
timeout (up to 3 tries), so its effective ceiling is `timeout x 3`. Traefik
retries connect failures but **not** read timeouts, so it stops at
`timeout x 1`. For read, config-only parity would require disabling nginx's
retries (a ConfigMap change we must not make) or raising Traefik's read timeout
to `timeout x 3` (which changes the per-attempt semantics and doesn't hold once
an app sets the annotation).

**Conclusion:**
- **connect timeout** — identical via Traefik config (`proxyConnectTimeout=5`).
- **send timeout** — identical timing (only the default HTTP status differs).
- **proxy-body-size** — identical once `proxyRequestBuffering=true`; without it
  Traefik does not enforce the limit at all.
- **proxy-buffer-size** — differs at defaults: nginx's 4k header buffer returns
  `502` for large response headers, Traefik accepts them.
- **read timeout** — cannot be made identical; documented behavioral difference.

## Environment

| | |
|---|---|
| Cluster | `homelabs` (k3s) |
| Kubeconfig | `~/.kube/homelabs.yaml` |
| Node address | `100.110.223.52` (Tailscale) |
| ingress-nginx NodePort (http) | `30244` |
| Traefik NodePort (http) | `30153` |
| Namespace | `connect-timeout` |

## Deploy the test backends

- `blackhole`: drops TCP/80 SYNs, so the **connect** hangs.
- `blackhole-read`: accepts, then stalls, so the wait is in the **read** phase.
- `blackhole-send`: accepts but never reads (tiny `SO_RCVBUF`), so the proxy
  blocks while **sending** a large request body.
- `hello`: fast backend; `POST /` for body-size, `GET /bighdr` for a 16 KiB
  response header (buffer-size).

```bash
kubectl --kubeconfig $K apply -f tests/proxy-connect-timeout/backend.yaml
kubectl --kubeconfig $K apply -f tests/proxy-connect-timeout/backend-read.yaml
kubectl --kubeconfig $K apply -f tests/proxy-connect-timeout/backend-send.yaml
kubectl --kubeconfig $K apply -f tests/proxy-connect-timeout/backend-hello.yaml
kubectl --kubeconfig $K apply -f tests/proxy-connect-timeout/manual.yaml
kubectl --kubeconfig $K apply -f tests/proxy-connect-timeout/ingress-read.yaml
kubectl --kubeconfig $K apply -f tests/proxy-connect-timeout/ingress-send.yaml
kubectl --kubeconfig $K apply -f tests/proxy-connect-timeout/ingress-hello.yaml

kubectl --kubeconfig $K -n connect-timeout wait --for=condition=Ready pod -l app=blackhole --timeout=180s
kubectl --kubeconfig $K -n connect-timeout wait --for=condition=Ready pod -l app=blackhole-read --timeout=240s
kubectl --kubeconfig $K -n connect-timeout wait --for=condition=Ready pod -l app=blackhole-send --timeout=240s
kubectl --kubeconfig $K -n connect-timeout wait --for=condition=Ready pod -l app=hello --timeout=240s
```

## Test with curl

```bash
# connect
curl -s -o /dev/null -w 'connect nginx   http=%{http_code} time=%{time_total}s\n' --max-time 40 \
  -H 'Host: nginx-connect.example.com'   http://100.110.223.52:30244/
curl -s -o /dev/null -w 'connect traefik http=%{http_code} time=%{time_total}s\n' --max-time 40 \
  -H 'Host: traefik-connect.example.com' http://100.110.223.52:30153/

# read
curl -s -o /dev/null -w 'read nginx   http=%{http_code} time=%{time_total}s\n' --max-time 220 \
  -H 'Host: read-nginx.example.com'      http://100.110.223.52:30244/
curl -s -o /dev/null -w 'read traefik http=%{http_code} time=%{time_total}s\n' --max-time 220 \
  -H 'Host: read-traefik.example.com'    http://100.110.223.52:30153/

# send (POST a body)
head -c 262144 /dev/zero > /tmp/body.bin
curl -s -o /dev/null -w 'send nginx   http=%{http_code} time=%{time_total}s\n' --max-time 120 \
  -X POST --data-binary @/tmp/body.bin -H 'Expect:' \
  -H 'Host: send-nginx.example.com'      http://100.110.223.52:30244/
curl -s -o /dev/null -w 'send traefik http=%{http_code} time=%{time_total}s\n' --max-time 120 \
  -X POST --data-binary @/tmp/body.bin -H 'Expect:' \
  -H 'Host: send-traefik.example.com'    http://100.110.223.52:30153/

# body-size (POST a 2 MiB body; default limit is 1m)
head -c 2097152 /dev/zero > /tmp/body2m.bin
curl -s -o /dev/null -w 'body nginx   http=%{http_code}\n' --max-time 30 \
  -X POST --data-binary @/tmp/body2m.bin -H 'Expect:' \
  -H 'Host: hello-nginx.example.com'     http://100.110.223.52:30244/
curl -s -o /dev/null -w 'body traefik http=%{http_code}\n' --max-time 30 \
  -X POST --data-binary @/tmp/body2m.bin -H 'Expect:' \
  -H 'Host: hello-traefik.example.com'   http://100.110.223.52:30153/

# buffer-size (16 KiB response header)
curl -s -o /dev/null -w 'buf nginx   http=%{http_code}\n' --max-time 30 \
  -H 'Host: hello-nginx.example.com'     http://100.110.223.52:30244/bighdr
curl -s -o /dev/null -w 'buf traefik http=%{http_code}\n' --max-time 30 \
  -H 'Host: hello-traefik.example.com'   http://100.110.223.52:30153/bighdr
```

Or via just (connect hosts): `just nginx`, `just traefik`, `just all`.

## Notes

- `-H 'Host: ...'` selects the Ingress rule; the TCP connection goes to the
  node/NodePort, independent of the hostname.
- Cleanup: `kubectl --kubeconfig $K delete namespace connect-timeout`.
