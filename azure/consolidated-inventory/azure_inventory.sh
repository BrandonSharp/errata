#!/usr/bin/env bash
# =====================================================
# Azure Consolidated Resource Inventory (Bash + AZ CLI)
# Groups resources by type → Markdown report
# =====================================================

set -euo pipefail

# Prerequisites check
command -v az >/dev/null 2>&1 || { echo "❌ Azure CLI (az) not found. Install it first."; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "❌ jq not found. Install with: apt/brew install jq"; exit 1; }

if [ $# -eq 0 ]; then
  echo "Usage: $0 <subscription1> [subscription2] [subscription3] [subscription4]"
  echo "   Subscriptions can be display names or GUIDs (from 'az account list')"
  exit 1
fi

SUBSCRIPTIONS=("$@")
OUTPUT_FILE="azure_resource_inventory_$(date +%Y%m%d_%H%M).md"

cat > "$OUTPUT_FILE" << EOF
# Azure Consolidated Resource Inventory

**Generated:** $(date)  
**Subscriptions processed:** ${#SUBSCRIPTIONS[@]}  
**Subscriptions:** ${SUBSCRIPTIONS[*]}

EOF

echo "🔄 Collecting resources from ${#SUBSCRIPTIONS[@]} subscriptions..." >&2

# Collect everything into one JSON array
ALL_RESOURCES="[]"
for sub in "${SUBSCRIPTIONS[@]}"; do
  sub_name=$(az account show --subscription "$sub" --query name -o tsv 2>/dev/null || echo "$sub")
  echo "   → $sub_name" >&2

  resources=$(az resource list --subscription "$sub" --output json)

  # Enrich each resource with subscription name and keep only useful fields
  enriched=$(echo "$resources" | jq --arg subname "$sub_name" '
    map(. + {subscription: $subname})
    | map({subscription, resourceGroup, name, type, location})
  ')

  ALL_RESOURCES=$(echo "$ALL_RESOURCES" | jq --argjson new "$enriched" '. + $new')
done

TOTAL=$(echo "$ALL_RESOURCES" | jq 'length')

# === Summary ===
cat >> "$OUTPUT_FILE" << EOF

## Summary
**Total resources found:** $TOTAL

### Count by Resource Type

| Resource Type                  | Count |
|--------------------------------|-------|
EOF

echo "$ALL_RESOURCES" | jq -r '
  group_by(.type)
  | sort_by(.[0].type)[]
  | "| `\(. [0].type)` | \(length) |"
' >> "$OUTPUT_FILE"

# === Detailed grouped sections ===
cat >> "$OUTPUT_FILE" << EOF

## Detailed Inventory (grouped by Resource Type)

EOF

# Get unique sorted resource types
mapfile -t TYPES < <(echo "$ALL_RESOURCES" | jq -r 'map(.type) | unique | sort[]')

for t in "${TYPES[@]}"; do
  echo "### $t" >> "$OUTPUT_FILE"
  echo "" >> "$OUTPUT_FILE"
  echo "| Subscription | Resource Group | Name | Location |" >> "$OUTPUT_FILE"
  echo "|--------------|----------------|------|----------|" >> "$OUTPUT_FILE"

  # Build table rows for this type only (sorted by subscription then name)
  echo "$ALL_RESOURCES" | jq -r --arg type "$t" '
    [.[] | select(.type == $type)]
    | sort_by(.subscription, .name)[]
    | "| \(.subscription | gsub("\\|"; "\\\\|")) | \(.resourceGroup | gsub("\\|"; "\\\\|")) | \(.name | gsub("\\|"; "\\\\|")) | \(.location // "N/A" | gsub("\\|"; "\\\\|")) |"
  ' >> "$OUTPUT_FILE"

  echo "" >> "$OUTPUT_FILE"
done

echo "✅ Report saved as **$OUTPUT_FILE**" >&2