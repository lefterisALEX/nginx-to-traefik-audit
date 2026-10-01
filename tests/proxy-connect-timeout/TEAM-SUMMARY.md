# ingress-nginx -> Traefik: configuration differences (for teams)

The platform runs **Traefik with the Kubernetes Ingress NGINX provider**, so
your existing `nginx.ingress.kubernetes.io/*` annotations keep working. This is
a summary of where the two controllers differ so you know what to expect.

## What this means for you

- Your annotations still apply (see the table below).
- Traefik is configured globally to match ingress-nginx defaults; that config is
  platform-owned, not part of your Ingress.
- Two behaviours genuinely differ — `proxy-read-timeout` and
  `proxy-buffer-size` (flagged in the Caveat column).

## Configuration at a glance

The table below shows the known differences between ingress-nginx and Traefik
for the proxy settings teams use most often. The **Annotation** column lists the
`nginx.ingress.kubernetes.io/*` key you set on your Ingress (same key works on
both controllers). The **Traefik** column reflects the platform's global
configuration. The **Caveat** column flags anything that is not fully
equivalent, so pay attention to those rows.

| Behaviour | Annotation (`nginx.ingress.kubernetes.io/`) | ingress-nginx | Traefik (platform config) | Caveat |
|---|---|---|---|---|
| connect timeout | `proxy-connect-timeout` | default 5s; retried 3x | 5s; retried 3x | none |
| read timeout | `proxy-read-timeout` | default 60s; retried 3x (up to 180s) | 60s; **no retry** | nginx retries read timeouts, Traefik does not |
| send timeout | `proxy-send-timeout` | default 60s; single attempt; returns `504` | 60s; single attempt; default returns `502` | default: nginx `504` vs Traefik `502`; with the annotation set, both `504` |
| body size | `proxy-body-size` | 1m; **always** enforced (`413`) | 1m; enforced **only because platform enables request buffering** | Traefik ignores `proxy-body-size` when request buffering is off (returns `200`, no `413`); with it on, both enforce `413` |
| response header buffer | `proxy-buffer-size` | 4k buffer for the response **status line + headers**; larger -> `502` | sizes the response **body** buffer, **not** headers; large headers accepted | large response headers: nginx `502` (unless raised), Traefik `200` |
| upstream retries | `proxy-next-upstream` | `error timeout` | mirrored | Traefik only retries connect-phase failures |
| retry count | `proxy-next-upstream-tries` | 3 | 3 | applies to connect only on Traefik |
| retry time budget | `proxy-next-upstream-timeout` | 0 | 0 | none |
| response buffer count | `proxy-buffers-number` | 4 | 4 | body buffer on Traefik, not headers |
| request buffering | `proxy-request-buffering` | on | on | required for `proxy-body-size` enforcement on Traefik |
| response buffering | `proxy-buffering` | off | off | none |
| client request header size | none (ConfigMap `large-client-header-buffers`) | `4 32K` (~32K) | ~64K | >32K differs (`400` vs `431`) |
| strict path type | none (ConfigMap `strict-validate-path-type`) | `true` | `true` | matches |

## Caveats

1. **`proxy-read-timeout` is not equivalent.** nginx retries a read timeout up
   to 3 times (a 60s timeout can take up to 180s); Traefik does not retry read
   timeouts (stops at 60s). If your app depends on the retry ceiling, it will
   behave differently on Traefik.

2. **`proxy-buffer-size` is not equivalent.** nginx uses `proxy_buffer_size` as
   the buffer for the response **status line + headers**; with the 4k default,
   any response whose headers exceed 4k returns
   `502 upstream sent too big header`. Traefik's provider maps `proxy-buffer-size`
   to its response **body** buffering (`proxy-buffering`), not the header buffer,
   so it does not affect header handling at all. Traefik (Go) accepts much larger
   response headers, so the same response returns `200`:

   | Response headers | ingress-nginx (default 4k) | ingress-nginx (`proxy-buffer-size: "32k"`) | Traefik |
   |---|---|---|---|
   | 2 KiB | `200` | `200` | `200` |
   | 16 KiB | `502` | `200` | `200` |

   Impact: if you raised `proxy-buffer-size` to stop nginx `502`ing on large
   response headers, that workaround is unnecessary on Traefik. Conversely, a
   response that failed with `502` on nginx will now succeed on Traefik. The
   platform cannot lower Traefik's header limit to match nginx's 4k.

3. **Retries only cover connect failures on Traefik.** `proxy-next-upstream` /
   `proxy-next-upstream-tries` are set to match nginx, but Traefik retries
   connect-phase failures only — not read/send timeouts.

4. **`proxy-body-size` is only enforced by Traefik when request buffering is
   on.** nginx always applies `client_max_body_size` (`proxy-body-size`). Traefik
   applies the limit through its request-buffering middleware, so with request
   buffering off (Traefik's default) an oversized upload is **streamed and
   accepted** — you get `200`, not `413`. The platform enables it globally
   (`proxy-request-buffering: on`), after which both controllers behave the same:

   | Body | `proxy-body-size` | ingress-nginx | Traefik (buffering off) | Traefik (buffering on) |
   |---|---|---|---|---|
   | 512 KiB | default (1m) | `200` | `200` | `200` |
   | 2 MiB | default (1m) | `413` | `200` (not enforced) | `413` |
   | 512 KiB | `"100k"` | `413` | `200` (not enforced) | `413` |

   Side effect: with request buffering on, the whole body is read and buffered
   by the proxy before it is forwarded to your backend (same as nginx's default
   `proxy_request_buffering: on`). Large uploads are therefore fully received by
   the proxy first, using memory/temp storage.

## Status codes

| Situation | ingress-nginx | Traefik |
|---|---|---|
| upstream timeout (read) | `504` | `504` |
| upstream timeout (send, default) | `504` | `502` |
| upstream timeout (send, `proxy-send-timeout` set) | `504` | `504` |
| request body too large | `413` | `413` |
| oversized client request header | `400` | `431` |
| large response header | `502` | `200` (accepted) |

## If something breaks

- Client request headers larger than **32K**: nginx rejects (`400`), Traefik
  accepts up to ~64K.
- Response headers larger than **4k**: nginx returns `502` unless
  `proxy-buffer-size` is raised; Traefik accepts them.
- Relying on read-timeout retries: Traefik no longer retries these.

Contact the platform team for platform-level changes (controller config, not
per-Ingress annotations).
