#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

SUBSCRIPTIONS=""
OUTPUT_DIR=""
FORMAT="both"
FAIL_ON_HIGH=false
VERBOSE=false
RUN_TAG=""

SCRIPT_PATHS=(
  "$REPO_ROOT/azure/iam-rbac-owner-contributor-audit/iam-rbac-owner-contributor-audit.sh"
  "$REPO_ROOT/azure/net-public-endpoints-audit/net-public-endpoints-audit.sh"
  "$REPO_ROOT/azure/data-keyvault-hardening-audit/data-keyvault-hardening-audit.sh"
  "$REPO_ROOT/azure/monitor-diagnostic-settings-coverage/monitor-diagnostic-settings-coverage.sh"
  "$REPO_ROOT/azure/backup-coverage-audit/backup-coverage-audit.sh"
)

usage() {
  cat <<USAGE
Usage: $(basename "$0") --subscriptions <sub1,sub2,...> [options]

Runs the initial Azure evaluation script kit in sequence and stores all outputs in one bundle directory.

Required:
  --subscriptions <csv>   Comma-separated subscription IDs or names.

Optional:
  --output-dir <path>     Parent directory for the bundle (default: ./reports).
  --format <markdown|json|both>
                          Report format passed to each script (default: both).
  --fail-on-high          Propagate non-zero exit when a child script finds high severity issues.
  --verbose               Enable verbose mode in child scripts.
  --run-tag <value>       Custom bundle suffix instead of UTC timestamp.
  -h, --help              Show help.
USAGE
}

log_info() {
  echo "[INFO] $*"
}

log_warn() {
  echo "[WARN] $*" >&2
}

log_error() {
  echo "[ERROR] $*" >&2
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || {
    log_error "Required command not found: $cmd"
    exit 1
  }
}

join_by() {
  local delim="$1"
  shift
  local first=1
  local item
  for item in "$@"; do
    if [[ $first -eq 1 ]]; then
      printf "%s" "$item"
      first=0
    else
      printf "%s%s" "$delim" "$item"
    fi
  done
}

slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//'
}

timestamp_utc() {
  date -u +"%Y%m%d_%H%M%S"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --subscriptions)
        [[ $# -lt 2 ]] && { log_error "--subscriptions requires a value"; exit 1; }
        SUBSCRIPTIONS="$2"
        shift 2
        ;;
      --output-dir)
        [[ $# -lt 2 ]] && { log_error "--output-dir requires a value"; exit 1; }
        OUTPUT_DIR="$2"
        shift 2
        ;;
      --format)
        [[ $# -lt 2 ]] && { log_error "--format requires a value"; exit 1; }
        FORMAT="$2"
        shift 2
        ;;
      --fail-on-high)
        FAIL_ON_HIGH=true
        shift
        ;;
      --verbose)
        VERBOSE=true
        shift
        ;;
      --run-tag)
        [[ $# -lt 2 ]] && { log_error "--run-tag requires a value"; exit 1; }
        RUN_TAG="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        log_error "Unknown option: $1"
        usage
        exit 1
        ;;
    esac
  done

  if [[ -z "$SUBSCRIPTIONS" ]]; then
    log_error "--subscriptions is required"
    usage
    exit 1
  fi

  case "$FORMAT" in
    markdown|json|both)
      ;;
    *)
      log_error "Invalid --format '$FORMAT'. Use markdown, json, or both."
      exit 1
      ;;
  esac
}

script_label_from_path() {
  local script_path="$1"
  basename "$(dirname "$script_path")"
}

run_child_script() {
  local script_path="$1"
  local bundle_dir="$2"
  local script_label
  script_label="$(script_label_from_path "$script_path")"

  local child_dir
  child_dir="$bundle_dir/$script_label"
  mkdir -p "$child_dir"

  local args=(--subscriptions "$SUBSCRIPTIONS" --output-dir "$child_dir" --format "$FORMAT")
  if [[ "$FAIL_ON_HIGH" == "true" ]]; then
    args+=(--fail-on-high)
  fi
  if [[ "$VERBOSE" == "true" ]]; then
    args+=(--verbose)
  fi

  log_info "Running $script_label"
  if "$script_path" "${args[@]}"; then
    log_info "$script_label completed successfully"
    return 0
  else
    local exit_code=$?
    log_warn "$script_label exited with status $exit_code"
    return "$exit_code"
  fi
}

main() {
  require_cmd bash
  require_cmd date

  parse_args "$@"

  local bundle_root
  bundle_root="${OUTPUT_DIR:-$REPO_ROOT/reports}"
  mkdir -p "$bundle_root"

  local bundle_name
  if [[ -n "$RUN_TAG" ]]; then
    bundle_name="initial-eval_${RUN_TAG}"
  else
    bundle_name="initial-eval_$(timestamp_utc)"
  fi

  local bundle_dir
  bundle_dir="$bundle_root/$bundle_name"
  mkdir -p "$bundle_dir"

  local subs_csv
  IFS=',' read -r -a subs_array <<< "$SUBSCRIPTIONS"
  subs_csv="$(join_by "," "${subs_array[@]}")"

  {
    echo "# Azure Initial Evaluation Run"
    echo
    echo "**Generated (UTC):** $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    echo "**Bundle:** $bundle_name"
    echo "**Subscriptions:** $subs_csv"
    echo "**Format:** $FORMAT"
    echo
    echo "## Scripts"
    for script_path in "${SCRIPT_PATHS[@]}"; do
      echo "- $(basename "$script_path")"
    done
  } > "$bundle_dir/README.md"

  local overall_exit=0
  local script_path script_label
  for script_path in "${SCRIPT_PATHS[@]}"; do
    script_label="$(script_label_from_path "$script_path")"
    if [[ ! -x "$script_path" ]]; then
      log_error "Script is not executable: $script_path"
      overall_exit=1
      continue
    fi

    if ! run_child_script "$script_path" "$bundle_dir"; then
      overall_exit=1
    fi
  done

  echo
  if [[ "$overall_exit" -eq 0 ]]; then
    log_info "Initial evaluation bundle complete: $bundle_dir"
  else
    log_warn "Initial evaluation bundle completed with one or more script failures: $bundle_dir"
  fi

  return "$overall_exit"
}

main "$@"
