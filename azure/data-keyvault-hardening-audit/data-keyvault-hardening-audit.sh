#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../_lib/audit_common.sh
source "$SCRIPT_DIR/../_lib/audit_common.sh"

SCRIPT_SLUG="data-keyvault-hardening-audit"
REPORT_TITLE="Key Vault Hardening Audit"

usage() {
  cat <<USAGE
Usage: $(basename "$0") --subscriptions <sub1,sub2,...> [options]

Audits Azure Key Vault configuration posture by subscription.

Required:
  --subscriptions <csv>   Comma-separated subscription IDs or names.

Optional:
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

  parse_common_args "$subscriptions_var" "$@" || {
    local status=$?
    if [[ $status -eq 2 ]]; then
      usage
      exit 0
    fi
    exit $status
  }
}

audit_vault() {
  local sub_display="$1"
  local vault_json="$2"

  local id name pna enable_purge enable_soft_delete rbac_enabled default_action bypass
  id="$(echo "$vault_json" | jq -r '.id // "Unknown"')"
  name="$(echo "$vault_json" | jq -r '.name // "Unknown"')"
  pna="$(echo "$vault_json" | jq -r '.properties.publicNetworkAccess // "Enabled"')"
  enable_purge="$(echo "$vault_json" | jq -r '.properties.enablePurgeProtection // false')"
  enable_soft_delete="$(echo "$vault_json" | jq -r '.properties.enableSoftDelete // true')"
  rbac_enabled="$(echo "$vault_json" | jq -r '.properties.enableRbacAuthorization // false')"
  default_action="$(echo "$vault_json" | jq -r '.properties.networkAcls.defaultAction // "Allow"')"
  bypass="$(echo "$vault_json" | jq -r '.properties.networkAcls.bypass // "AzureServices"')"

  local pe_count
  pe_count="$(echo "$vault_json" | jq -r '(.properties.privateEndpointConnections // []) | length')"

  if [[ "$enable_purge" != "true" ]]; then
    append_finding "$sub_display" "$id" "Microsoft.KeyVault/vaults" "$id" \
      "Key Vault purge protection disabled" "high" \
      "name=$name; enablePurgeProtection=$enable_purge" \
      "Enable purge protection on all production and sensitive vaults to mitigate destructive deletion risk."
  else
    append_finding "$sub_display" "$id" "Microsoft.KeyVault/vaults" "$id" \
      "Key Vault purge protection enabled" "info" \
      "name=$name; enablePurgeProtection=$enable_purge" \
      "Maintain purge protection and monitor configuration drift."
  fi

  if [[ "$enable_soft_delete" != "true" ]]; then
    append_finding "$sub_display" "$id" "Microsoft.KeyVault/vaults" "$id" \
      "Key Vault soft delete disabled" "high" \
      "name=$name; enableSoftDelete=$enable_soft_delete" \
      "Enable soft delete for recovery safety and accidental deletion protection."
  fi

  if [[ "$pna" != "Disabled" ]]; then
    append_finding "$sub_display" "$id" "Microsoft.KeyVault/vaults" "$id" \
      "Key Vault public network access enabled" "medium" \
      "name=$name; publicNetworkAccess=$pna; defaultAction=$default_action; bypass=$bypass" \
      "Prefer private endpoint access and disable public network access where possible."
  else
    append_finding "$sub_display" "$id" "Microsoft.KeyVault/vaults" "$id" \
      "Key Vault public network access disabled" "info" \
      "name=$name; publicNetworkAccess=$pna" \
      "Maintain private-only access design."
  fi

  if [[ "$default_action" == "Allow" && "$pna" != "Disabled" ]]; then
    append_finding "$sub_display" "$id" "Microsoft.KeyVault/vaults" "$id" \
      "Key Vault firewall default action allows traffic" "high" \
      "name=$name; defaultAction=$default_action; publicNetworkAccess=$pna" \
      "Set firewall default action to Deny and use explicit allowed networks/private endpoints."
  fi

  if [[ "$rbac_enabled" != "true" ]]; then
    append_finding "$sub_display" "$id" "Microsoft.KeyVault/vaults" "$id" \
      "Key Vault uses access policy model (non-RBAC)" "low" \
      "name=$name; enableRbacAuthorization=$rbac_enabled" \
      "Standardize on RBAC authorization for consistent governance and PIM workflows where feasible."
  else
    append_finding "$sub_display" "$id" "Microsoft.KeyVault/vaults" "$id" \
      "Key Vault uses RBAC authorization" "info" \
      "name=$name; enableRbacAuthorization=$rbac_enabled" \
      "Keep RBAC role assignments least-privileged and time-bound."
  fi

  if [[ "$pe_count" -eq 0 ]]; then
    append_finding "$sub_display" "$id" "Microsoft.KeyVault/vaults" "$id" \
      "Key Vault has no private endpoint connections" "medium" \
      "name=$name; privateEndpointConnections=$pe_count" \
      "Add private endpoint connectivity for sensitive vaults and disable public access."
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

  log_info "Auditing Key Vault posture in subscription: $display"

  local vaults
  vaults="$(az keyvault list --subscription "$sub_id" -o json 2>/dev/null || echo '[]')"

  echo "$vaults" | jq -c '.[]' | while IFS= read -r vault; do
    audit_vault "$display" "$vault"
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
