#!/bin/bash
# Stores the release signing material as GitHub Actions secrets for .github/workflows/release.yml.
# Usage: scripts/setup-release-secrets.sh RedOS.p12 [sparkle-private-key-file]
#   RedOS.p12: Keychain Access > login > My Certificates > "RedOS Development" > Export (only that identity).
#   Without a key file, the Sparkle key is exported from the Keychain (account "redos") to a temporary file.
set -euo pipefail

p12="${1:?usage: $0 RedOS.p12 [sparkle-key-file]}"
key_file="${2:-}"
repo="Carassale/redos"

[[ -f "$p12" ]] || { echo "error: $p12 not found"; exit 1; }
read -r -s -p "Password of $p12: " password
echo

# Early check of the password and content; some openssl builds cannot read newer PKCS#12 files, so only warn.
if ! openssl pkcs12 -in "$p12" -nokeys -passin "pass:$password" 2>/dev/null | grep -q "RedOS Development"; then
    read -r -p "warning: could not verify $p12 (wrong password or no 'RedOS Development'?). Continue? [y/N] " answer
    [[ "$answer" == [yY] ]] || exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
if [[ -z "$key_file" ]]; then
    key_file="$tmp/sparkle.key"
    .build/artifacts/sparkle/Sparkle/bin/generate_keys --account redos -x "$key_file" >/dev/null
fi

base64 -i "$p12" | gh secret set REDOS_CERT_P12 --repo "$repo"
printf '%s' "$password" | gh secret set REDOS_CERT_PASSWORD --repo "$repo"
gh secret set SPARKLE_ED_KEY --repo "$repo" < "$key_file"
echo "Secrets set. Release from GitHub: Actions > Release > Run workflow (or: gh workflow run release.yml -f channel=beta)."
