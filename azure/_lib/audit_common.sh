#!/usr/bin/env bash
# Shared helpers for Azure assessment scripts.

set -euo pipefail

COMMON_SCRIPT_NAME="$(basename "${0:-script}")"
AUDIT_TMP_FILES=()
AUDIT_FINDINGS_FILE=""
AUDIT_OUTPUT_DIR=""
AUDIT_REPORT_BASENAME=""
AUDIT_FORMAT="markdown"
AUDIT_FAIL_ON_HIGH=false
AUDIT_VERBOSE=false

HIGH_WEIGHT=20
MEDIUM_WEIGHT=7
LOW_WEIGHT=2
INFO_WEIGHT=0

log_info() {
  echo "[INFO] $*"
}

log_warn() {
  echo "[WARN] $*" >&2
}

log_error() {
  echo "[ERROR] $*" >&2
}

log_debug() {
  if [[ "${AUDIT_VERBOSE}" == "true" ]]; then
    echo "[DEBUG] $*"
  fi
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || {
    log_error "Required command not found: $cmd"
    exit 1
  }
}

ensure_base_deps() {
  require_cmd az
  require_cmd jq
  require_cmd date
}

safe_slug() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//'
}

join_by() {
  local delim="$1"
  shift
  local first=1
  for item in "$@"; do
    if [[ $first -eq 1 ]]; then
      printf "%s" "$item"
      first=0
    else
      printf "%s%s" "$delim" "$item"
    fi
  done
}

timestamp_utc() {
  date -u +"%Y%m%d_%H%M%S"
}

iso_now_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

parse_common_args() {
  local subscriptions_ref="$1"
  shift
  local -n _subscriptions="$subscriptions_ref"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --subscriptions)
        [[ $# -lt 2 ]] && { log_error "--subscriptions requires a value"; exit 1; }
        IFS=',' read -r -a _subscriptions <<< "$2"
        shift 2
        ;;
      --output-dir)
        [[ $# -lt 2 ]] && { log_error "--output-dir requires a value"; exit 1; }
        AUDIT_OUTPUT_DIR="$2"
        shift 2
        ;;
      --format)
        [[ $# -lt 2 ]] && { log_error "--format requires a value"; exit 1; }
        AUDIT_FORMAT="$2"
        shift 2
        ;;
      --fail-on-high)
        AUDIT_FAIL_ON_HIGH=true
        shift
        ;;
      --verbose)
        AUDIT_VERBOSE=true
        shift
        ;;
      --help|-h)
        return 2
        ;;
      --)
        shift
        break
        ;;
      *)
        break
        ;;
    esac
  done

  case "$AUDIT_FORMAT" in
    markdown|json|both)
      ;;
    *)
      log_error "Invalid --format '$AUDIT_FORMAT'. Use: markdown, json, or both."
      exit 1
      ;;
  esac

  if [[ ${#_subscriptions[@]} -eq 0 ]]; then
    log_error "At least one subscription must be provided via --subscriptions."
    exit 1
  fi

  local i
  for i in "${!_subscriptions[@]}"; do
    _subscriptions[$i]="$(echo "${_subscriptions[$i]}" | xargs)"
  done
}

init_audit_run() {
  local script_slug="$1"
  local output_dir="${AUDIT_OUTPUT_DIR:-$PWD}"
  mkdir -p "$output_dir"

  AUDIT_REPORT_BASENAME="${script_slug}_$(timestamp_utc)"
  AUDIT_FINDINGS_FILE="$(mktemp)"
  AUDIT_TMP_FILES+=("$AUDIT_FINDINGS_FILE")
}

cleanup_audit_tmp() {
  local f
  for f in "${AUDIT_TMP_FILES[@]:-}"; do
    [[ -f "$f" ]] && rm -f "$f"
  done
}

register_cleanup_trap() {
  trap cleanup_audit_tmp EXIT
}

append_finding_json() {
  local finding_json="$1"
  echo "$finding_json" >> "$AUDIT_FINDINGS_FILE"
}

append_finding() {
  local subscription="$1"
  local scope="$2"
  local resource_type="$3"
  local resource_id="$4"
  local finding="$5"
  local severity="$6"
  local evidence="$7"
  local recommendation="$8"

  append_finding_json "$(jq -cn \
    --arg subscription "$subscription" \
    --arg scope "$scope" \
    --arg resourceType "$resource_type" \
    --arg resourceId "$resource_id" \
    --arg finding "$finding" \
    --arg severity "$severity" \
    --arg evidence "$evidence" \
    --arg recommendation "$recommendation" \
    '{
      subscription: $subscription,
      scope: $scope,
      resourceType: $resourceType,
      resourceId: $resourceId,
      finding: $finding,
      severity: $severity,
      evidence: $evidence,
      recommendation: $recommendation
    }')"
}

findings_as_array_json() {
  if [[ ! -s "$AUDIT_FINDINGS_FILE" ]]; then
    echo '[]'
    return
  fi
  jq -s '.' "$AUDIT_FINDINGS_FILE"
}

severity_counts_json() {
  findings_as_array_json | jq '{
    high: map(select(.severity == "high")) | length,
    medium: map(select(.severity == "medium")) | length,
    low: map(select(.severity == "low")) | length,
    info: map(select(.severity == "info")) | length,
    total: length
  }'
}

compute_risk_score() {
  local counts_json="$1"
  local weighted
  weighted="$(echo "$counts_json" | jq -r \
    --argjson highW "$HIGH_WEIGHT" \
    --argjson medW "$MEDIUM_WEIGHT" \
    --argjson lowW "$LOW_WEIGHT" \
    --argjson infoW "$INFO_WEIGHT" \
    '(.high * $highW) + (.medium * $medW) + (.low * $lowW) + (.info * $infoW)')"

  if [[ "$weighted" -gt 100 ]]; then
    echo 100
  else
    echo "$weighted"
  fi
}

risk_level_from_score() {
  local score="$1"
  if (( score >= 75 )); then
    echo "critical"
  elif (( score >= 50 )); then
    echo "high"
  elif (( score >= 25 )); then
    echo "medium"
  else
    echo "low"
  fi
}

write_json_report() {
  local title="$1"
  local subscriptions_csv="$2"
  local script_name="$3"
  local counts_json="$4"
  local score="$5"
  local findings_file="$6"
  local output_path="$7"

  local findings_array_file
  findings_array_file="$(mktemp)"
  jq -s '.' "$findings_file" > "$findings_array_file"

  jq -cn \
    --arg title "$title" \
    --arg generatedAt "$(iso_now_utc)" \
    --arg subscriptions "$subscriptions_csv" \
    --arg scriptName "$script_name" \
    --argjson counts "$counts_json" \
    --argjson score "$score" \
    --arg riskLevel "$(risk_level_from_score "$score")" \
    --slurpfile findings "$findings_array_file" \
    '{
      title: $title,
      generatedAt: $generatedAt,
      script: $scriptName,
      subscriptions: ($subscriptions | split(",") | map(select(length > 0))),
      summary: ($counts + {riskScore: $score, riskLevel: $riskLevel}),
      findings: $findings[0]
    }' > "$output_path"

  rm -f "$findings_array_file"
}

write_markdown_report() {
  local title="$1"
  local subscriptions_csv="$2"
  local counts_json="$3"
  local score="$4"
  local findings_file="$5"
  local output_path="$6"

  local high medium low info total risk_level
  high="$(echo "$counts_json" | jq -r '.high')"
  medium="$(echo "$counts_json" | jq -r '.medium')"
  low="$(echo "$counts_json" | jq -r '.low')"
  info="$(echo "$counts_json" | jq -r '.info')"
  total="$(echo "$counts_json" | jq -r '.total')"
  risk_level="$(risk_level_from_score "$score")"

  {
    echo "# $title"
    echo
    echo "**Generated (UTC):** $(iso_now_utc)"
    echo "**Subscriptions:** $subscriptions_csv"
    echo
    echo "## Summary"
    echo
    echo "- Total findings: $total"
    echo "- High: $high"
    echo "- Medium: $medium"
    echo "- Low: $low"
    echo "- Info: $info"
    echo "- Risk score (0-100): $score"
    echo "- Risk level: $risk_level"
    echo
    echo "## Findings"
    echo
    echo "| Severity | Subscription | Scope | Resource Type | Finding | Evidence | Recommendation |"
    echo "|----------|--------------|-------|---------------|---------|----------|----------------|"

    jq -s -r '
      sort_by((if .severity=="high" then 0 elif .severity=="medium" then 1 elif .severity=="low" then 2 else 3 end), .subscription, .resourceType, .finding)
      | .[]
      | [
          .severity,
          .subscription,
          .scope,
          .resourceType,
          .finding,
          .evidence,
          .recommendation
        ]
      | map((. // "N/A") | tostring | gsub("\\|"; "\\\\|") | gsub("\n"; " "))
      | "| " + join(" | ") + " |"
    ' "$findings_file"
  } > "$output_path"
}

emit_reports() {
  local title="$1"
  local script_slug="$2"
  shift 2
  local subscriptions=("$@")

  local subscriptions_csv
  subscriptions_csv="$(join_by "," "${subscriptions[@]}")"

  local counts_json score
  counts_json="$(severity_counts_json)"
  score="$(compute_risk_score "$counts_json")"

  local md_path json_path
  md_path="${AUDIT_OUTPUT_DIR:-$PWD}/${AUDIT_REPORT_BASENAME}.md"
  json_path="${AUDIT_OUTPUT_DIR:-$PWD}/${AUDIT_REPORT_BASENAME}.json"

  case "$AUDIT_FORMAT" in
    markdown)
      write_markdown_report "$title" "$subscriptions_csv" "$counts_json" "$score" "$AUDIT_FINDINGS_FILE" "$md_path"
      log_info "Markdown report: $md_path"
      ;;
    json)
      write_json_report "$title" "$subscriptions_csv" "$script_slug" "$counts_json" "$score" "$AUDIT_FINDINGS_FILE" "$json_path"
      log_info "JSON report: $json_path"
      ;;
    both)
      write_markdown_report "$title" "$subscriptions_csv" "$counts_json" "$score" "$AUDIT_FINDINGS_FILE" "$md_path"
      write_json_report "$title" "$subscriptions_csv" "$script_slug" "$counts_json" "$score" "$AUDIT_FINDINGS_FILE" "$json_path"
      log_info "Markdown report: $md_path"
      log_info "JSON report: $json_path"
      ;;
  esac

  local high_count
  high_count="$(echo "$counts_json" | jq -r '.high')"
  if [[ "$AUDIT_FAIL_ON_HIGH" == "true" && "$high_count" -gt 0 ]]; then
    log_warn "High severity findings detected ($high_count); exiting non-zero due to --fail-on-high."
    return 3
  fi
  return 0
}
