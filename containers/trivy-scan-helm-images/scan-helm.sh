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
DEBUG=false

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
  -h, --help                Show this help and exit
EOF
  exit 1
}

# ---------- Parse arguments ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--chart)      HELM_CHART="$2";      shift 2 ;;
    -v|--values)     VALUES_FILE="$2";     shift 2 ;;
    -r|--release)    RELEASE_NAME="$2";    shift 2 ;;
    -n|--namespace)  NAMESPACE="$2";       shift 2 ;;
    -o|--output)     OUTPUT_DIR="$2";      shift 2 ;;
    -C|--cache)      TRIVY_CACHE_DIR="$2"; shift 2 ;;
    -d|--debug)      DEBUG=true;           shift 1 ;;
    -h|--help)       usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

# ---------- Validate required args ----------
[[ -z "$HELM_CHART" ]]   && { echo "Error: --chart is required";   usage; }
[[ -z "$VALUES_FILE" ]]  && { echo "Error: --values is required";  usage; }
[[ ! -d "$HELM_CHART" ]] && { echo "Error: Chart directory not found: $HELM_CHART"; exit 1; }
[[ ! -f "$VALUES_FILE" ]]&& { echo "Error: Values file not found: $VALUES_FILE"; exit 1; }

# ---------- Ensure tools ----------
for cmd in helm yq; do
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

echo $images

# ------------------------------------------------------------
# 3. Run Trivy on each image
# ------------------------------------------------------------
for img in "${images[@]}"; do
    set -x
    # Sanitize image name for filesystem (replace / : with _)
    safe_name=$(echo "$img" | tr '/' '_' | tr ':' '_')
    cve_file="${safe_name}_cve.json"
    sbom_file="${safe_name}_sbom.json"

    echo "Scanning $img ..."

    docker pull $img

    # Generate SBOM
    docker run -it -v ${OUTPUT_DIR}:/output -v /var/run/docker.sock:/var/run/docker.sock --rm aquasec/trivy:latest image --format cyclonedx --output /output/"$sbom_file" $img

    # Generage CVE report; drop the --severity param if you want a full one
    docker run -it -v ${OUTPUT_DIR}:/output -v /var/run/docker.sock:/var/run/docker.sock --rm aquasec/trivy:latest image --severity CRITICAL,HIGH --format json --output /output/"$cve_file" $img

    echo "  -> CVE:  $cve_file"
    echo "  -> SBOM: $sbom_file"

    docker rmi $img >/dev/null 2>&1 || true
done

echo "All done! Reports are in $OUTPUT_DIR"

