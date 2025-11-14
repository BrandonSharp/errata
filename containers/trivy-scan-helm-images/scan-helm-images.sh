#!/usr/bin/env bash
# ------------------------------------------------------------
# scan-helm-images.sh
# Render a Helm chart, extract every container image,
# and generate Trivy CVE + SBOM JSON files (one pair per image).
#
# Usage examples:
#   ./scan-helm-images.sh --chart ./mychart --values ./values.yaml
#   ./scan-helm-images.sh -c ./mychart -v ./values.yaml -r myrel -n default -o ./reports
# ------------------------------------------------------------

set -euo pipefail

# ---------- Default values ----------
HELM_CHART=""
VALUES_FILE=""
RELEASE_NAME="myrelease"
NAMESPACE="default"
OUTPUT_DIR="./trivy-reports"
TRIVY_CACHE_DIR="${HOME}/.cache/trivy"
REPORT_FILE="${OUTPUT_DIR}/trivy-report.md"
DEBUG=false
CLEANUP=true
GENERATE_SBOM_REPORTS=false

# ---------- Helper: usage ----------
usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Options:
  -c, --chart <path>        Path to the Helm chart directory (required)
  -v, --values <file>       Path to values.yaml (required)
  -r, --release <name>      Release name for helm template (default: $RELEASE_NAME)
  -n, --namespace <ns>      Kubernetes namespace (default: $NAMESPACE)
  -o, --output <dir>        Directory for Trivy JSON reports (default: $OUTPUT_DIR)
  -C, --cache <dir>         Trivy cache directory (default: $TRIVY_CACHE_DIR)
  -d, --debug               Enable debug output
  -k, --keep-images         Do not remove pulled images after scanning
  -s, --sbom-reports        Generate SBOM summary reports after scanning
  -h, --help                Show this help and exit
EOF
  exit 1
}

# Function to generate Markdown section for an image
generate_md_section() {
    local image="$1"
    local json_output="$2"
    
    local vuln_count=$(echo "$json_output" | jq '[.Results[].Vulnerabilities[]? // [] | length] | add // 0')
    if [[ "$vuln_count" == "0" ]]; then
        cat << EOF
## Image: $image

No vulnerabilities detected.

EOF
        return
    fi

    local critical_count=$(echo "$json_output" | jq '[.Results[].Vulnerabilities[]? | select(.Severity == "CRITICAL")] | length // 0')
    local high_count=$(echo "$json_output" | jq '[.Results[].Vulnerabilities[]? | select(.Severity == "HIGH")] | length // 0')
    local medium_count=$(echo "$json_output" | jq '[.Results[].Vulnerabilities[]? | select(.Severity == "MEDIUM")] | length // 0')
    local low_count=$(echo "$json_output" | jq '[.Results[].Vulnerabilities[]? | select(.Severity == "LOW")] | length // 0')

    cat << EOF
## Image: $image

**Total vulnerabilities:** $vuln_count  
**Critical:** $critical_count, **High:** $high_count, **Medium:** $medium_count, **Low:** $low_count

| VulnerabilityID | Severity | Title | Description | PrimaryUrl |
|-----------------|----------|-------|-------------|------------|
EOF

    echo "$json_output" | jq -r '.Results[].Vulnerabilities[]? | [
      (.VulnerabilityID // "N/A"),
      (.Severity // "UNKNOWN"),
      (.Title // "No title available"),
      (.Description // "No description available"),
      (.PrimaryURL // "No URL available")
    ] | @tsv' | while IFS=$'\t' read -r vid sev title desc url; do
      echo "| $vid | $sev | $title | $desc | $url |"
    done

    echo ""
}

# ---------- Parse arguments ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--chart)          HELM_CHART="$2";            shift 2 ;;
    -v|--values)         VALUES_FILE="$2";           shift 2 ;;
    -r|--release)        RELEASE_NAME="$2";          shift 2 ;;
    -n|--namespace)      NAMESPACE="$2";             shift 2 ;;
    -o|--output)         OUTPUT_DIR="$2";            shift 2 ;;
    -C|--cache)          TRIVY_CACHE_DIR="$2";       shift 2 ;;
    -d|--debug)          DEBUG=true;                 shift 1 ;;
    -k|--keep-images)    CLEANUP=false;              shift 1 ;;
    -s|--sbom-reports)   GENERATE_SBOM_REPORTS=true; shift 1 ;;
    -h|--help)           usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

# ---------- Validate required args ----------
[[ -z "$HELM_CHART" ]]   && { echo "Error: --chart is required";   usage; }
[[ -z "$VALUES_FILE" ]]  && { echo "Error: --values is required";  usage; }
[[ ! -d "$HELM_CHART" ]] && { echo "Error: Chart directory not found: $HELM_CHART"; exit 1; }
[[ ! -f "$VALUES_FILE" ]]&& { echo "Error: Values file not found: $VALUES_FILE"; exit 1; }

# ---------- Ensure tools ----------
for cmd in helm; do
  command -v "$cmd" >/dev/null || { echo "Error: $cmd not found in PATH"; exit 1; }
done

mkdir -p "$OUTPUT_DIR"


# ------------------------------------------------------------
# 1. Render Helm chart
# ------------------------------------------------------------
echo "Rendering Helm chart..."
rendered_yaml=$(helm template "$RELEASE_NAME" "$HELM_CHART" \
    --values "$VALUES_FILE" \
    --namespace "$NAMESPACE")

# ------------------------------------------------------------
# 2. Extract images
# ------------------------------------------------------------
echo "Extracting container images..."
mapfile -t images < <(
  echo "$rendered_yaml" |
  grep -E '^[[:space:]]+image:' |
  awk -F 'image:' '{
    gsub(/^[ \t]+|[ \t]+$/, "", $2);  # trim whitespace
    gsub(/^["'"'"']|["'"'"']$/, "", $2);  # strip leading/trailing " or '"'"'
    print $2
  }' |
  grep -E '.+/.+[:@].*' |
  sort -u
)

if [[ "$DEBUG" == true ]]; then
  echo "DEBUG: Raw image lines:"
  echo "$rendered_yaml" | grep -E '^[[:space:]]+image:' | head -10
  echo "DEBUG: After awk + sed:"
  echo "$rendered_yaml" | grep -E '^[[:space:]]+image:' | awk -F 'image:' '{print $2}' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | head -5
  echo "DEBUG: After final grep (should match all real images):"
  echo "$rendered_yaml" | grep -E '^[[:space:]]+image:' | awk -F 'image:' '{print $2}' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -E '.+/.+[:@].*' | head -5
fi

if (( ${#images[@]} == 0 )); then
  echo "Still no images? Possible causes:"
  echo "  • images are quoted: image: \"nginx:latest\""
  echo "  • images are in Helm comments or hooks"
  echo "  • chart uses .Values.image but no containers"
  echo ""
  echo "Try: grep -n 'image:' /tmp/rendered.yaml"
  exit 1
fi

printf '%s\n' "${images[@]}" | nl
echo "Found ${#images[@]} unique image(s)."

# ------------------------------------------------------------
# 3. Generate report header
# ------------------------------------------------------------

if [[ -z "$images" ]]; then
        cat > "$REPORT_FILE" << EOF
# Trivy Scan Report for Helm Chart

No images found in the chart directory: $HELM_CHART
EOF
        echo "No images found. Generated empty report: $REPORT_FILE"
        exit 0
    fi
    
    echo "Found images:"
    echo "$images"
    
    # Initialize Markdown report
    cat > "$REPORT_FILE" << EOF
# Trivy Scan Report for Helm Chart

**Chart:** $HELM_CHART  
**Values file:** $VALUES_FILE  
*Generated on: $(date)*  

Scanned images:
EOF
    for image in "${images[@]}"; do
      echo "- $image" >> "$REPORT_FILE"
    done
    echo "" >> "$REPORT_FILE"

# ------------------------------------------------------------
# 4. Run Trivy on each image
# ------------------------------------------------------------
for img in "${images[@]}"; do
    # Sanitize image name for filesystem (replace / : with _)
    safe_name=$(echo "$img" | tr '/' '_' | tr ':' '_')
    cve_file="${safe_name}_cve.json"
    sbom_file="${safe_name}_sbom.json"

    echo "Scanning $img ..."

    docker pull $img

    # Generate SBOM
    docker run -it -v ${OUTPUT_DIR}:/output -v /var/run/docker.sock:/var/run/docker.sock -v ${TRIVY_CACHE_DIR}:/root/.cache/trivy --rm aquasec/trivy:latest image --format cyclonedx --output /output/"$sbom_file" $img

    # Generage CVE report; drop the --severity param if you want a full one
    docker run -it -v ${OUTPUT_DIR}:/output -v /var/run/docker.sock:/var/run/docker.sock -v ${TRIVY_CACHE_DIR}:/root/.cache/trivy --rm aquasec/trivy:latest image --severity CRITICAL,HIGH --format json --output /output/"$cve_file" $img

    echo "  -> CVE:  $cve_file"
    echo "  -> SBOM: $sbom_file"

    # Append to Markdown report
    generate_md_section "$img" "$(cat ${OUTPUT_DIR}/$cve_file)" >> "$REPORT_FILE"

    if [[ "$CLEANUP" == true ]]; then
        docker rmi $img >/dev/null 2>&1 || true
    fi
done

if [[ "$GENERATE_SBOM_REPORTS" == true ]]; then
  echo "Generating SBOM summary reports..."
  "$(dirname "$0")/generate-sbom-summary-reports.sh" "$OUTPUT_DIR"
fi

echo "All done! Reports are in $OUTPUT_DIR"

