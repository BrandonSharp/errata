#!/bin/bash

# Usage: ./delete_mg_hierarchy.sh <management-group-name> [--dry-run] [--yes]

MG_NAME="$1"
DRY_RUN=false
YES=false

if [ -z "$MG_NAME" ]; then
  echo "Usage: $0 <management-group-name> [--dry-run] [--yes]"
  echo "  --dry-run: List groups without deleting"
  echo "  --yes:     Skip confirmation prompt"
  exit 1
fi

# Parse optional flags
shift  # Remove the management group name from arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --yes)
      YES=true
      shift
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# Declare a global array
declare -a GROUPS_ORDER=()

# Function to recursively collect management group names in post-order (leaves first)
collect_postorder() {
  local group="$1"
  local children=$(az account management-group show --name "$group" --expand --query "children[?type=='Microsoft.Management/managementGroups'].name" -o tsv)

  for child in $children; do
    collect_postorder "$child"
  done
  
  # Append to global array
  GROUPS_ORDER+=("$group")
}

echo "Collecting management groups to delete under '$MG_NAME' (including itself)..."

# Get list in deletion order (deepest first)
collect_postorder "$MG_NAME"

# Now use the array
echo "Groups to be deleted (in human-readable order, top-down):"
printf "%s\n" "${GROUPS_ORDER[@]}" | tac | nl

if [ "$DRY_RUN" = true ]; then
  echo "(Dry run: No deletions will be performed.)"
  exit 0
fi

if [ "$YES" = false ]; then
  read -p "Type 'yes' to confirm deletion: " CONFIRM
  if [ "$CONFIRM" != "yes" ]; then
    echo "Aborted."
    exit 1
  fi
fi

# Delete in post-order (leaves first)
for group in "${GROUPS_ORDER[@]}"; do
  echo "Deleting management group: $group"
  az account management-group delete --name "$group" # --yes
  if [ $? -eq 0 ]; then
    echo "Deleted $group successfully."
  else
    echo "Failed to delete $group (may have children or permissions issue)."
  fi
done

echo "Deletion process complete."