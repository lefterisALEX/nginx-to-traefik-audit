#!/usr/bin/env bash
#
# check-nginx-annotations.sh
#
# Scans every Ingress in a cluster (via a kubeconfig file) and reports usage of
# nginx.ingress.kubernetes.io/* annotations, classified against annotation-map.txt.
#
# Usage:
#   ./check-nginx-annotations.sh <kubeconfig.yaml>     # single cluster
#   ./check-nginx-annotations.sh <kubeconfigs-dir>     # every *.yaml/*.yml in the dir
#   ./check-nginx-annotations.sh --merge <dir>         # also merge all reports into one CSV
#
# Examples:
#   ./check-nginx-annotations.sh kubeconfigs/dev-cluster.yaml
#     -> writes reports/dev-cluster-annotations-report.csv
#   ./check-nginx-annotations.sh kubeconfigs
#     -> loops over kubeconfigs/*.yaml and writes one report per cluster
#   ./check-nginx-annotations.sh --merge kubeconfigs
#     -> as above, plus reports/all-clusters-annotations-report.csv
#
# The mapping file can be overridden with the MAP_FILE environment variable,
# the output directory with REPORTS_DIR, the merged filename with MERGED_OUT.
# Works in Git Bash on Windows (bash 4+ / kubectl required).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAP_FILE="${MAP_FILE:-$SCRIPT_DIR/annotation-map.txt}"
ANNOTATION_PREFIX="nginx.ingress.kubernetes.io/"
REPORTS_DIR="${REPORTS_DIR:-reports}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [--merge] <kubeconfig.yaml | kubeconfigs-dir>

Scans all Ingress objects in the cluster described by <kubeconfig.yaml> and
reports which nginx.ingress.kubernetes.io/* annotations are unsupported or
carry remarks (see $MAP_FILE).

If a directory is given, every *.yaml / *.yml kubeconfig inside it is processed
in turn (one report per cluster). Pass --merge to also write a single CSV that
concatenates every per-cluster report.

Outputs (under ./reports, override with REPORTS_DIR):
  reports/<name>-annotations-report.csv
  reports/all-clusters-annotations-report.csv   (with --merge)

Environment:
  MAP_FILE    mapping file (default: $SCRIPT_DIR/annotation-map.txt)
  REPORTS_DIR output directory (default: reports)
  MERGED_OUT  merged CSV path (default: REPORTS_DIR/all-clusters-annotations-report.csv)
EOF
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# Number of elements in an (associative) array, safe under `set -u`
# even when the array has never had an element assigned.
arr_count() {
    local -n ref="$1"
    if [[ ${ref[@]+set} ]]; then
        printf '%s' "${#ref[@]}"
    else
        printf '0'
    fi
}

# --- argument handling -------------------------------------------------------
MERGE=0
positional=()
for arg in "$@"; do
    case "$arg" in
        -h|--help) usage; exit 0 ;;
        --merge)   MERGE=1 ;;
        -*)        die "unknown option: $arg" ;;
        *)         positional+=("$arg") ;;
    esac
done

if [[ "${#positional[@]}" -ne 1 ]]; then
    usage >&2
    exit 1
fi

TARGET="${positional[0]}"

[[ -f "$MAP_FILE" ]] || die "annotation map not found: $MAP_FILE"
command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"
mkdir -p "$REPORTS_DIR"

MERGED_OUT="${MERGED_OUT:-$REPORTS_DIR/all-clusters-annotations-report.csv}"

# --- load mapping (once, shared by every cluster) ----------------------------
declare -A STATUS NOTE
while IFS='|' read -r raw_status raw_ann raw_note || [[ -n "${raw_status:-}" ]]; do
    raw_status="$(trim "${raw_status:-}")"
    raw_ann="$(trim "${raw_ann:-}")"
    raw_note="$(trim "${raw_note:-}")"

    [[ -z "$raw_status" || "$raw_status" == \#* ]] && continue
    [[ -z "$raw_ann" ]] && continue

    if [[ -n "${STATUS[$raw_ann]:-}" && "${STATUS[$raw_ann]}" != "$raw_status" ]]; then
        printf 'WARNING: %s listed as both %s and %s in %s\n' \
            "$raw_ann" "${STATUS[$raw_ann]}" "$raw_status" "$MAP_FILE" >&2
    fi

    STATUS["$raw_ann"]="$raw_status"
    NOTE["$raw_ann"]="$raw_note"
done < "$MAP_FILE"

# scratch files reused across clusters, cleaned up on exit
tmp_ing="$(mktemp)"
tmp_hits="$(mktemp)"
trap 'rm -f "$tmp_ing" "$tmp_hits"' EXIT
produced_csvs=()

# --- process one kubeconfig --------------------------------------------------
process_kubeconfig() {
    local kubeconfig="$1"
    local base csv_out
    base="$(basename "$kubeconfig")"
    base="${base%.yaml}"
    base="${base%.yml}"
    csv_out="$REPORTS_DIR/$base-annotations-report.csv"

    if ! kubectl --kubeconfig "$kubeconfig" get ingress -A \
            -o go-template='{{range .items}}{{$ing := .}}{{range $k, $v := .metadata.annotations}}{{$ing.metadata.namespace}}{{"|"}}{{$ing.metadata.name}}{{"|"}}{{$k}}{{"|"}}{{$v}}{{"\n"}}{{end}}{{end}}' \
            > "$tmp_ing" 2>/dev/null; then
        printf 'ERROR: kubectl failed to list ingresses using %s\n' "$kubeconfig" >&2
        return 1
    fi

    local total_ingress
    total_ingress="$(kubectl --kubeconfig "$kubeconfig" get ingress -A --no-headers 2>/dev/null | grep -c . || true)"

    awk -F'|' -v pfx="$ANNOTATION_PREFIX" '$3 ~ ("^" pfx)' "$tmp_ing" > "$tmp_hits" || true

    local -A unsup_ing remark_ing unknown_ing
    local csv_rows=""
    local ns name ann value status note key

    if [[ -s "$tmp_hits" ]]; then
        while IFS='|' read -r ns name ann value; do
            status="${STATUS[$ann]:-}"
            note="${NOTE[$ann]:-}"
            key="$ns/$name"

            case "$status" in
                unsupported) unsup_ing["$key"]=1 ;;
                remark)      remark_ing["$key"]=1 ;;
                supported)   : ;; # explicitly supported; nothing to report
                *)           status="unknown"; unknown_ing["$key"]=1 ;;
            esac

            csv_rows+="$base,$ns,$name,$ann,$status,$note"$'\n'
        done < "$tmp_hits"
    fi

    {
        echo "context,namespace,ingress,annotation,status,note"
        printf '%s' "$csv_rows"
    } > "$csv_out"
    produced_csvs+=("$csv_out")

    printf 'Scanned %s ingress(es) with kubeconfig: %s\n' "$total_ingress" "$kubeconfig"
    printf '  unsupported annotations : %s ingress(es)\n' "$(arr_count unsup_ing)"
    printf '  remarks                 : %s ingress(es)\n' "$(arr_count remark_ing)"
    printf '  unknown (not in map)    : %s ingress(es)\n' "$(arr_count unknown_ing)"
    printf '  report                  : %s\n' "$csv_out"
}

# --- dispatch: single file or directory loop ---------------------------------
failures=0

if [[ -d "$TARGET" ]]; then
    shopt -s nullglob
    files=("$TARGET"/*.yaml "$TARGET"/*.yml)
    shopt -u nullglob

    if [[ "${#files[@]}" -eq 0 ]]; then
        die "no .yaml/.yml kubeconfig files found in: $TARGET"
    fi

    for f in "${files[@]}"; do
        printf '=== %s ===\n' "$f"
        if ! process_kubeconfig "$f"; then
            failures=$((failures + 1))
        fi
        echo
    done
elif [[ -f "$TARGET" ]]; then
    process_kubeconfig "$TARGET" || failures=1
else
    die "kubeconfig file or directory not found: $TARGET"
fi

# --- optional merge of all per-cluster reports -------------------------------
if [[ "$MERGE" -eq 1 ]]; then
    if [[ "${#produced_csvs[@]}" -eq 0 ]]; then
        printf 'WARNING: --merge requested but no reports were produced\n' >&2
    else
        {
            echo "context,namespace,ingress,annotation,status,note"
            for c in "${produced_csvs[@]}"; do
                tail -n +2 "$c"
            done
        } > "$MERGED_OUT"
        printf 'Merged report: %s\n' "$MERGED_OUT"
    fi
fi

[[ "$failures" -eq 0 ]] || die "$failures kubeconfig(s) failed"
