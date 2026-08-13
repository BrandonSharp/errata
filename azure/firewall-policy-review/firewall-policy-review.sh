#!/usr/bin/env bash

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SUBSCRIPTIONS=()
OUTPUT_DIR="$PWD"
OUTPUT_FILE=""

ATTACHED_POLICY_FILE=""
NO_POLICY_FIREWALLS_FILE=""

usage() {
  cat <<USAGE
Usage: $SCRIPT_NAME --subscriptions <sub1,sub2,...> [--output-dir <path>] [--output-file <path>]

Builds a Markdown report of Azure Firewall policies attached to firewalls.
For each policy, the report includes three sections:
  1) Application rules
  2) Network rules
  3) DNAT rules

Each rule is rendered as a table row with source, destination, and ports.
Multi-value fields are separated with line breaks for readability.

Options:
  --subscriptions <csv>   Comma-separated subscription IDs or names.
  --output-dir <path>     Directory for report output (default: current directory).
  --output-file <path>    Explicit report file path (overrides --output-dir name).
  -h, --help              Show this help.
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

az_json_or_die() {
  local out_file err_file
  out_file="$(mktemp)"
  err_file="$(mktemp)"

  if az "$@" -o json >"$out_file" 2>"$err_file"; then
    cat "$out_file"
    rm -f "$out_file" "$err_file"
    return 0
  fi

  log_error "Azure CLI command failed: az $*"
  if [[ -s "$err_file" ]]; then
    sed 's/^/[AZ-ERROR] /' "$err_file" >&2
  fi

  rm -f "$out_file" "$err_file"
  return 1
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --subscriptions)
        [[ $# -lt 2 ]] && { log_error "--subscriptions requires a value"; exit 1; }
        IFS=',' read -r -a SUBSCRIPTIONS <<< "$2"
        shift 2
        ;;
      --output-dir)
        [[ $# -lt 2 ]] && { log_error "--output-dir requires a value"; exit 1; }
        OUTPUT_DIR="$2"
        shift 2
        ;;
      --output-file)
        [[ $# -lt 2 ]] && { log_error "--output-file requires a value"; exit 1; }
        OUTPUT_FILE="$2"
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

  if [[ ${#SUBSCRIPTIONS[@]} -eq 0 ]]; then
    log_error "--subscriptions is required"
    usage
    exit 1
  fi

  local i
  for i in "${!SUBSCRIPTIONS[@]}"; do
    SUBSCRIPTIONS[$i]="$(echo "${SUBSCRIPTIONS[$i]}" | xargs)"
  done

  if [[ -z "$OUTPUT_FILE" ]]; then
    mkdir -p "$OUTPUT_DIR"
    OUTPUT_FILE="$OUTPUT_DIR/firewall_policy_review_$(date -u +%Y%m%d_%H%M%S).md"
  else
    mkdir -p "$(dirname "$OUTPUT_FILE")"
  fi
}

cleanup() {
  [[ -n "$ATTACHED_POLICY_FILE" && -f "$ATTACHED_POLICY_FILE" ]] && rm -f "$ATTACHED_POLICY_FILE"
  [[ -n "$NO_POLICY_FIREWALLS_FILE" && -f "$NO_POLICY_FIREWALLS_FILE" ]] && rm -f "$NO_POLICY_FIREWALLS_FILE"
}

extract_subscription_id_from_resource_id() {
  local resource_id="$1"
  echo "$resource_id" | awk -F'/' '
    {
      for (i = 1; i <= NF; i++) {
        if (tolower($i) == "subscriptions" && (i + 1) <= NF) {
          print $(i + 1)
          exit
        }
      }
    }
  '
}

extract_resource_group_from_resource_id() {
  local resource_id="$1"
  echo "$resource_id" | awk -F'/' '
    {
      for (i = 1; i <= NF; i++) {
        if (tolower($i) == "resourcegroups" && (i + 1) <= NF) {
          print $(i + 1)
          exit
        }
      }
    }
  '
}

extract_name_from_resource_id() {
  local resource_id="$1"
  echo "$resource_id" | awk -F'/' '{print $NF}'
}

report_header() {
  {
    echo "# Azure Firewall Policy Review"
    echo
    echo "**Generated (UTC):** $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    echo "**Subscriptions:** ${SUBSCRIPTIONS[*]}"
    echo
  } > "$OUTPUT_FILE"
}

collect_firewalls_and_policies() {
  ATTACHED_POLICY_FILE="$(mktemp)"
  NO_POLICY_FIREWALLS_FILE="$(mktemp)"

  local sub
  for sub in "${SUBSCRIPTIONS[@]}"; do
    log_info "Collecting Azure Firewalls in subscription: $sub"

    local firewalls
    if ! firewalls="$(az_json_or_die network firewall list --subscription "$sub")"; then
      log_error "Cannot continue firewall discovery for subscription: $sub"
      exit 1
    fi

    echo "$firewalls" | jq -c '.[]?' | while IFS= read -r fw; do
      local fw_name fw_id fw_rg fw_policy_id sub_name
      fw_name="$(echo "$fw" | jq -r '.name')"
      fw_id="$(echo "$fw" | jq -r '.id')"
      fw_rg="$(echo "$fw" | jq -r '.resourceGroup')"
      fw_policy_id="$(echo "$fw" | jq -r '.firewallPolicy.id // empty')"
      sub_name="$(az account show --subscription "$sub" --query name -o tsv 2>/dev/null || true)"
      if [[ -z "$sub_name" ]]; then
        sub_name="$sub"
      fi

      if [[ -n "$fw_policy_id" ]]; then
        jq -cn \
          --arg subscription "$sub_name" \
          --arg firewallName "$fw_name" \
          --arg firewallId "$fw_id" \
          --arg firewallRg "$fw_rg" \
          --arg policyId "$fw_policy_id" \
          '{
            subscription: $subscription,
            firewallName: $firewallName,
            firewallId: $firewallId,
            firewallResourceGroup: $firewallRg,
            policyId: $policyId
          }' >> "$ATTACHED_POLICY_FILE"
      else
        jq -cn \
          --arg subscription "$sub_name" \
          --arg firewallName "$fw_name" \
          --arg firewallId "$fw_id" \
          '{
            subscription: $subscription,
            firewallName: $firewallName,
            firewallId: $firewallId
          }' >> "$NO_POLICY_FIREWALLS_FILE"
      fi
    done
  done
}

render_rule_section() {
  local rule_groups_json="$1"
  local title="$2"
  local rule_type="$3"

  echo "### $title" >> "$OUTPUT_FILE"
  echo >> "$OUTPUT_FILE"
  echo "| Rule Collection Group | Rule Collection | Rule | Action | Source | Destination | Ports |" >> "$OUTPUT_FILE"
  echo "|-----------------------|-----------------|------|--------|--------|-------------|-------|" >> "$OUTPUT_FILE"

  local rows
  rows="$(echo "$rule_groups_json" | jq -r --arg ruleType "$rule_type" '
    def clean_list(a): (a // []) | map(select(. != null and . != "")) | unique;
    def join_lines(a): clean_list(a) | if length == 0 then "N/A" else join("<br>") end;

    .[]?
    | {
        rcgName: (.name // .properties.name // "N/A"),
        ruleCollections: (.ruleCollections // .properties.ruleCollections // [])
      }
    | .rcgName as $rcgName
    | .ruleCollections[]?
    | {
        rcName: (.name // "N/A"),
        action: (.action.type // .properties.action.type // "N/A"),
        rules: (.rules // .properties.rules // [])
      }
    | .rcName as $rcName
    | .action as $action
    | .rules[]?
    | select((.ruleType // .properties.ruleType // "") == $ruleType)
    | . as $r
    | (
        if $ruleType == "ApplicationRule" then
          {
            src: join_lines((($r.sourceAddresses // []) + ($r.sourceIpGroups // []))),
            dst: join_lines((($r.targetFqdns // [])
                  + (($r.fqdnTags // []) | map("fqdnTag:" + .))
                  + (($r.webCategories // []) | map("webCategory:" + .))
                  + ($r.destinationAddresses // [])
                  + ($r.destinationIpGroups // []))),
            ports: join_lines((($r.protocols // []) | map((.protocolType // "Any") + ":" + ((.port // "Any") | tostring))))
          }
        elif $ruleType == "NetworkRule" then
          {
            src: join_lines((($r.sourceAddresses // []) + ($r.sourceIpGroups // []))),
            dst: join_lines((($r.destinationAddresses // []) + ($r.destinationFqdns // []) + ($r.destinationIpGroups // []))),
            ports: join_lines((($r.destinationPorts // []) + (($r.ipProtocols // []) | map("protocol:" + .))))
          }
        else
          {
            src: join_lines((($r.sourceAddresses // []) + ($r.sourceIpGroups // []))),
            dst: join_lines((($r.destinationAddresses // []) + ($r.destinationIpGroups // [])
                  + (if (($r.translatedAddress // "") != "") then ["translatedAddress:" + $r.translatedAddress] else [] end)
                  + (if (($r.translatedFqdn // "") != "") then ["translatedFqdn:" + $r.translatedFqdn] else [] end))),
            ports: join_lines((($r.destinationPorts // [])
                  + (if ($r.translatedPort != null) then ["translatedPort:" + ($r.translatedPort | tostring)] else [] end)
                  + (($r.ipProtocols // []) | map("protocol:" + .))))
          }
        end
      ) as $shape
    | [
        $rcgName,
        $rcName,
        ($r.name // "N/A"),
        $action,
        $shape.src,
        $shape.dst,
        $shape.ports
      ]
    | map((. // "N/A") | tostring | gsub("\\|"; "\\\\|"))
    | "| " + join(" | ") + " |"
  ' )"

  if [[ -n "$rows" ]]; then
    printf "%s\n" "$rows" >> "$OUTPUT_FILE"
  else
    echo "| N/A | N/A | N/A | N/A | N/A | N/A | N/A |" >> "$OUTPUT_FILE"
  fi

  echo >> "$OUTPUT_FILE"
}

render_policy_section() {
  local policy_id="$1"

  local policy_sub policy_rg policy_name
  policy_sub="$(extract_subscription_id_from_resource_id "$policy_id")"
  policy_rg="$(extract_resource_group_from_resource_id "$policy_id")"
  policy_name="$(extract_name_from_resource_id "$policy_id")"

  if [[ -z "$policy_sub" || -z "$policy_rg" || -z "$policy_name" ]]; then
    log_warn "Skipping malformed policy resource ID: $policy_id"
    return
  fi

  log_info "Rendering policy: $policy_name"

  local attached_firewalls
  attached_firewalls="$(jq -s -r --arg policyId "$policy_id" '
    [.[] | select(.policyId == $policyId)]
  ' "$ATTACHED_POLICY_FILE")"

  {
    echo "## Firewall Policy: $policy_name"
    echo
    echo "- Policy ID: $policy_id"
    echo "- Subscription ID: $policy_sub"
    echo "- Resource Group: $policy_rg"
    echo "- Attached Firewalls:"
  } >> "$OUTPUT_FILE"

  local attached_lines
  attached_lines="$(echo "$attached_firewalls" | jq -r '.[] | "  - " + .firewallName + " (subscription=" + .subscription + ", rg=" + .firewallResourceGroup + ")"')"
  if [[ -n "$attached_lines" ]]; then
    printf "%s\n" "$attached_lines" >> "$OUTPUT_FILE"
  else
    echo "  - none detected" >> "$OUTPUT_FILE"
  fi
  echo >> "$OUTPUT_FILE"

  local rule_groups_json
  if ! rule_groups_json="$(az_json_or_die network firewall policy rule-collection-group list \
    --subscription "$policy_sub" \
    --resource-group "$policy_rg" \
    --policy-name "$policy_name")"; then
    log_warn "Skipping policy due to query failure: $policy_id"
    return
  fi

  render_rule_section "$rule_groups_json" "Application Rules" "ApplicationRule"
  render_rule_section "$rule_groups_json" "Network Rules" "NetworkRule"
  render_rule_section "$rule_groups_json" "DNAT Rules" "NatRule"
}

render_unattached_firewall_note() {
  local count
  count="$(wc -l < "$NO_POLICY_FIREWALLS_FILE" | tr -d ' ')"

  if [[ "$count" == "0" ]]; then
    return
  fi

  {
    echo "## Firewalls Without Attached Policy"
    echo
    echo "| Subscription | Firewall | Firewall ID |"
    echo "|--------------|----------|-------------|"
  } >> "$OUTPUT_FILE"

  jq -s -r '
    .[]
    | [
        (.subscription // "N/A"),
        (.firewallName // "N/A"),
        (.firewallId // "N/A")
      ]
    | map((. // "N/A") | tostring | gsub("\\|"; "\\\\|"))
    | "| " + join(" | ") + " |"
  ' "$NO_POLICY_FIREWALLS_FILE" >> "$OUTPUT_FILE"

  echo >> "$OUTPUT_FILE"
}

main() {
  trap cleanup EXIT

  require_cmd az
  require_cmd jq
  require_cmd date

  parse_args "$@"
  report_header
  collect_firewalls_and_policies

  local policy_ids
  policy_ids="$(jq -r '.policyId' "$ATTACHED_POLICY_FILE" | awk 'NF' | sort -u)"

  if [[ -z "$policy_ids" ]]; then
    echo "No Azure Firewalls with attached firewall policies were found in the provided subscriptions." >> "$OUTPUT_FILE"
    render_unattached_firewall_note
    log_warn "No attached firewall policies found. Report: $OUTPUT_FILE"
    exit 0
  fi

  local policy_id
  while IFS= read -r policy_id; do
    [[ -z "$policy_id" ]] && continue
    render_policy_section "$policy_id"
  done <<< "$policy_ids"

  render_unattached_firewall_note

  log_info "Report written: $OUTPUT_FILE"
}

main "$@"
