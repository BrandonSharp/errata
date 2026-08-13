#!/bin/bash
# generate-csr-keyvault-per-domain.sh
# Generate ONE CSR per domain in Azure Key Vault (individual TLS certificates)
#
# Usage:
#   ./generate-csr-keyvault-per-domain.sh <domains_file> <key-vault-name> [cert-name-prefix]
#
# Requirements:
#   - Azure CLI (`az`) installed and logged in (`az login`)
#   - Permissions on the Key Vault: certificates/create, certificates/get, certificates/pending
#
# What it does:
#   - Reads every domain from the file (one per line)
#   - Creates a separate certificate object in Key Vault for each domain
#   - Generates a CSR with CN = domain + SAN = DNS:domain (best practice)
#   - Saves one .csr file per domain (e.g. example.com.csr)
#   - Private keys stay securely inside Key Vault

set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: $0 <domains_file> <key-vault-name> [cert-name-prefix]"
  echo "Example: $0 domains.txt my-keyvault"
  echo "Example with prefix: $0 domains.txt my-keyvault prod"
  exit 1
fi

DOMAINS_FILE="$1"
VAULT_NAME="$2"
PREFIX="${3:-}"   # optional prefix for Key Vault certificate names

# Read domains (skip empty lines, trim whitespace)
mapfile -t DOMAINS < <(grep -v '^[[:space:]]*$' "$DOMAINS_FILE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

if [[ ${#DOMAINS[@]} -eq 0 ]]; then
  echo "Error: No domains found in $DOMAINS_FILE"
  exit 1
fi

echo "🚀 Generating ${#DOMAINS[@]} individual CSRs in Key Vault '$VAULT_NAME'"
echo "   Vault: $VAULT_NAME"
if [[ -n "$PREFIX" ]]; then
  echo "   Certificate name prefix: $PREFIX"
fi
echo ""

CSR_FILES=()
CERT_NAMES=()

for DOMAIN in "${DOMAINS[@]}"; do
  # Sanitize domain for Key Vault certificate name (must be lowercase alphanumeric + hyphen)
  CERT_NAME="${DOMAIN//./-}"
  CERT_NAME="${CERT_NAME,,}"          # lowercase
  if [[ -n "$PREFIX" ]]; then
    CERT_NAME="${PREFIX}-${CERT_NAME}"
  fi

  CSR_FILE="${DOMAIN}.csr"

  echo "📌 Processing: $DOMAIN"
  echo "   → Key Vault cert name : $CERT_NAME"
  echo "   → CSR file            : $CSR_FILE"

  # Create temporary policy JSON (single-domain with SAN)
  POLICY_FILE=$(mktemp /tmp/keyvault-policy.XXXXXX.json)

  cat > "$POLICY_FILE" <<EOF
{
  "issuerParameters": {
    "name": "Unknown"
  },
  "keyProperties": {
    "exportable": true,
    "keySize": 2048,
    "keyType": "RSA",
    "reuseKey": false
  },
  "x509CertificateProperties": {
    "subject": "CN=${DOMAIN}",
    "validityInMonths": 12,
    "subjectAlternativeNames": {
      "dnsNames": [
        "${DOMAIN}"
      ]
    }
  }
}
EOF

  # Create the certificate in Key Vault (private key never leaves the vault)
  az keyvault certificate create \
    --vault-name "$VAULT_NAME" \
    --name "$CERT_NAME" \
    --policy "@$POLICY_FILE" \
    --output none

  # Retrieve the pending CSR (base64)
  CSR_B64=$(az keyvault certificate pending show \
    --vault-name "$VAULT_NAME" \
    --name "$CERT_NAME" \
    --query "csr" \
    -o tsv)

  # Write the standard PEM CSR file
  {
    echo "-----BEGIN CERTIFICATE REQUEST-----"
    echo "$CSR_B64" | fold -w 64
    echo "-----END CERTIFICATE REQUEST-----"
  } > "$CSR_FILE"

  # Cleanup
  rm -f "$POLICY_FILE"

  # Store for summary
  CSR_FILES+=("$CSR_FILE")
  CERT_NAMES+=("$CERT_NAME")

  echo "   ✅ CSR ready for $DOMAIN"
  echo ""
done

# Final summary
echo "🎉 All done! ${#CSR_FILES[@]} individual CSRs generated."
echo ""
echo "Summary:"
for ((i=0; i<${#DOMAINS[@]}; i++)); do
  echo "   ${DOMAINS[i]}  →  ${CSR_FILES[i]}  (Key Vault certificate: ${CERT_NAMES[i]})"
done

echo ""
echo "Next steps for each certificate:"
echo "1. Submit the .csr file to your CA (Let’s Encrypt, DigiCert, etc.)"
echo "2. When you receive the signed certificate, merge it back into Key Vault:"
echo "   az keyvault certificate pending merge \\"
echo "     --vault-name $VAULT_NAME \\"
echo "     --name <cert-name-from-summary-above> \\"
echo "     --file signed-cert.cer"
echo ""
echo "To verify any CSR:"
echo "   openssl req -text -noout -in <domain>.csr | grep -E 'Subject:|DNS:'"
echo ""
echo "You now have completely separate TLS certificates (one per domain) with private keys safely stored in Azure Key Vault."