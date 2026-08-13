#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../_lib/audit_common.sh
source "$SCRIPT_DIR/../_lib/audit_common.sh"

SCRIPT_SLUG="monitor-diagnostic-settings-coverage"
REPORT_TITLE="Diagnostic Settings Coverage Audit"

RESOURCE_TYPES="Microsoft.KeyVault/vaults,Microsoft.Storage/storageAccounts,Microsoft.Web/sites,Microsoft.Sql/servers,Microsoft.Network/networkSecurityGroups"

usage() {
  cat <<USAGE
Usage: $(basename "$0") --subscriptions <sub1,sub2,...> [options]

Audits diagnostic settings coverage for selected resource types.

Required:
  --subscriptions <csv>   Comma-separated subscription IDs or names.

Optional:
  --resource-types <csv>  Resource types to inspect.
                          Default: $RESOURCE_TYPES
  --output-dir <path>     Directory for report files (default: current dir).
  --format <markdown|json|both>
                          Report format (default: markdown).
  --fail-on-high          Exit non-zero if any high finding is present.
  --verbose               Print debug information.
  -h, --help              Show help.
USAGE
}

parse_args() {
  local subscriptions_var="$1"
  shift

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --resource-types)
        [[ $# -lt 2 ]] && { log_error "--resource-types requires a value"; exit 1; }
        RESOURCE_TYPES="$2"
        shift 2
        ;;
      *)
        break
        ;;
    esac
  done

  parse_common_args "$subscriptions_var" "$@" || {
    local status=$?
    if [[ $status -eq 2 ]]; then
      usage
      exit 0
    fi
    exit $status
  }
}

audit_resource_diag() {
  local sub_display="$1"
  local resource_json="$2"

  local id name type
  id="$(echo "$resource_json" | jq -r '.id')"
  name="$(echo "$resource_json" | jq -r '.name')"
  type="$(echo "$resource_json" | jq -r '.type')"

  local diag
  diag="$(az monitor diagnostic-settings list --resource "$id" -o json 2>/dev/null || echo '{"value":[]}')"

  local count
  count="$(echo "$diag" | jq -r '.value | length')"

  if [[ "$count" -eq 0 ]]; then
    append_finding "$sub_display" "$id" "$type" "$id" \
      "No diagnostic settings configured" "high" \
      "resource=$name; diagnosticSettings=0" \
      "Configure diagnostic settings to send logs and metrics to Log Analytics/Event Hub/Storage as required."
    return
  fi

  local has_dest
  has_dest="$(echo "$diag" | jq -r '[.value[] | select((.workspaceId != null and .workspaceId != "") or (.eventHubAuthorizationRuleId != null and .eventHubAuthorizationRuleId != "") or (.storageAccountId != null and .storageAccountId != ""))] | length')"

  if [[ "$has_dest" -eq 0 ]]; then
    append_finding "$sub_display" "$id" "$type" "$id" \
      "Diagnostic settings exist but no destination configured" "high" \
      "resource=$name; diagnosticSettings=$count; validDestinations=0" \
      "Update diagnostic settings with a valid destination to avoid telemetry loss."
  else
    append_finding "$sub_display" "$id" "$type" "$id" \
      "Diagnostic settings configured" "info" \
      "resource=$name; diagnosticSettings=$count; validDestinations=$has_dest" \
      "Maintain baseline and validate category coverage against detection requirements."
  fi
}

audit_subscription() {
  local sub="$1"

  local sub_id sub_name
  sub_id="$(az account show --subscription "$sub" --query id -o tsv 2>/dev/null || true)"
  sub_name="$(az account show --subscription "$sub" --query name -o tsv 2>/dev/null || true)"

  if [[ -z "$sub_id" ]]; then
    log_warn "Unable to resolve subscription: $sub"
    return
  fi

  local display
  display="${sub_name:-$sub_id}"

  log_info "Auditing diagnostic settings in subscription: $display"

  local type
  IFS=',' read -r -a types <<< "$RESOURCE_TYPES"
  for type in "${types[@]}"; do
    type="$(echo "$type" | xargs)"
    [[ -z "$type" ]] && continue

    local resources
    resources="$(az resource list --subscription "$sub_id" --resource-type "$type" -o json 2>/dev/null || echo '[]')"

    echo "$resources" | jq -c '.[]' | while IFS= read -r resource; do
      audit_resource_diag "$display" "$resource"
    done
  done
}

main() {
  ensure_base_deps
  register_cleanup_trap

  local subscriptions=()
  parse_args subscriptions "$@"

  init_audit_run "$SCRIPT_SLUG"

  local sub
  for sub in "${subscriptions[@]}"; do
    audit_subscription "$sub"
  done

  emit_reports "$REPORT_TITLE" "$SCRIPT_SLUG" "${subscriptions[@]}"
}

main "$@"
