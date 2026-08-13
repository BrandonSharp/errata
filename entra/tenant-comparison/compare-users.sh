#!/usr/bin/env bash

set -euo pipefail

SOURCE_TENANT=""
SOURCE_CLOUD="AzureCloud"
SOURCE_ACCOUNT=""
OUTPUT_FILE="tenant-user-sync-report_$(date +%Y%m%d_%H%M%S).md"
SECONDARIES=()

usage() {
	cat <<EOF
Usage: $0 --source-tenant <tenant-id> --secondary <tenant-id[:cloud[:account]]> [options]

Compare users in one source Entra tenant with users in one or more secondary tenants.
Users are matched by the local part of their userPrincipalName, case-insensitively.

Required:
	-s, --source-tenant <id>       Source tenant ID or domain
	-t, --secondary <descriptor>   Secondary tenant descriptor; repeat this option

Options:
			--source-cloud <name>      Source Azure cloud (default: AzureCloud)
			--source-account <name>    Account to use when logging into the source tenant
	-o, --output <file>            Markdown report path (default: $OUTPUT_FILE)
	-h, --help                     Show this help

Descriptor format:
	<tenant-id>[:<cloud>[:<account>]]

Examples:
	$0 --source-tenant source.example.com \\
		--secondary secondary.example.com:AzureCloud:admin@bar.com
	$0 -s source-tenant-id -t gov-tenant-id:AzureUSGovernment -o report.md

The script runs 'az login' for each tenant. Omit an account when the Azure CLI
can select the correct cached account or your login method does not require one.
EOF
}

error() {
	echo "Error: $*" >&2
	exit 1
}

require_command() {
	command -v "$1" >/dev/null 2>&1 || error "$1 not found in PATH"
}

login_to_tenant() {
	local tenant="$1"
	local cloud="$2"
	local account="$3"

	echo "Logging into tenant '$tenant' in cloud '$cloud'..." >&2
	az cloud set --name "$cloud"
	if [[ -n "$account" ]]; then
		az login --tenant "$tenant" --username "$account" --allow-no-subscriptions --output none
	else
		az login --tenant "$tenant" --allow-no-subscriptions --output none
	fi
}

fetch_users() {
	local tenant="$1"
	local cloud="$2"
	local output_file="$3"
	local graph_endpoint
	local next_url
	local page_file

	graph_endpoint=$(az cloud show --query endpoints.microsoftGraphResourceId -o tsv)
	[[ -n "$graph_endpoint" ]] || error "No Microsoft Graph endpoint found for cloud '$cloud'"

	page_file=$(mktemp)
	next_url="${graph_endpoint%/}/v1.0/users?\$select=id,displayName,userPrincipalName&\$top=999"
	printf '[]\n' > "$output_file"

	while [[ -n "$next_url" ]]; do
		az rest --method get --url "$next_url" --output json > "$page_file"
		jq -e '.value | type == "array"' "$page_file" >/dev/null \
			|| error "Unexpected Microsoft Graph response while reading tenant '$tenant'"
		jq -s '.[0] + .[1].value' "$output_file" "$page_file" > "${output_file}.tmp"
		mv "${output_file}.tmp" "$output_file"
		next_url=$(jq -r '.["@odata.nextLink"] // empty' "$page_file")
	done

	rm -f "$page_file"
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		-s|--source-tenant)
			[[ $# -ge 2 ]] || error "$1 requires a value"
			SOURCE_TENANT="$2"
			shift 2
			;;
		--source-cloud)
			[[ $# -ge 2 ]] || error "$1 requires a value"
			SOURCE_CLOUD="$2"
			shift 2
			;;
		--source-account)
			[[ $# -ge 2 ]] || error "$1 requires a value"
			SOURCE_ACCOUNT="$2"
			shift 2
			;;
		-t|--secondary)
			[[ $# -ge 2 ]] || error "$1 requires a value"
			SECONDARIES+=("$2")
			shift 2
			;;
		-o|--output)
			[[ $# -ge 2 ]] || error "$1 requires a value"
			OUTPUT_FILE="$2"
			shift 2
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			error "Unknown option '$1'"
			;;
	esac
done

[[ -n "$SOURCE_TENANT" ]] || { usage >&2; error "--source-tenant is required"; }
[[ ${#SECONDARIES[@]} -gt 0 ]] || { usage >&2; error "At least one --secondary is required"; }

require_command az
require_command jq

work_dir=$(mktemp -d)
cleanup() {
	rm -rf "$work_dir"
}
trap cleanup EXIT

source_users="$work_dir/source-users.json"
source_keys="$work_dir/source-keys.json"

login_to_tenant "$SOURCE_TENANT" "$SOURCE_CLOUD" "$SOURCE_ACCOUNT"
fetch_users "$SOURCE_TENANT" "$SOURCE_CLOUD" "$source_users"
jq 'map(select(.userPrincipalName != null and (.userPrincipalName | contains("@")))) | map({key: (.userPrincipalName | split("@")[0] | ascii_downcase), value: true}) | from_entries' "$source_users" > "$source_keys"

{
	echo "# Entra Tenant User Synchronization Report"
	echo
	echo "**Generated:** $(date)  "
	echo "**Source tenant:** $SOURCE_TENANT  "
	echo "**Source cloud:** $SOURCE_CLOUD  "
	echo
} > "$OUTPUT_FILE"

total_missing=0

for descriptor in "${SECONDARIES[@]}"; do
	IFS=: read -r secondary_tenant secondary_cloud secondary_account <<< "$descriptor"
	secondary_cloud="${secondary_cloud:-AzureCloud}"
	secondary_account="${secondary_account:-}"
	[[ -n "$secondary_tenant" ]] || error "Invalid secondary descriptor '$descriptor'"

	secondary_users="$work_dir/secondary-${#descriptor}-${RANDOM}.json"
	login_to_tenant "$secondary_tenant" "$secondary_cloud" "$secondary_account"
	fetch_users "$secondary_tenant" "$secondary_cloud" "$secondary_users"

	missing_count=$(jq --slurpfile source "$source_keys" '[.[] | select(.userPrincipalName != null and (.userPrincipalName | contains("@"))) | select((.userPrincipalName | split("@")[0] | ascii_downcase) as $name | ($source[0] | has($name) | not))] | length' "$secondary_users")
	total_missing=$((total_missing + missing_count))

	{
		echo "## Secondary Tenant: $secondary_tenant"
		echo
		echo "**Cloud:** $secondary_cloud  "
		echo "**Users missing from source:** $missing_count"
		echo
		if [[ "$missing_count" -eq 0 ]]; then
			echo "No secondary-only users found."
		else
			echo "| Display name | Secondary UPN | Object ID |"
			echo "|--------------|---------------|-----------|"
			jq -r --slurpfile source "$source_keys" '[.[] | select(.userPrincipalName != null and (.userPrincipalName | contains("@"))) | select((.userPrincipalName | split("@")[0] | ascii_downcase) as $name | ($source[0] | has($name) | not))] | sort_by(.userPrincipalName)[] | "| \(.displayName // "N/A" | gsub("\\|"; "\\|")) | \(.userPrincipalName) | \(.id) |"' "$secondary_users"
		fi
		echo
	} >> "$OUTPUT_FILE"
done

echo "**Total secondary-only users:** $total_missing" >> "$OUTPUT_FILE"
echo "Report saved to $OUTPUT_FILE" >&2
