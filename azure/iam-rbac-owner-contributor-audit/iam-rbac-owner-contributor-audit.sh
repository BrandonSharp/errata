#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../_lib/audit_common.sh
source "$SCRIPT_DIR/../_lib/audit_common.sh"

SCRIPT_SLUG="iam-rbac-owner-contributor-audit"
REPORT_TITLE="IAM RBAC Owner/Access Audit"

ROLE_FILTERS_DEFAULT="Owner,User Access Administrator"
ROLE_FILTERS="$ROLE_FILTERS_DEFAULT"
INCLUDE_CONTRIBUTOR=false

usage() {
  cat <<USAGE
Usage: $(basename "$0") --subscriptions <sub1,sub2,...> [options]

Audits high-privilege Azure RBAC assignments by subscription and scope.

Required:
  --subscriptions <csv>   Comma-separated subscription IDs or names.

Optional:
  --roles <csv>           Comma-separated role names to include.
                          Default: ${ROLE_FILTERS_DEFAULT}
  --include-contributor   Also include Contributor assignments.
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
      --roles)
        [[ $# -lt 2 ]] && { log_error "--roles requires a value"; exit 1; }
        ROLE_FILTERS="$2"
        shift 2
        ;;
      --include-contributor)
        INCLUDE_CONTRIBUTOR=true
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

build_role_filter_json() {
  local role_csv="$1"
  if [[ "$INCLUDE_CONTRIBUTOR" == "true" ]]; then
    role_csv+=" ,Contributor"
  fi

  echo "$role_csv" | tr ',' '\n' | sed 's/^ *//; s/ *$//' | awk 'NF' | jq -R . | jq -s 'unique'
}

scope_classification() {
  local scope="$1"
  case "$scope" in
    /subscriptions/*/resourceGroups/*/providers/*)
      echo "resource"
      ;;
    /subscriptions/*/resourceGroups/*)
      echo "resourceGroup"
      ;;
    /subscriptions/*)
      echo "subscription"
      ;;
    /providers/Microsoft.Management/managementGroups/*)
      echo "managementGroup"
      ;;
    *)
      echo "other"
      ;;
  esac
}

principal_severity() {
  local principal_type="$1"
  local scope_type="$2"
  local role_name="$3"

  if [[ "$principal_type" == "User" && ( "$role_name" == "Owner" || "$role_name" == "User Access Administrator" ) ]]; then
    echo "high"
    return
  fi

  if [[ "$scope_type" == "subscription" && "$role_name" == "Owner" ]]; then
    echo "high"
    return
  fi

  if [[ "$principal_type" == "ServicePrincipal" && "$role_name" == "Owner" ]]; then
    echo "high"
    return
  fi

  if [[ "$role_name" == "User Access Administrator" || "$role_name" == "Owner" ]]; then
    echo "medium"
  elif [[ "$role_name" == "Contributor" ]]; then
    echo "low"
  else
    echo "info"
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

  log_info "Scanning RBAC assignments in subscription: ${sub_name:-$sub_id}"

  local roles_json
  roles_json="$(build_role_filter_json "$ROLE_FILTERS")"

  local assignments_json
  assignments_json="$(az role assignment list --subscription "$sub_id" --all \
    --query "[].{roleDefinitionName:roleDefinitionName, principalId:principalId, principalName:principalName, principalType:principalType, scope:scope, id:id}" \
    -o json 2>/dev/null || echo '[]')"

  echo "$assignments_json" | jq -c --argjson roles "$roles_json" '
    map(select(.roleDefinitionName as $r | $roles | index($r)))
    | .[]
  ' | while IFS= read -r assignment; do
    local role_name principal_name principal_type scope assignment_id principal_id
    role_name="$(echo "$assignment" | jq -r '.roleDefinitionName // "Unknown"')"
    principal_name="$(echo "$assignment" | jq -r '.principalName // "Unknown"')"
    principal_type="$(echo "$assignment" | jq -r '.principalType // "Unknown"')"
    scope="$(echo "$assignment" | jq -r '.scope // "Unknown"')"
    assignment_id="$(echo "$assignment" | jq -r '.id // "Unknown"')"
    principal_id="$(echo "$assignment" | jq -r '.principalId // "Unknown"')"

    local scope_type severity finding evidence recommendation
    scope_type="$(scope_classification "$scope")"
    severity="$(principal_severity "$principal_type" "$scope_type" "$role_name")"

    if [[ "$scope_type" == "subscription" ]]; then
      finding="High-privilege role assigned at subscription scope"
      recommendation="Restrict direct subscription-scope assignments. Prefer least privilege via Entra groups and PIM activation."
    elif [[ "$scope_type" == "resourceGroup" ]]; then
      finding="High-privilege role assigned at resource group scope"
      recommendation="Validate business justification and minimize broad RG-level assignment surface."
    elif [[ "$scope_type" == "resource" ]]; then
      finding="High-privilege role assigned at resource scope"
      recommendation="Confirm resource-scope necessity and rotate to least-privileged custom role where possible."
    else
      finding="High-privilege role assigned at non-standard scope"
      recommendation="Review scope design and enforce consistent RBAC boundaries."
    fi

    evidence="role=$role_name; principalType=$principal_type; principalName=$principal_name; principalId=$principal_id; assignmentId=$assignment_id"

    append_finding "${sub_name:-$sub_id}" "$scope" "Microsoft.Authorization/roleAssignments" "$assignment_id" "$finding" "$severity" "$evidence" "$recommendation"
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
