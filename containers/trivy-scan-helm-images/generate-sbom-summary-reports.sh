#!/usr/bin/env bash
# generate-sbom-summary.sh
#   $1  – directory that contains the *_sbom.json files
#   Output:
#       version-conflicts.md  – components with version conflicts
#       inventory.md          – full component inventory by type

set -euo pipefail

# -------------------------------------------------------------------------
# Helper
# -------------------------------------------------------------------------
usage() {
    cat <<'EOF'
Usage: $0 <directory>

  <directory>  Path to a folder that contains CycloneDX SBOM files
               (files must end with "_sbom.json").
EOF
    exit 1
}

# -------------------------------------------------------------------------
# Argument check
# -------------------------------------------------------------------------
if [[ $# -ne 1 ]] || [[ ! -d "$1" ]]; then
    echo "Error: please supply a valid directory." >&2
    usage
fi

DIR="$(realpath "$1")"
CONFLICTS_OUT="$DIR/version-conflicts.md"
INVENTORY_OUT="$DIR/inventory.md"

# -------------------------------------------------------------------------
# Secure temporary files
# -------------------------------------------------------------------------
TEMP_COMPONENTS=$(mktemp) || exit 1
TEMP_SORTED=$(mktemp)     || exit 1
trap 'rm -f "$TEMP_COMPONENTS" "$TEMP_SORTED"' EXIT

# -------------------------------------------------------------------------
# 1. Gather raw data: type|name|version|image
# -------------------------------------------------------------------------
> "$TEMP_COMPONENTS"

find "$DIR" -type f -name '*_sbom.json' -print0 |
while IFS= read -r -d '' file; do
    image=$(jq -r '.metadata.component.name // .metadata.component."bom-ref" // "unknown"' "$file")
    jq -e '.components // empty' "$file" >/dev/null || continue

    jq -r --arg img "$image" '
        .components[] |
        [
            (.type // "unknown"),
            (.name // "unknown"),
            (.version // "unknown"),
            $img
        ] | join("|")
    ' "$file" >> "$TEMP_COMPONENTS"
done

# -------------------------------------------------------------------------
# 2. Deduplicate + sort
# -------------------------------------------------------------------------
sort "$TEMP_COMPONENTS" | uniq > "$TEMP_SORTED"

# -------------------------------------------------------------------------
# 3. Generate BOTH reports in one awk pass
# -------------------------------------------------------------------------
awk -F'|' \
    -v conflicts_out="$CONFLICTS_OUT" \
    -v inventory_out="$INVENTORY_OUT" \
    -v srcdir="$DIR" \
'
BEGIN {
    # Header for conflicts
    printf "# Version Conflicts Report\n\n_Generated from SBOMs in: %s_\n\n", srcdir > conflicts_out
    printf "_Components that appear with **multiple versions** across images._\n\n" >> conflicts_out

    # Header for inventory
    printf "# Component Inventory\n\n_Generated from SBOMs in: %s_\n\n", srcdir > inventory_out
}
{
    typ   = $1
    name  = $2
    ver   = $3
    img   = $4
    key   = name " @" ver

    # Full inventory
    types[typ][key][img] = 1

    # Conflict detection (name-based, ignore type)
    all[name][ver][img] = 1
}
END {
    # ------------------------------------------------------------------
    # 1. VERSION CONFLICTS → version-conflicts.md
    # ------------------------------------------------------------------
    conflict_count = 0
    for (n in all) {
        ver_cnt = 0
        for (v in all[n]) ver_arr[++ver_cnt] = v
        if (ver_cnt > 1) {
            conflict_names[++conflict_count] = n

            # Build pipe-separated version list
            vers_str = ""
            for (v in all[n]) {
                vers_str = (vers_str == "" ? v : vers_str "|" v)
            }
            conflict_data[n] = vers_str
        }
    }

    if (conflict_count > 0) {
        asort(conflict_names)
        for (i = 1; i <= conflict_count; i++) {
            n = conflict_names[i]
            split(conflict_data[n], ver_arr, "|")

            # Find newest version (lexical)
            newest = ""
            for (j = 1; j in ver_arr; j++) {
                v = ver_arr[j]
                if (newest == "" || v > newest) newest = v
            }

            printf "- **%s** – *latest: `%s`*\n", n, newest >> conflicts_out

            for (j = 1; j in ver_arr; j++) {
                v = ver_arr[j]
                printf "  - **%s**\n", v >> conflicts_out

                delete img_arr; img_cnt = 0
                for (im in all[n][v]) img_arr[++img_cnt] = im
                asort(img_arr)
                for (q = 1; q <= img_cnt; q++) {
                    printf "    - %s\n", img_arr[q] >> conflicts_out
                }
            }
            print "" >> conflicts_out
        }
    } else {
        print "*No version conflicts found.*" >> conflicts_out
    }

    # ------------------------------------------------------------------
    # 2. FULL INVENTORY → inventory.md
    # ------------------------------------------------------------------
    type_cnt = 0
    for (t in types) type_arr[++type_cnt] = t
    asort(type_arr)

    for (i = 1; i <= type_cnt; i++) {
        t = type_arr[i]
        printf "## %s\n\n", t >> inventory_out

        delete comp_arr; comp_cnt = 0
        for (k in types[t]) comp_arr[++comp_cnt] = k
        asort(comp_arr)

        for (j = 1; j <= comp_cnt; j++) {
            k = comp_arr[j]
            printf "- **%s**\n", k >> inventory_out

            delete img_arr; img_cnt = 0
            for (im in types[t][k]) img_arr[++img_cnt] = im
            asort(img_arr)

            for (q = 1; q <= img_cnt; q++) {
                printf "  - %s\n", img_arr[q] >> inventory_out
            }
            print "" >> inventory_out
        }
        print "" >> inventory_out
    }

    # Final message
    printf "\n**%d component type(s) scanned.**\n", type_cnt >> inventory_out
}
' "$TEMP_SORTED"

# -------------------------------------------------------------------------
# Done
# -------------------------------------------------------------------------
echo "Reports generated:"
echo "   Version Conflicts: $CONFLICTS_OUT"
echo "   Full Inventory:    $INVENTORY_OUT"