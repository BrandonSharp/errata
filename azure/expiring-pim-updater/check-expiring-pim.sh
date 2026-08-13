#!/usr/bin/env bash

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
# WINDOW_DAYS=14
WINDOW_DAYS=118
DEFAULT_UPDATE_DAYS=364

SCOPE=""
CHECK_RESOURCES=false
UPDATE_MODE=false
UPDATE_DATE_INPUT=""
UPDATE_TARGET_END=""

NOW_EPOCH=""
WINDOW_END_EPOCH=""

FINDINGS_FILE=""
ERROR_COUNT=0
LAST_GRAPH_ERROR=""
GRAPH_ACCESS_TOKEN="${GRAPH_ACCESS_TOKEN:-}"
GRAPH_TOKEN_SOURCE=""
GRAPH_CLIENT_ID="${GRAPH_CLIENT_ID:-}"
GRAPH_TENANT_ID="${GRAPH_TENANT_ID:-organizations}"
GRAPH_SCOPES="${GRAPH_SCOPES:-https://graph.microsoft.com/RoleEligibilitySchedule.Read.Directory https://graph.microsoft.com/RoleManagement.Read.Directory https://graph.microsoft.com/Group.Read.All openid profile offline_access}"

declare -a AZURE_SCOPES=()
declare -A SCOPE_SEEN=()

usage() {
  cat <<USAGE
Usage: $SCRIPT_NAME --scope <scope-resource-id> [--check-resources] [--update [date_or_datetime]]

Checks for expired or expiring (within next ${WINDOW_DAYS} days) PIM eligibilities across:
  1. Entra role assignment eligibilities
  2. Entra group membership eligibilities (Privileged Access Groups)
  3. Azure role assignment eligibilities under the provided scope and child scopes

Options:
  --scope <scope-resource-id>  Azure scope resource ID to evaluate. Supports:
                               - Management group: /providers/Microsoft.Management/managementGroups/<name>
                               - Subscription:     /subscriptions/<subscriptionId>
                               - Resource group:   /subscriptions/<id>/resourceGroups/<name>
                               - Resource:         /subscriptions/<id>/resourceGroups/<rg>/providers/<type>/<name>
  --check-resources            Include individual resources when traversing subscription or resource-group scope.
  --update [date_or_datetime]  Prompt per finding to update eligibility expiration.
                               If omitted, default update target is now + ${DEFAULT_UPDATE_DAYS} days.
                               Accepted formats include YYYY-MM-DD or parseable datetime.
  --graph-client-id <app-id>   Optional. Use custom Entra app registration for Graph delegated auth.
  --graph-tenant-id <tenant>   Optional. Tenant ID/domain for custom Graph auth (default: organizations).
  --graph-scopes <scopes>      Optional. Space-separated Graph scopes for custom Graph auth.
  -h, --help                   Show this help.

Notes:
  - Default behavior is report-only (no write operations).
  - Assumes you are already authenticated with az CLI.
USAGE
}

log() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
err() { echo "[ERROR] $*" >&2; }

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || {
    err "Required command not found: $cmd"
    exit 1
  }
}

cleanup() {
  if [[ -n "$FINDINGS_FILE" && -f "$FINDINGS_FILE" ]]; then
    rm -f "$FINDINGS_FILE"
  fi
}
trap cleanup EXIT

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --scope)
        [[ $# -lt 2 ]] && { err "--scope requires a value"; usage; exit 1; }
        SCOPE="$2"
        shift 2
        ;;
      --check-resources)
        CHECK_RESOURCES=true
        shift
        ;;
      --update)
        UPDATE_MODE=true
        if [[ $# -gt 1 && ! "$2" =~ ^- ]]; then
          UPDATE_DATE_INPUT="$2"
          shift 2
        else
          shift
        fi
        ;;
      --graph-client-id)
        [[ $# -lt 2 ]] && { err "--graph-client-id requires a value"; usage; exit 1; }
        GRAPH_CLIENT_ID="$2"
        shift 2
        ;;
      --graph-tenant-id)
        [[ $# -lt 2 ]] && { err "--graph-tenant-id requires a value"; usage; exit 1; }
        GRAPH_TENANT_ID="$2"
        shift 2
        ;;
      --graph-scopes)
        [[ $# -lt 2 ]] && { err "--graph-scopes requires a value"; usage; exit 1; }
        GRAPH_SCOPES="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        err "Unknown option: $1"
        usage
        exit 1
        ;;
    esac
  done

  if [[ -z "$SCOPE" ]]; then
    err "--scope is required"
    usage
    exit 1
  fi
}

normalize_update_target() {
  local input="$1"
  if [[ -z "$input" ]]; then
    UPDATE_TARGET_END="$(date -u -d "+${DEFAULT_UPDATE_DAYS} days" +"%Y-%m-%dT23:59:59Z")"
    return
  fi

  if [[ "$input" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    UPDATE_TARGET_END="$(date -u -d "$input 23:59:59" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || true)"
  else
    UPDATE_TARGET_END="$(date -u -d "$input" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || true)"
  fi

  if [[ -z "$UPDATE_TARGET_END" ]]; then
    err "Unable to parse update date/time: $input"
    exit 1
  fi
}

init_time_window() {
  NOW_EPOCH="$(date -u +%s)"
  WINDOW_END_EPOCH="$(date -u -d "+${WINDOW_DAYS} days" +%s)"
}

classify_expiration() {
  local end_datetime="$1"
  local end_epoch
  end_epoch="$(date -u -d "$end_datetime" +%s 2>/dev/null || true)"
  if [[ -z "$end_epoch" ]]; then
    echo ""
    return
  fi

  if (( end_epoch < NOW_EPOCH )); then
    echo "expired"
  elif (( end_epoch <= WINDOW_END_EPOCH )); then
    echo "expiring"
  else
    echo ""
  fi
}

append_finding() {
  local scenario="$1"
  local status="$2"
  local end_datetime="$3"
  local principal_id="$4"
  local principal_name="$5"
  local role_name="$6"
  local scope_value="$7"
  local schedule_id="$8"
  local update_context_json="$9"

  jq -cn \
    --arg scenario "$scenario" \
    --arg status "$status" \
    --arg endDateTime "$end_datetime" \
    --arg principalId "$principal_id" \
    --arg principalName "$principal_name" \
    --arg roleName "$role_name" \
    --arg scope "$scope_value" \
    --arg scheduleId "$schedule_id" \
    --argjson updateContext "$update_context_json" \
    '{
      scenario: $scenario,
      status: $status,
      endDateTime: $endDateTime,
      principalId: $principalId,
      principalName: $principalName,
      roleName: $roleName,
      scope: $scope,
      scheduleId: $scheduleId,
      updateContext: $updateContext
    }' >> "$FINDINGS_FILE"
}

graph_get_all() {
  local initial_url="$1"
  local url="$initial_url"
  while [[ -n "$url" ]]; do
    local response
    local response_file
    response_file="$(mktemp)"

    if ! graph_http_get "$url" >"$response_file"; then
      rm -f "$response_file"
      return 1
    fi

    response="$(cat "$response_file")"
    rm -f "$response_file"

    echo "$response"
    url="$(echo "$response" | jq -r '.["@odata.nextLink"] // empty')"
  done
  return 0
}

get_graph_access_token() {
  local token=""

  # Allow callers to provide an already-consented Graph token.
  if [[ -n "${GRAPH_ACCESS_TOKEN:-}" ]]; then
    # Normalize token copied from shell variables/files that may include line breaks.
    GRAPH_ACCESS_TOKEN="$(printf '%s' "$GRAPH_ACCESS_TOKEN" | tr -d '\r\n')"
    if [[ -z "$GRAPH_ACCESS_TOKEN" ]]; then
      LAST_GRAPH_ERROR="GRAPH_ACCESS_TOKEN was provided but is empty after normalization"
      return 1
    fi
    GRAPH_TOKEN_SOURCE="env"
    return 0
  fi

  # If a custom app registration is configured, prefer custom delegated auth.
  if [[ -n "$GRAPH_CLIENT_ID" ]]; then
    if get_graph_access_token_custom_device_code; then
      return 0
    fi
    LAST_GRAPH_ERROR="custom Graph auth failed: ${LAST_GRAPH_ERROR}"
    return 1
  fi

  token="$(az account get-access-token --resource-type ms-graph --query accessToken -o tsv 2>/dev/null || true)"
  if [[ -z "$token" ]]; then
    token="$(az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv 2>/dev/null || true)"
  fi

  if [[ -z "$token" ]]; then
    LAST_GRAPH_ERROR="unable to obtain Microsoft Graph access token from az account get-access-token"
    return 1
  fi

  GRAPH_ACCESS_TOKEN="$token"
  GRAPH_TOKEN_SOURCE="az"
  return 0
}

get_graph_access_token_custom_device_code() {
  local tenant token_url device_url
  local device_resp token_resp
  local device_code interval expires_in deadline now
  local auth_error

  if [[ -z "$GRAPH_CLIENT_ID" ]]; then
    LAST_GRAPH_ERROR="GRAPH_CLIENT_ID is required for custom Graph device-code auth"
    return 1
  fi

  tenant="$GRAPH_TENANT_ID"
  device_url="https://login.microsoftonline.com/${tenant}/oauth2/v2.0/devicecode"
  token_url="https://login.microsoftonline.com/${tenant}/oauth2/v2.0/token"

  if ! device_resp="$(curl -sS -X POST "$device_url" \
    --data-urlencode "client_id=${GRAPH_CLIENT_ID}" \
    --data-urlencode "scope=${GRAPH_SCOPES}")"; then
    LAST_GRAPH_ERROR="failed to start device code flow"
    return 1
  fi

  device_code="$(echo "$device_resp" | jq -r '.device_code // empty')"
  interval="$(echo "$device_resp" | jq -r '.interval // 5')"
  expires_in="$(echo "$device_resp" | jq -r '.expires_in // 900')"

  if [[ -z "$device_code" ]]; then
    LAST_GRAPH_ERROR="device code response missing device_code: ${device_resp}"
    return 1
  fi

  echo ""
  echo "[INFO] Custom Graph authentication required."
  echo "$(echo "$device_resp" | jq -r '.message // "Open browser and complete device code login."')"

  now="$(date -u +%s)"
  deadline=$((now + expires_in))

  while true; do
    now="$(date -u +%s)"
    if (( now >= deadline )); then
      LAST_GRAPH_ERROR="device code flow timed out before token issuance"
      return 1
    fi

    if ! token_resp="$(curl -sS -X POST "$token_url" \
      --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:device_code" \
      --data-urlencode "client_id=${GRAPH_CLIENT_ID}" \
      --data-urlencode "device_code=${device_code}")"; then
      LAST_GRAPH_ERROR="failed while polling token endpoint"
      return 1
    fi

    if [[ "$(echo "$token_resp" | jq -r '.access_token // empty')" != "" ]]; then
      GRAPH_ACCESS_TOKEN="$(echo "$token_resp" | jq -r '.access_token')"
      GRAPH_TOKEN_SOURCE="custom-device"
      return 0
    fi

    auth_error="$(echo "$token_resp" | jq -r '.error // empty')"
    case "$auth_error" in
      authorization_pending)
        sleep "$interval"
        ;;
      slow_down)
        interval=$((interval + 5))
        sleep "$interval"
        ;;
      authorization_declined|expired_token|bad_verification_code)
        LAST_GRAPH_ERROR="device code auth failed: ${token_resp}"
        return 1
        ;;
      *)
        LAST_GRAPH_ERROR="token endpoint error: ${token_resp}"
        return 1
        ;;
    esac
  done
}

print_graph_scope_remediation() {
  if [[ "$LAST_GRAPH_ERROR" == *"PermissionScopeNotGranted"* ]]; then
    warn "Microsoft Graph token is missing required delegated scopes for PIM role eligibility APIs."
    warn "Global Administrator role alone is not sufficient; Graph OAuth scope consent is also required."
    warn "Required scopes include one of: RoleEligibilitySchedule.Read.Directory or RoleEligibilitySchedule.ReadWrite.Directory"
    warn "and one of: RoleManagement.Read.Directory, RoleManagement.Read.All, or RoleManagement.ReadWrite.Directory."
    warn "Remediation: grant admin consent for the Azure CLI enterprise application, then re-authenticate (az logout && az login)."
    warn "Workaround: provide a pre-consented token via GRAPH_ACCESS_TOKEN environment variable."
    warn "Alternative: use custom app auth with --graph-client-id <app-id> [--graph-tenant-id <tenant>]"
  fi
}

graph_http_get() {
  local url="$1"
  local body_file code_file err_file
  local http_code response_body

  if [[ -z "$GRAPH_ACCESS_TOKEN" ]]; then
    if ! get_graph_access_token; then
      return 1
    fi
  fi

  body_file="$(mktemp)"
  code_file="$(mktemp)"
  err_file="$(mktemp)"

  if curl -sS \
    -H "Authorization: Bearer ${GRAPH_ACCESS_TOKEN}" \
    -H "Accept: application/json" \
    "$url" \
    -o "$body_file" \
    -w "%{http_code}" >"$code_file" 2>"$err_file"; then
    :
  else
    local curl_exit
    curl_exit=$?
    local curl_stderr
    curl_stderr="$(cat "$err_file" 2>/dev/null || true)"
    rm -f "$body_file" "$code_file" "$err_file"
    LAST_GRAPH_ERROR="url=${url} curl_exit=${curl_exit} stderr='${curl_stderr}'"
    return 1
  fi

  http_code="$(cat "$code_file")"
  response_body="$(cat "$body_file")"
  rm -f "$body_file" "$code_file" "$err_file"

  if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    echo "$response_body"
    return 0
  fi

  # If Azure CLI token lacks needed scopes and a custom app is configured, retry once with device-code auth.
  if [[ "$response_body" == *"PermissionScopeNotGranted"* && "$GRAPH_TOKEN_SOURCE" == "az" && -n "$GRAPH_CLIENT_ID" ]]; then
    GRAPH_ACCESS_TOKEN=""
    if get_graph_access_token_custom_device_code; then
      graph_http_get "$url"
      return $?
    fi
  fi

  LAST_GRAPH_ERROR="url=${url} http=${http_code} body='${response_body}'"
  return 1
}

arm_get_all() {
  local initial_url="$1"
  local url="$initial_url"
  while [[ -n "$url" ]]; do
    local response
    if ! response="$(az rest --method get --uri "$url" --output json 2>/dev/null)"; then
      return 1
    fi
    echo "$response"
    url="$(echo "$response" | jq -r '.nextLink // empty')"
  done
  return 0
}

collect_entra_role_eligibilities() {
  log "Checking Entra role assignment eligibilities"

  local url="https://graph.microsoft.com/v1.0/roleManagement/directory/roleEligibilitySchedules?\$expand=principal,roleDefinition&\$top=999"
  local pages_file
  LAST_GRAPH_ERROR=""
  pages_file="$(mktemp)"
  if ! graph_get_all "$url" >"$pages_file"; then
    warn "Unable to query Entra role eligibilities. Graph response: ${LAST_GRAPH_ERROR:-unknown error}"
    print_graph_scope_remediation
    ERROR_COUNT=$((ERROR_COUNT + 1))
    rm -f "$pages_file"
    return
  fi

  while IFS= read -r item; do
    local end_datetime status
    end_datetime="$(echo "$item" | jq -r '.scheduleInfo.expiration.endDateTime // empty')"
    [[ -z "$end_datetime" || "$end_datetime" == "null" ]] && continue

    status="$(classify_expiration "$end_datetime")"
    [[ -z "$status" ]] && continue

    local principal_id principal_name role_name directory_scope schedule_id
    principal_id="$(echo "$item" | jq -r '.principalId // "unknown"')"
    principal_name="$(echo "$item" | jq -r '.principal.displayName // "unknown"')"
    role_name="$(echo "$item" | jq -r '.roleDefinition.displayName // .roleDefinitionId // "unknown"')"
    directory_scope="$(echo "$item" | jq -r '.directoryScopeId // "/"')"
    schedule_id="$(echo "$item" | jq -r '.id')"

    local update_context
    update_context="$(echo "$item" | jq -c '{
      type: "entraRole",
      principalId: .principalId,
      roleDefinitionId: .roleDefinitionId,
      directoryScopeId: (.directoryScopeId // "/"),
      scheduleId: .id
    }')"

    append_finding \
      "entra-role-assignment" \
      "$status" \
      "$end_datetime" \
      "$principal_id" \
      "$principal_name" \
      "$role_name" \
      "$directory_scope" \
      "$schedule_id" \
      "$update_context"
  done < <(jq -c '.value[]?' "$pages_file")

  rm -f "$pages_file"
}

collect_entra_group_eligibilities() {
  log "Checking Entra group membership eligibilities"

  # The PIM for Groups API requires GroupId or PrincipalId; for tenant-wide coverage,
  # enumerate groups and query per GroupId.
  local groups_url="https://graph.microsoft.com/v1.0/groups?\$select=id,displayName&\$top=999"
  local groups_file
  LAST_GRAPH_ERROR=""
  groups_file="$(mktemp)"
  if ! graph_get_all "$groups_url" >"$groups_file"; then
    warn "Unable to enumerate groups for Entra group eligibility checks. Graph response: ${LAST_GRAPH_ERROR:-unknown error}"
    print_graph_scope_remediation
    ERROR_COUNT=$((ERROR_COUNT + 1))
    rm -f "$groups_file"
    return
  fi

  local groups_processed=0
  local groups_query_errors=0

  while IFS= read -r group_item; do
    local group_id
    group_id="$(echo "$group_item" | jq -r '.id // empty')"
    [[ -n "$group_id" ]] || continue
    groups_processed=$((groups_processed + 1))

    local url
    url="https://graph.microsoft.com/beta/identityGovernance/privilegedAccess/group/eligibilityScheduleInstances?GroupId=${group_id}&\$expand=principal,group&\$top=999"

    local pages_file
    pages_file="$(mktemp)"
    LAST_GRAPH_ERROR=""

    if ! graph_get_all "$url" >"$pages_file"; then
      groups_query_errors=$((groups_query_errors + 1))
      rm -f "$pages_file"
      continue
    fi

    while IFS= read -r item; do
      local end_datetime status
      end_datetime="$(echo "$item" | jq -r '.endDateTime // .scheduleInfo.expiration.endDateTime // empty')"
      [[ -z "$end_datetime" || "$end_datetime" == "null" ]] && continue

      status="$(classify_expiration "$end_datetime")"
      [[ -z "$status" ]] && continue

      local principal_id principal_name access_id group_name group_id schedule_id
      principal_id="$(echo "$item" | jq -r '.principalId // .principal.id // "unknown"')"
      principal_name="$(echo "$item" | jq -r '.principal.displayName // "unknown"')"
      access_id="$(echo "$item" | jq -r '.accessId // .memberType // "member"')"
      group_name="$(echo "$item" | jq -r '.group.displayName // .groupId // "unknown-group"')"
      group_id="$(echo "$item" | jq -r '.groupId // "unknown"')"
      schedule_id="$(echo "$item" | jq -r '.eligibilityScheduleId // .id')"

      local update_context
      update_context="$(echo "$item" | jq -c '{
        type: "entraGroup",
        principalId: .principalId,
        groupId: .groupId,
        accessId: (.accessId // "member"),
        scheduleId: (.eligibilityScheduleId // .id)
      }')"

      append_finding \
        "entra-group-membership" \
        "$status" \
        "$end_datetime" \
        "$principal_id" \
        "$principal_name" \
        "$access_id" \
        "$group_name ($group_id)" \
        "$schedule_id" \
        "$update_context"
    done < <(jq -c '.value[]?' "$pages_file")

    rm -f "$pages_file"
  done < <(jq -c '.value[]?' "$groups_file")

  rm -f "$groups_file"

  if [[ "$groups_processed" -eq 0 ]]; then
    warn "No groups were returned for Entra group eligibility scan."
  elif [[ "$groups_query_errors" -gt 0 ]]; then
    warn "Entra group eligibility scan skipped ${groups_query_errors} group query operations due to API/permission limitations."
  fi
}

add_scope_once() {
  local scope_id="$1"
  if [[ -z "${SCOPE_SEEN[$scope_id]:-}" ]]; then
    SCOPE_SEEN[$scope_id]=1
    AZURE_SCOPES+=("$scope_id")
  fi
}

scope_kind() {
  local scope_id="$1"
  if [[ "$scope_id" =~ ^/providers/Microsoft\.Management/managementGroups/[^/]+$ ]]; then
    echo "managementGroup"
  elif [[ "$scope_id" =~ ^/subscriptions/[^/]+$ ]]; then
    echo "subscription"
  elif [[ "$scope_id" =~ ^/subscriptions/[^/]+/resourceGroups/[^/]+$ ]]; then
    echo "resourceGroup"
  elif [[ "$scope_id" =~ ^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/.+$ ]]; then
    echo "resource"
  else
    echo "unknown"
  fi
}

extract_subscription_id() {
  local scope_id="$1"
  echo "$scope_id" | sed -n 's#^/subscriptions/\([^/]*\).*$#\1#p'
}

extract_resource_group_name() {
  local scope_id="$1"
  echo "$scope_id" | sed -n 's#^/subscriptions/[^/]*/resourceGroups/\([^/]*\).*$#\1#p'
}

collect_resource_groups_for_subscription() {
  local sub_id="$1"
  az group list --subscription "$sub_id" --query '[].id' -o tsv 2>/dev/null || true
}

collect_resources_for_subscription() {
  local sub_id="$1"
  az resource list --subscription "$sub_id" --query '[].id' -o tsv 2>/dev/null || true
}

collect_resources_for_rg() {
  local sub_id="$1"
  local rg_name="$2"
  az resource list --subscription "$sub_id" --resource-group "$rg_name" --query '[].id' -o tsv 2>/dev/null || true
}

expand_from_subscription() {
  local sub_scope="$1"
  local sub_id
  sub_id="$(extract_subscription_id "$sub_scope")"

  add_scope_once "$sub_scope"

  while IFS= read -r rg; do
    [[ -z "$rg" ]] && continue
    add_scope_once "$rg"

    if [[ "$CHECK_RESOURCES" == true ]]; then
      local rg_name
      rg_name="$(extract_resource_group_name "$rg")"
      while IFS= read -r resource_id; do
        [[ -z "$resource_id" ]] && continue
        add_scope_once "$resource_id"
      done < <(collect_resources_for_rg "$sub_id" "$rg_name")
    fi
  done < <(collect_resource_groups_for_subscription "$sub_id")

  if [[ "$CHECK_RESOURCES" == true ]]; then
    while IFS= read -r resource_id; do
      [[ -z "$resource_id" ]] && continue
      add_scope_once "$resource_id"
    done < <(collect_resources_for_subscription "$sub_id")
  fi
}

expand_from_resource_group() {
  local rg_scope="$1"
  add_scope_once "$rg_scope"

  if [[ "$CHECK_RESOURCES" == true ]]; then
    local sub_id rg_name
    sub_id="$(extract_subscription_id "$rg_scope")"
    rg_name="$(extract_resource_group_name "$rg_scope")"
    while IFS= read -r resource_id; do
      [[ -z "$resource_id" ]] && continue
      add_scope_once "$resource_id"
    done < <(collect_resources_for_rg "$sub_id" "$rg_name")
  fi
}

collect_mg_children() {
  local mg_name="$1"
  az account management-group show \
    --name "$mg_name" \
    --expand \
    --query 'children[].{name:name,type:type}' \
    -o json 2>/dev/null || true
}

expand_from_management_group() {
  local mg_scope="$1"
  local mg_name="${mg_scope##*/}"

  add_scope_once "$mg_scope"

  local children
  children="$(collect_mg_children "$mg_name")"
  if [[ -z "$children" || "$children" == "[]" ]]; then
    return
  fi

  while IFS= read -r child; do
    local child_type child_name
    child_type="$(echo "$child" | jq -r '.type')"
    child_name="$(echo "$child" | jq -r '.name')"

    if [[ "$child_type" == "Microsoft.Management/managementGroups" ]]; then
      expand_from_management_group "/providers/Microsoft.Management/managementGroups/$child_name"
    elif [[ "$child_type" == "/subscriptions" ]]; then
      expand_from_subscription "/subscriptions/$child_name"
    fi
  done < <(echo "$children" | jq -c '.[]')
}

normalize_scope_input() {
  local raw_scope="$1"

  if [[ "$raw_scope" =~ ^/providers/Microsoft\.Management/managementGroups/[^/]+$ ]]; then
    echo "$raw_scope"
    return
  fi

  if [[ "$raw_scope" =~ ^/subscriptions/[^/]+(/.*)?$ ]]; then
    echo "$raw_scope"
    return
  fi

  if [[ "$raw_scope" =~ ^[A-Za-z0-9_.()-]+$ ]]; then
    echo "/providers/Microsoft.Management/managementGroups/$raw_scope"
    return
  fi

  echo "$raw_scope"
}

collect_azure_scopes() {
  log "Resolving Azure scopes from input"

  local normalized_scope kind
  normalized_scope="$(normalize_scope_input "$SCOPE")"
  kind="$(scope_kind "$normalized_scope")"

  case "$kind" in
    managementGroup)
      expand_from_management_group "$normalized_scope"
      ;;
    subscription)
      expand_from_subscription "$normalized_scope"
      ;;
    resourceGroup)
      expand_from_resource_group "$normalized_scope"
      ;;
    resource)
      add_scope_once "$normalized_scope"
      ;;
    *)
      err "Unrecognized scope format: $SCOPE"
      err "Provide a valid management group, subscription, resource group, or resource ID"
      exit 1
      ;;
  esac

  if (( ${#AZURE_SCOPES[@]} == 0 )); then
    warn "No Azure scopes resolved from input"
  else
    log "Resolved ${#AZURE_SCOPES[@]} scope(s) for Azure PIM checks"
  fi
}

collect_azure_role_eligibilities() {
  log "Checking Azure role assignment eligibilities"

  for scope_id in "${AZURE_SCOPES[@]}"; do
    local url pages
    url="https://management.azure.com${scope_id}/providers/Microsoft.Authorization/roleEligibilitySchedules?api-version=2020-10-01-preview"

    if ! pages="$(arm_get_all "$url")"; then
      warn "Unable to query Azure role eligibilities at scope: $scope_id"
      ERROR_COUNT=$((ERROR_COUNT + 1))
      continue
    fi

    while IFS= read -r item; do
      local end_datetime status principal_id role_definition_id schedule_id
      end_datetime="$(echo "$item" | jq -r '.properties.scheduleInfo.expiration.endDateTime // empty')"
      [[ -z "$end_datetime" || "$end_datetime" == "null" ]] && continue

      status="$(classify_expiration "$end_datetime")"
      [[ -z "$status" ]] && continue

      principal_id="$(echo "$item" | jq -r '.properties.principalId // "unknown"')"
      role_definition_id="$(echo "$item" | jq -r '.properties.roleDefinitionId // "unknown"')"
      schedule_id="$(echo "$item" | jq -r '.name // .id // "unknown"')"

      local update_context
      update_context="$(echo "$item" | jq -c --arg scope "$scope_id" '{
        type: "azureRole",
        scope: $scope,
        principalId: .properties.principalId,
        roleDefinitionId: .properties.roleDefinitionId,
        scheduleId: (.name // .id)
      }')"

      append_finding \
        "azure-role-assignment" \
        "$status" \
        "$end_datetime" \
        "$principal_id" \
        "$principal_id" \
        "$role_definition_id" \
        "$scope_id" \
        "$schedule_id" \
        "$update_context"
    done < <(echo "$pages" | jq -c '.value[]?')
  done
}

report_findings() {
  local total expired expiring
  total="$(wc -l < "$FINDINGS_FILE" | tr -d ' ')"

  if [[ "$total" == "0" ]]; then
    echo
    echo "No expired or expiring (next ${WINDOW_DAYS} days) PIM eligibilities found."
    return
  fi

  expired="$(jq -s '[.[] | select(.status == "expired")] | length' "$FINDINGS_FILE")"
  expiring="$(jq -s '[.[] | select(.status == "expiring")] | length' "$FINDINGS_FILE")"

  echo
  echo "Findings summary"
  echo "- Total:    $total"
  echo "- Expired:  $expired"
  echo "- Expiring: $expiring"

  local scenario
  for scenario in "entra-group-membership" "entra-role-assignment" "azure-role-assignment"; do
    local count
    count="$(jq -s --arg s "$scenario" '[.[] | select(.scenario == $s)] | length' "$FINDINGS_FILE")"

    echo
    echo "Scenario: $scenario ($count)"
    if [[ "$count" == "0" ]]; then
      echo "  none"
      continue
    fi

    jq -s --arg s "$scenario" '
      [.[] | select(.scenario == $s)]
      | sort_by(.status, .endDateTime)
      | .[]
      | "  [\(.status)] end=\(.endDateTime) principal=\(.principalName) role=\(.roleName) scope=\(.scope) scheduleId=\(.scheduleId)"
    ' -r "$FINDINGS_FILE"
  done
}

update_azure_role_eligibility() {
  local ctx="$1"
  local scope principal_id role_definition_id schedule_id request_id

  scope="$(echo "$ctx" | jq -r '.scope')"
  principal_id="$(echo "$ctx" | jq -r '.principalId')"
  role_definition_id="$(echo "$ctx" | jq -r '.roleDefinitionId')"
  schedule_id="$(echo "$ctx" | jq -r '.scheduleId')"
  request_id="$(cat /proc/sys/kernel/random/uuid)"

  local body
  body="$(jq -cn \
    --arg principalId "$principal_id" \
    --arg roleDefinitionId "$role_definition_id" \
    --arg targetRoleEligibilityScheduleId "$schedule_id" \
    --arg endDateTime "$UPDATE_TARGET_END" \
    '{
      properties: {
        principalId: $principalId,
        roleDefinitionId: $roleDefinitionId,
        requestType: "AdminUpdate",
        targetRoleEligibilityScheduleId: $targetRoleEligibilityScheduleId,
        justification: "Updated by check-expiring-pim.sh",
        scheduleInfo: {
          expiration: {
            type: "AfterDateTime",
            endDateTime: $endDateTime
          }
        }
      }
    }')"

  az rest \
    --method put \
    --uri "https://management.azure.com${scope}/providers/Microsoft.Authorization/roleEligibilityScheduleRequests/${request_id}?api-version=2020-10-01-preview" \
    --body "$body" \
    --output none >/dev/null
}

update_entra_role_eligibility() {
  local ctx="$1"
  local principal_id role_definition_id directory_scope_id schedule_id

  principal_id="$(echo "$ctx" | jq -r '.principalId')"
  role_definition_id="$(echo "$ctx" | jq -r '.roleDefinitionId')"
  directory_scope_id="$(echo "$ctx" | jq -r '.directoryScopeId // "/"')"
  schedule_id="$(echo "$ctx" | jq -r '.scheduleId')"

  local body
  body="$(jq -cn \
    --arg principalId "$principal_id" \
    --arg roleDefinitionId "$role_definition_id" \
    --arg directoryScopeId "$directory_scope_id" \
    --arg targetScheduleId "$schedule_id" \
    --arg endDateTime "$UPDATE_TARGET_END" \
    '{
      action: "adminUpdate",
      principalId: $principalId,
      roleDefinitionId: $roleDefinitionId,
      directoryScopeId: $directoryScopeId,
      targetScheduleId: $targetScheduleId,
      justification: "Updated by check-expiring-pim.sh",
      scheduleInfo: {
        expiration: {
          type: "afterDateTime",
          endDateTime: $endDateTime
        }
      }
    }')"

  az rest \
    --method post \
    --uri "https://graph.microsoft.com/v1.0/roleManagement/directory/roleEligibilityScheduleRequests" \
    --body "$body" \
    --output none >/dev/null
}

update_entra_group_eligibility() {
  local ctx="$1"
  local principal_id group_id access_id schedule_id

  principal_id="$(echo "$ctx" | jq -r '.principalId')"
  group_id="$(echo "$ctx" | jq -r '.groupId')"
  access_id="$(echo "$ctx" | jq -r '.accessId // "member"')"
  schedule_id="$(echo "$ctx" | jq -r '.scheduleId')"

  local body
  body="$(jq -cn \
    --arg principalId "$principal_id" \
    --arg groupId "$group_id" \
    --arg accessId "$access_id" \
    --arg targetScheduleId "$schedule_id" \
    --arg endDateTime "$UPDATE_TARGET_END" \
    '{
      action: "adminUpdate",
      principalId: $principalId,
      groupId: $groupId,
      accessId: $accessId,
      targetScheduleId: $targetScheduleId,
      justification: "Updated by check-expiring-pim.sh",
      scheduleInfo: {
        expiration: {
          type: "afterDateTime",
          endDateTime: $endDateTime
        }
      }
    }')"

  az rest \
    --method post \
    --uri "https://graph.microsoft.com/beta/identityGovernance/privilegedAccess/group/eligibilityScheduleRequests" \
    --body "$body" \
    --output none >/dev/null
}

apply_updates_interactively() {
  if [[ "$UPDATE_MODE" != true ]]; then
    return
  fi

  if [[ ! -t 0 ]]; then
    err "--update requires an interactive terminal (TTY) for prompts"
    exit 1
  fi

  local total
  total="$(wc -l < "$FINDINGS_FILE" | tr -d ' ')"
  if [[ "$total" == "0" ]]; then
    log "No findings to update"
    return
  fi

  log "Update mode enabled. Target expiration: $UPDATE_TARGET_END"

  local updated=0
  local skipped=0
  local failed=0

  while IFS= read -r finding; do
    local scenario status principal role scope end_dt context
    scenario="$(echo "$finding" | jq -r '.scenario')"
    status="$(echo "$finding" | jq -r '.status')"
    principal="$(echo "$finding" | jq -r '.principalName')"
    role="$(echo "$finding" | jq -r '.roleName')"
    scope="$(echo "$finding" | jq -r '.scope')"
    end_dt="$(echo "$finding" | jq -r '.endDateTime')"
    context="$(echo "$finding" | jq -c '.updateContext')"

    echo
    echo "Item"
    echo "- Scenario:    $scenario"
    echo "- Status:      $status"
    echo "- Principal:   $principal"
    echo "- Role/Access: $role"
    echo "- Scope:       $scope"
    echo "- Current end: $end_dt"

    read -r -p "Update this item to $UPDATE_TARGET_END ? [y/N]: " answer
    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
      skipped=$((skipped + 1))
      continue
    fi

    local kind
    kind="$(echo "$context" | jq -r '.type')"
    if [[ -z "$kind" || "$kind" == "null" ]]; then
      warn "Skipping update: missing update context"
      failed=$((failed + 1))
      continue
    fi

    if [[ "$kind" == "azureRole" ]]; then
      if update_azure_role_eligibility "$context"; then
        updated=$((updated + 1))
      else
        warn "Failed to update Azure role eligibility"
        failed=$((failed + 1))
      fi
    elif [[ "$kind" == "entraRole" ]]; then
      if update_entra_role_eligibility "$context"; then
        updated=$((updated + 1))
      else
        warn "Failed to update Entra role eligibility"
        failed=$((failed + 1))
      fi
    elif [[ "$kind" == "entraGroup" ]]; then
      if update_entra_group_eligibility "$context"; then
        updated=$((updated + 1))
      else
        warn "Failed to update Entra group eligibility"
        failed=$((failed + 1))
      fi
    else
      warn "Unknown update context type: $kind"
      failed=$((failed + 1))
    fi
  done < "$FINDINGS_FILE"

  echo
  echo "Update summary"
  echo "- Updated: $updated"
  echo "- Skipped: $skipped"
  echo "- Failed:  $failed"
}

main() {
  require_cmd az
  require_cmd jq
  require_cmd date
  require_cmd curl

  parse_args "$@"
  init_time_window

  if [[ "$UPDATE_MODE" == true ]]; then
    normalize_update_target "$UPDATE_DATE_INPUT"
  fi

  FINDINGS_FILE="$(mktemp)"

  collect_entra_role_eligibilities
  collect_entra_group_eligibilities

  collect_azure_scopes
  collect_azure_role_eligibilities

  report_findings
  apply_updates_interactively

  if (( ERROR_COUNT > 0 )); then
    warn "Completed with $ERROR_COUNT warning path(s). See messages above."
  fi
}

main "$@"
