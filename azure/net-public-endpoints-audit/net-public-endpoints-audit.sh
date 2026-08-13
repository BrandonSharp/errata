#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../_lib/audit_common.sh
source "$SCRIPT_DIR/../_lib/audit_common.sh"

SCRIPT_SLUG="net-public-endpoints-audit"
REPORT_TITLE="Network Public Endpoints Audit"
CHECK_APP_SERVICES=true
CHECK_STORAGE=true

usage() {
  cat <<USAGE
Usage: $(basename "$0") --subscriptions <sub1,sub2,...> [options]

Audits internet-facing surface across selected Azure resource classes.

Required:
  --subscriptions <csv>   Comma-separated subscription IDs or names.

Optional:
  --skip-app-services     Skip App Service public access checks.
  --skip-storage          Skip Storage account public exposure checks.
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
      --skip-app-services)
        CHECK_APP_SERVICES=false
        shift
        ;;
      --skip-storage)
        CHECK_STORAGE=false
        shift
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

audit_public_ips() {
  local sub_id="$1"
  local sub_display="$2"

  local pips
  pips="$(az network public-ip list --subscription "$sub_id" -o json 2>/dev/null || echo '[]')"

  echo "$pips" | jq -c '.[]' | while IFS= read -r pip; do
    local id name ipaddr allocation sku zones
    id="$(echo "$pip" | jq -r '.id // "Unknown"')"
    name="$(echo "$pip" | jq -r '.name // "Unknown"')"
    ipaddr="$(echo "$pip" | jq -r '.ipAddress // "Unassigned"')"
    allocation="$(echo "$pip" | jq -r '.publicIPAllocationMethod // "Unknown"')"
    sku="$(echo "$pip" | jq -r '.sku.name // "Unknown"')"
    zones="$(echo "$pip" | jq -r '(.zones // []) | join(",")')"

    local severity finding recommendation evidence
    severity="high"
    finding="Public IP address present"
    recommendation="Confirm business necessity, enforce NSG/Azure Firewall controls, and remove unused public IPs."
    evidence="name=$name; ip=$ipaddr; allocation=$allocation; sku=$sku; zones=${zones:-none}"

    append_finding "$sub_display" "/subscriptions/$sub_id" "Microsoft.Network/publicIPAddresses" "$id" "$finding" "$severity" "$evidence" "$recommendation"
  done
}

audit_app_services() {
  local sub_id="$1"
  local sub_display="$2"

  local apps
  apps="$(az webapp list --subscription "$sub_id" -o json 2>/dev/null || echo '[]')"

  echo "$apps" | jq -c '.[]' | while IFS= read -r app; do
    local id name state default_host
    id="$(echo "$app" | jq -r '.id // "Unknown"')"
    name="$(echo "$app" | jq -r '.name // "Unknown"')"
    state="$(echo "$app" | jq -r '.state // "Unknown"')"
    default_host="$(echo "$app" | jq -r '.defaultHostName // "Unknown"')"

    local pna ip_restriction_count
    pna="$(az webapp show --ids "$id" --query 'publicNetworkAccess' -o tsv 2>/dev/null || echo "Unknown")"
    ip_restriction_count="$(az webapp config access-restriction show --ids "$id" --query 'ipSecurityRestrictions | length(@)' -o tsv 2>/dev/null || echo "0")"

    local severity finding recommendation evidence
    if [[ "$pna" == "Disabled" ]]; then
      severity="info"
      finding="App Service public network access disabled"
      recommendation="Keep public access disabled and maintain private endpoint or trusted ingress design."
    elif [[ "$ip_restriction_count" == "0" ]]; then
      severity="high"
      finding="App Service potentially internet-reachable without access restrictions"
      recommendation="Apply access restrictions and/or private endpoints, and front with approved ingress controls (WAF, APIM)."
    else
      severity="medium"
      finding="App Service has public access with IP restrictions"
      recommendation="Review restriction rules for least privilege and remove broad allow entries."
    fi

    evidence="name=$name; state=$state; host=$default_host; publicNetworkAccess=$pna; ipRestrictions=$ip_restriction_count"
    append_finding "$sub_display" "/subscriptions/$sub_id" "Microsoft.Web/sites" "$id" "$finding" "$severity" "$evidence" "$recommendation"
  done
}

audit_storage_accounts() {
  local sub_id="$1"
  local sub_display="$2"

  local stores
  stores="$(az storage account list --subscription "$sub_id" -o json 2>/dev/null || echo '[]')"

  echo "$stores" | jq -c '.[]' | while IFS= read -r st; do
    local id name pna allow_blob_public
    id="$(echo "$st" | jq -r '.id // "Unknown"')"
    name="$(echo "$st" | jq -r '.name // "Unknown"')"
    pna="$(echo "$st" | jq -r '.publicNetworkAccess // "Unknown"')"
    allow_blob_public="$(echo "$st" | jq -r '.allowBlobPublicAccess // false')"

    local severity finding recommendation evidence
    if [[ "$allow_blob_public" == "true" ]]; then
      severity="high"
      finding="Storage account allows blob public access"
      recommendation="Disable blob public access unless explicitly required and documented."
    elif [[ "$pna" != "Disabled" ]]; then
      severity="medium"
      finding="Storage account permits public network access"
      recommendation="Restrict public network access and prefer private endpoints with firewall allowlists."
    else
      severity="info"
      finding="Storage account public network access disabled"
      recommendation="Maintain private-only access model and monitor for drift."
    fi

    evidence="name=$name; publicNetworkAccess=$pna; allowBlobPublicAccess=$allow_blob_public"
    append_finding "$sub_display" "/subscriptions/$sub_id" "Microsoft.Storage/storageAccounts" "$id" "$finding" "$severity" "$evidence" "$recommendation"
  done
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

  log_info "Auditing network exposure in subscription: $display"
  audit_public_ips "$sub_id" "$display"

  if [[ "$CHECK_APP_SERVICES" == "true" ]]; then
    audit_app_services "$sub_id" "$display"
  fi

  if [[ "$CHECK_STORAGE" == "true" ]]; then
    audit_storage_accounts "$sub_id" "$display"
  fi
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
