#!/usr/bin/env bash
#
# proxy-connect-timeout behaviour test
#
# Deploys a "blackhole" backend whose TCP/80 SYNs are DROPPED, exposes it
# through both ingress-nginx and Traefik, and measures how long each controller
# waits before returning 504. This shows whether the nginx annotation
# `nginx.ingress.kubernetes.io/proxy-connect-timeout` is honoured.
#
# Traefik runs with the Kubernetes Ingress NGINX provider
# (providers.kubernetesIngressNGINX) only, so it reads the same nginx annotations.
#
# Expected result:
#   ingress-nginx : honours the annotation -> 504 after ~CONNECT_TIMEOUT seconds
#   traefik       : its ingress-nginx provider honours it too -> ~CONNECT_TIMEOUT
#
# The defaults differ: with no annotation ingress-nginx uses 5s per attempt,
# Traefik's ingress-nginx provider uses 60s per attempt.
#
# Usage:
#   tests/proxy-connect-timeout/run.sh <kubeconfig.yaml> [options]
#
# Options:
#   --install            install ingress-nginx + Traefik via helm first
#   --uninstall          remove the controllers afterwards (implies keeping ns gone)
#   --timeout <seconds>  value of proxy-connect-timeout to test (default 3)
#   --keep               leave the test namespace (and controllers) in place
#   -h, --help           show help
#
# Environment:
#   CONNECT_TIMEOUT           same as --timeout        (default 3)
#   NGINX_PORT / TRAEFIK_PORT local port-forward ports (default 18080 / 18081)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="connect-timeout"
NGINX_NS="ingress-nginx"
TRAEFIK_NS="traefik"

CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-3}"
NGINX_PORT="${NGINX_PORT:-18080}"
TRAEFIK_PORT="${TRAEFIK_PORT:-18081}"
NGINX_HOST="nginx-connect.example.com"
TRAEFIK_HOST="traefik-connect.example.com"

INSTALL=0
UNINSTALL=0
KEEP=0
KUBECONFIG_FILE=""

usage() {
    awk 'NR==1{next} /^set -euo/{exit} {print}' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --install)   INSTALL=1 ;;
        --uninstall) UNINSTALL=1 ;;
        --keep)      KEEP=1 ;;
        --timeout)   shift; CONNECT_TIMEOUT="${1:?--timeout needs a value}" ;;
        -h|--help)   usage 0 ;;
        -*)          die "unknown option: $1" ;;
        *)           [[ -n "$KUBECONFIG_FILE" ]] && die "unexpected argument: $1"
                     KUBECONFIG_FILE="$1" ;;
    esac
    shift
done

[[ -n "$KUBECONFIG_FILE" ]] || usage 1
[[ -f "$KUBECONFIG_FILE" ]] || die "kubeconfig not found: $KUBECONFIG_FILE"
command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"
command -v curl    >/dev/null 2>&1 || die "curl not found in PATH"

kubectl() { command kubectl --kubeconfig "$KUBECONFIG_FILE" "$@"; }

PF_PIDS=()
cleanup() {
    local rc=$?
    for pid in "${PF_PIDS[@]:-}"; do
        [[ -n "${pid:-}" ]] && kill "$pid" >/dev/null 2>&1 || true
    done
    if [[ "$KEEP" -eq 0 ]]; then
        kubectl delete namespace "$NS" --ignore-not-found >/dev/null 2>&1 || true
        if [[ "$UNINSTALL" -eq 1 ]]; then
            helm uninstall ingress-nginx -n "$NGINX_NS" >/dev/null 2>&1 || true
            helm uninstall traefik      -n "$TRAEFIK_NS" >/dev/null 2>&1 || true
        fi
    fi
    exit "$rc"
}
trap cleanup EXIT INT TERM

render() { sed "s/__CONNECT_TIMEOUT__/${CONNECT_TIMEOUT}/g" "$1"; }

install_controllers() {
    command -v helm >/dev/null 2>&1 || die "--install requires helm in PATH"
    printf 'Adding/updating helm repos...\n'
    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
    helm repo add traefik https://traefik.github.io/charts >/dev/null 2>&1 || true
    helm repo update >/dev/null 2>&1 || true

    printf 'Installing ingress-nginx (scoped to %s)...\n' "$NS"
    helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
        -n "$NGINX_NS" --create-namespace \
        --set controller.service.type=ClusterIP \
        --set controller.admissionWebhooks.enabled=false \
        --set controller.scope.enabled=true \
        --set "controller.scope.namespace=$NS" \
        --wait --timeout 5m >/dev/null

    printf 'Installing Traefik (Kubernetes Ingress NGINX provider only)...\n'
    helm upgrade --install traefik traefik/traefik \
        -n "$TRAEFIK_NS" --create-namespace \
        --set service.type=ClusterIP \
        --set providers.kubernetesIngress.enabled=false \
        --set providers.kubernetesCRD.enabled=false \
        --set providers.kubernetesIngressNGINX.enabled=true \
        --set providers.kubernetesIngressNGINX.ingressClass=nginx \
        --wait --timeout 5m >/dev/null || true

    kubectl -n "$NGINX_NS"   rollout status deploy/ingress-nginx-controller --timeout=180s
    kubectl -n "$TRAEFIK_NS" rollout status deploy/traefik --timeout=180s
}

# wait until a local port-forward answers HTTP (any status code counts).
wait_local_port() {
    local port="$1" deadline=$((SECONDS + 30))
    while (( SECONDS < deadline )); do
        if curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$port/" 2>/dev/null; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# probe returns "<http_code> <seconds>"; retries while the ingress is not yet
# programmed (404) or unreachable (000).
probe() {
    local port="$1" host="$2" max="$3"
    local out code elapsed deadline=$((SECONDS + 30))
    while (( SECONDS < deadline )); do
        out="$(curl -s -o /dev/null -w '%{http_code} %{time_total}' \
            --max-time "$max" -H "Host: $host" "http://127.0.0.1:$port/" || true)"
        code="${out%% *}"; elapsed="${out##* }"
        if [[ "$code" == "502" || "$code" == "504" ]]; then
            printf '%s %s' "$code" "$elapsed"
            return 0
        fi
        sleep 2
    done
    printf '%s %s' "${code:-000}" "${elapsed:-0}"
}

# within <value> <target> <tol>
within() { awk -v v="$1" -v t="$2" -v tol="$3" 'BEGIN{ d=v-t; if(d<0)d=-d; exit !(d<=tol) }'; }

failures=0
report() {
    local name="$1" ok="$2" detail="$3"
    if [[ "$ok" == "0" ]]; then
        printf '  [PASS] %-14s %s\n' "$name" "$detail"
    else
        printf '  [FAIL] %-14s %s\n' "$name" "$detail"
        failures=$((failures + 1))
    fi
}

printf 'proxy-connect-timeout behaviour test\n'
printf '  kubeconfig : %s\n' "$KUBECONFIG_FILE"
printf '  annotation : proxy-connect-timeout=%ss\n\n' "$CONNECT_TIMEOUT"

# 1. backend + namespace
kubectl apply -f "$SCRIPT_DIR/backend.yaml" >/dev/null
kubectl -n "$NS" wait --for=condition=Ready pod -l app=blackhole --timeout=180s >/dev/null

# 2. install controllers if requested
if [[ "$INSTALL" -eq 1 ]]; then
    install_controllers
fi

# 3. ingresses
render "$SCRIPT_DIR/ingress-nginx.yaml"   | kubectl apply -f - >/dev/null
render "$SCRIPT_DIR/ingress-traefik.yaml" | kubectl apply -f - >/dev/null
sleep 3

# 4. port-forward both controllers
kubectl -n "$NGINX_NS"   port-forward svc/ingress-nginx-controller "$NGINX_PORT:80"   >/dev/null 2>&1 &
PF_PIDS+=("$!")
kubectl -n "$TRAEFIK_NS" port-forward svc/traefik                  "$TRAEFIK_PORT:80" >/dev/null 2>&1 &
PF_PIDS+=("$!")
wait_local_port "$NGINX_PORT"   || die "ingress-nginx port-forward not reachable"
wait_local_port "$TRAEFIK_PORT" || die "traefik port-forward not reachable"

# 5. measure
nginx_result="$(probe "$NGINX_PORT"   "$NGINX_HOST"   $((CONNECT_TIMEOUT + 15)))"
traefik_result="$(probe "$TRAEFIK_PORT" "$TRAEFIK_HOST" $((CONNECT_TIMEOUT + 15)))"

nginx_code="${nginx_result%% *}";   nginx_time="${nginx_result##* }"
traefik_code="${traefik_result%% *}"; traefik_time="${traefik_result##* }"

printf 'Results:\n'
printf '  %-14s HTTP %s after %ss\n' "ingress-nginx" "$nginx_code" "$nginx_time"
printf '  %-14s HTTP %s after %ss\n\n' "traefik" "$traefik_code" "$traefik_time"

# 6. assertions
printf 'Assertions:\n'
if [[ "$nginx_code" == "504" ]]; then
    report "nginx status" 0 "504 as expected"
else
    report "nginx status" 1 "expected 504, got $nginx_code"
fi
if within "$nginx_time" "$CONNECT_TIMEOUT" 2; then
    report "nginx timeout" 0 "honoured annotation (~${CONNECT_TIMEOUT}s)"
else
    report "nginx timeout" 1 "expected ~${CONNECT_TIMEOUT}s, got ${nginx_time}s"
fi

if [[ "$traefik_code" == "504" ]]; then
    report "traefik status" 0 "504 as expected"
else
    report "traefik status" 1 "expected 504, got $traefik_code"
fi
if within "$traefik_time" "$CONNECT_TIMEOUT" 2; then
    report "traefik timeout" 0 "honoured annotation (~${CONNECT_TIMEOUT}s)"
else
    report "traefik timeout" 1 "expected ~${CONNECT_TIMEOUT}s, got ${traefik_time}s"
fi

echo
if [[ "$failures" -eq 0 ]]; then
    printf 'ALL ASSERTIONS PASSED\n'
else
    printf '%s ASSERTION(S) FAILED\n' "$failures"
    exit 1
fi
