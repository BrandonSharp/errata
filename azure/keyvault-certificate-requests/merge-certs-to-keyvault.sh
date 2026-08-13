#!/bin/bash
# merge-certs-keyvault-per-domain.sh
# Merge signed TLS certificates back into Azure Key Vault (one per domain)
#
# This script is the companion to generate-csr-keyvault-per-domain.sh
# It uses the exact same naming logic for Key Vault certificate objects.
#
# Usage:
#   ./merge-certs-keyvault-per-domain.sh <domains_file> <key-vault-name> [cert-name-prefix]
#
# Requirements:
#   - Azure CLI (`az`) installed and logged in (`az login`)
#   - Permissions: certificates/update, certificates/get
#   - Signed certificate files must be in the current directory and named:
#        <domain>.cer   (PEM or DER format – most CAs give you this)
#     Example: example.com.cer, www.example.com.cer, etc.
#
# What it does:
#   - Reads every domain from domains.txt
#   - Computes the exact same Key Vault certificate name as the CSR generator
#   - Merges the corresponding <domain>.cer file into the pending operation
#   - Private key never leaves Key Vault – the certificate is now fully usable

set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: $0 <domains_file> <key-vault-name> [cert-name-prefix]"
  echo "Example: $0 domains.txt my-production-vault"
  echo "Example with prefix: $0 domains.txt my-production-vault prod"
  exit 1
fi

DOMAINS_FILE="$1"
VAULT_NAME="$2"
PREFIX="${3:-}"

# Read domains (skip empty lines, trim whitespace)
mapfile -t DOMAINS < <(grep -v '^[[:space:]]*$' "$DOMAINS_FILE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

if [[ ${#DOMAINS[@]} -eq 0 ]]; then
  echo "Error: No domains found in $DOMAINS_FILE"
  exit 1
fi

echo "🔄 Merging ${#DOMAINS[@]} signed certificates into Key Vault '$VAULT_NAME'"
if [[ -n "$PREFIX" ]]; then
  echo "   Certificate name prefix: $PREFIX"
fi
echo ""

MERGED=()
FAILED=()

for DOMAIN in "${DOMAINS[@]}"; do
  # Compute the exact same certificate name used during CSR generation
  CERT_NAME="${DOMAIN//./-}"
  CERT_NAME="${CERT_NAME,,}"          # lowercase
  if [[ -n "$PREFIX" ]]; then
    CERT_NAME="${PREFIX}-${CERT_NAME}"
  fi

  SIGNED_FILE="${DOMAIN}.cer"

  echo "📌 Processing: $DOMAIN"
  echo "   → Key Vault cert name : $CERT_NAME"
  echo "   → Signed cert file    : $SIGNED_FILE"

  # Check that the signed certificate file exists
  if [[ ! -f "$SIGNED_FILE" ]]; then
    echo "   ❌ ERROR: $SIGNED_FILE not found in current directory"
    FAILED+=("$DOMAIN")
    echo ""
    continue
  fi

  # Merge the signed certificate into the pending operation in Key Vault
  if az keyvault certificate pending merge \
    --vault-name "$VAULT_NAME" \
    --name "$CERT_NAME" \
    --file "$SIGNED_FILE" \
    --output none; then
    echo "   ✅ Successfully merged into Key Vault"
    MERGED+=("$DOMAIN")
  else
    echo "   ❌ Merge failed (check az output above)"
    FAILED+=("$DOMAIN")
  fi

  echo ""
done

# Final summary
echo "========================================"
if [[ ${#MERGED[@]} -gt 0 ]]; then
  echo "✅ Successfully merged ${#MERGED[@]} certificate(s):"
  for DOMAIN in "${MERGED[@]}"; do
    echo "   • $DOMAIN"
  done
fi

if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "❌ Failed to merge ${#FAILED[@]} certificate(s):"
  for DOMAIN in "${FAILED[@]}"; do
    echo "   • $DOMAIN"
  done
  echo ""
  echo "Troubleshooting tips:"
  echo "• Make sure the pending CSR still exists (run the CSR script again if needed)"
  echo "• Verify file format – should be PEM (-----BEGIN CERTIFICATE-----) or DER"
  echo "• Check az CLI output above for specific errors"
fi

if [[ ${#MERGED[@]} -gt 0 ]]; then
  echo ""
  echo "🎉 All merged certificates are now active in Key Vault!"
  echo ""
  echo "Quick verification commands:"
  echo "   az keyvault certificate show --vault-name $VAULT_NAME --name <cert-name> --query \"attributes.enabled\""
  echo ""
  echo "You can now use these certificates directly in:"
  echo "• Azure App Service, Front Door, Application Gateway, etc."
  echo "• Or export them if needed: az keyvault certificate download ..."
fi

echo ""
echo "Done! Your individual TLS certificates (one per domain) are now fully provisioned in Azure Key Vault."