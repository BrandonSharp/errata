#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../_lib/audit_common.sh
source "$SCRIPT_DIR/../_lib/audit_common.sh"

SCRIPT_SLUG="backup-coverage-audit"
REPORT_TITLE="Backup Coverage Audit"

usage() {
  cat <<USAGE
Usage: $(basename "$0") --subscriptions <sub1,sub2,...> [options]

Audits backup coverage for Azure virtual machines using Recovery Services data.

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

normalize_vm_id() {
  local value="$1"
  echo "$value" | tr '[:upper:]' '[:lower:]'
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

  log_info "Auditing VM backup coverage in subscription: $display"

  local vms
  vms="$(az vm list --subscription "$sub_id" -o json 2>/dev/null || echo '[]')"

  local backup_items_all='[]'
  local vaults
  vaults="$(az backup vault list --subscription "$sub_id" -o json 2>/dev/null || echo '[]')"

  echo "$vaults" | jq -c '.[]' | while IFS= read -r vault; do
    local vault_name rg
    vault_name="$(echo "$vault" | jq -r '.name')"
    rg="$(echo "$vault" | jq -r '.resourceGroup')"

    local items
    items="$(az backup item list --subscription "$sub_id" --resource-group "$rg" --vault-name "$vault_name" --backup-management-type AzureIaasVM -o json 2>/dev/null || echo '[]')"

    backup_items_all="$(jq -cn --argjson left "$backup_items_all" --argjson right "$items" '$left + $right')"

    echo "$items" | jq -c '.[]' | while IFS= read -r item; do
      local source_id health id
      source_id="$(echo "$item" | jq -r '.properties.sourceResourceId // ""')"
      health="$(echo "$item" | jq -r '.properties.healthStatus // "Unknown"')"
      id="$(echo "$item" | jq -r '.id // "Unknown"')"

      if [[ -n "$source_id" ]]; then
        local sev
        if [[ "$health" == "Healthy" ]]; then
          sev="info"
        else
          sev="medium"
        fi

        append_finding "$display" "/subscriptions/$sub_id" "Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers/protectedItems" "$id" \
          "VM backup item present" "$sev" \
          "sourceResourceId=$source_id; healthStatus=$health; vault=$vault_name" \
          "Investigate unhealthy protected items and ensure backup policy compliance."
      fi
    done
  done

  local protected_ids_tmp
  protected_ids_tmp="$(mktemp)"
  AUDIT_TMP_FILES+=("$protected_ids_tmp")
  echo "$backup_items_all" | jq -r '.[] | .properties.sourceResourceId // empty | ascii_downcase' | sort -u > "$protected_ids_tmp"

  echo "$vms" | jq -c '.[]' | while IFS= read -r vm; do
    local vm_id vm_name
    vm_id="$(echo "$vm" | jq -r '.id')"
    vm_name="$(echo "$vm" | jq -r '.name')"

    local vm_id_norm
    vm_id_norm="$(normalize_vm_id "$vm_id")"

    if grep -Fxq "$vm_id_norm" "$protected_ids_tmp"; then
      append_finding "$display" "$vm_id" "Microsoft.Compute/virtualMachines" "$vm_id" \
        "VM appears protected by Recovery Services backup" "info" \
        "vmName=$vm_name; backupCoverage=protected" \
        "Maintain backup policy compliance and periodic restore validation."
    else
      append_finding "$display" "$vm_id" "Microsoft.Compute/virtualMachines" "$vm_id" \
        "VM has no detected Recovery Services backup item" "high" \
        "vmName=$vm_name; backupCoverage=not-detected" \
        "Enable VM backup policy or document approved exception for this workload."
    fi
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
