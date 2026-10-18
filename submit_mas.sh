#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Readlet 1.0.0 — Automated Mac App Store Submission Pipeline (via `asc` CLI)
# ==============================================================================
# Prerequisites:
#   1. Run `asc web auth login --apple-id "$APPLE_ID"` once
#      (or configure `asc auth login` + a cached web session).
#   2. Ensure `dist/Readlet-1.0.0-AppStore.pkg` exists (built via `./build_mas.sh`).
# ==============================================================================

cd "$(dirname "$0")"
[ -f .env.local ] && . ./.env.local

: "${APPLE_ID:?set APPLE_ID in environment or .env.local}"
: "${TEAM_ID:?set TEAM_ID in environment or .env.local}"
: "${PUBLIC_PROVIDER_ID:?set PUBLIC_PROVIDER_ID in environment or .env.local}"
BUNDLE_ID="io.novarock.readlet"
SKU="READLET001"
APP_NAME="Readlet – AI Bilingual Reader"
VERSION=$(cat VERSION)
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
PKG_PATH="dist/Readlet-${VERSION}-AppStore.pkg"

echo "==> [1/10] Checking asc web session & API key authentication..."
if ! asc web auth status --apple-id "$APPLE_ID" --output json | grep -q '"authenticated":true'; then
    echo "No cached Apple web session found for $APPLE_ID. Starting interactive login..."
    asc web auth login --apple-id "$APPLE_ID"
fi

if ! asc auth status --output json | grep -q '"name"'; then
    echo "==> Creating & registering App Store Connect Team API Key via web session..."
    mkdir -p ~/.asc/keys
    chmod 700 ~/.asc/keys
    KEY_JSON=$(asc web api-keys create \
        --apple-id "$APPLE_ID" \
        --public-provider-id "$PUBLIC_PROVIDER_ID" \
        --name "Readlet CLI Automation" \
        --role ADMIN \
        --output-dir ~/.asc/keys \
        --output json)
    KEY_ID=$(echo "$KEY_JSON" | /usr/bin/python3 -c 'import sys, json; d=json.load(sys.stdin); print(d.get("keyId") or d.get("id") or d.get("data",{}).get("id",""))')
    ISSUER_ID=$(echo "$KEY_JSON" | /usr/bin/python3 -c 'import sys, json; d=json.load(sys.stdin); print(d.get("issuerId") or d.get("providerId") or "")')
    if [[ -z "$ISSUER_ID" ]]; then
        ISSUER_ID=$(asc web api-keys list --apple-id "$APPLE_ID" --public-provider-id "$PUBLIC_PROVIDER_ID" --output json | /usr/bin/python3 -c 'import sys, json; d=json.load(sys.stdin); print(d.get("issuerId",""))')
    fi
    asc auth login \
        --name "readlet-asc" \
        --key-id "$KEY_ID" \
        --issuer-id "$ISSUER_ID" \
        --private-key "$HOME/.asc/keys/AuthKey_${KEY_ID}.p8" \
        --fix-permissions \
        --network
fi

echo "==> [2/10] Creating or resolving App Store Connect app record ($BUNDLE_ID)..."
asc web apps create \
    --apple-id "$APPLE_ID" \
    --name "$APP_NAME" \
    --bundle-id "$BUNDLE_ID" \
    --sku "$SKU" \
    --platform MAC_OS \
    --primary-locale "en-US" \
    --version "$VERSION" \
    --if-exists skip \
    --output json

APP_ID=$(asc apps list --bundle-id "$BUNDLE_ID" --output json | /usr/bin/python3 -c 'import sys, json; d=json.load(sys.stdin); print(d["data"][0]["id"])')
echo "    Resolved APP_ID: $APP_ID"

echo "==> [3/10] Uploading $PKG_PATH ($VERSION build $BUILD_NUMBER) and waiting for processing..."
asc builds upload \
    --app "$APP_ID" \
    --pkg "$PKG_PATH" \
    --version "$VERSION" \
    --build-number "$BUILD_NUMBER" \
    --wait \
    --output json

BUILD_ID=$(asc builds info --app "$APP_ID" --version "$VERSION" --build-number "$BUILD_NUMBER" --platform MAC_OS --output json | /usr/bin/python3 -c 'import sys, json; d=json.load(sys.stdin); print(d["data"]["id"])')
echo "    Resolved BUILD_ID: $BUILD_ID"

echo "==> [4/10] Configuring App Info, Categories, Content Rights & Encryption..."
asc app-setup info set \
    --app "$APP_ID" \
    --primary-locale "en-US" \
    --privacy-policy-url "https://readlet.novarock.io/privacy.html"

asc app-setup categories set \
    --app "$APP_ID" \
    --primary EDUCATION \
    --secondary PRODUCTIVITY

asc apps content-rights edit \
    --app "$APP_ID" \
    --uses-third-party-content=false

echo "==> [5/10] Configuring Free Pricing & Global Territory Availability..."
TODAY=$(date -u +%Y-%m-%d)
asc pricing schedule create \
    --app "$APP_ID" \
    --free \
    --base-territory "USA" \
    --start-date "$TODAY" || true

ALL_TERRITORIES=$(asc pricing territories list --paginate --output json | /usr/bin/python3 -c 'import sys, json; d=json.load(sys.stdin); print(",".join(x["id"] for x in d["data"]))')
if ! asc pricing availability view --app "$APP_ID" --output json >/dev/null 2>&1; then
    asc pricing availability create \
        --app "$APP_ID" \
        --territory "$ALL_TERRITORIES" \
        --available true \
        --available-in-new-territories true || \
    asc web apps availability create \
        --apple-id "$APPLE_ID" \
        --app "$APP_ID" \
        --territory "$ALL_TERRITORIES" \
        --available-in-new-territories true
else
    asc pricing availability edit \
        --app "$APP_ID" \
        --all-territories \
        --available true \
        --available-in-new-territories true
fi

echo "==> [6/10] Configuring Age Rating (4+ / All None) & App Privacy (DATA_NOT_COLLECTED)..."
asc age-rating edit \
    --app "$APP_ID" \
    --all-none \
    --unrestricted-web-access false \
    --gambling false \
    --loot-boxes false \
    --user-generated-content false \
    --social-media false \
    --social-media-age-restricted false \
    --age-assurance false \
    --advertising false \
    --health-or-wellness-topics false \
    --messaging-and-chat false \
    --parental-controls false

asc web privacy apply \
    --apple-id "$APPLE_ID" \
    --public-provider-id "$PUBLIC_PROVIDER_ID" \
    --app "$APP_ID" \
    --file "AppStore/privacy.json"

asc web privacy publish \
    --apple-id "$APPLE_ID" \
    --public-provider-id "$PUBLIC_PROVIDER_ID" \
    --app "$APP_ID" \
    --confirm

echo "==> [7/10] Syncing Localized Metadata (en-US, zh-Hans, ja) & Copyright..."
asc metadata validate --dir "AppStore/asc-metadata" --output table
asc metadata push \
    --app "$APP_ID" \
    --version "$VERSION" \
    --platform MAC_OS \
    --dir "AppStore/asc-metadata"

VERSION_ID=$(asc versions list --app "$APP_ID" --platform MAC_OS --output json | /usr/bin/python3 -c 'import sys, json; d=json.load(sys.stdin); print(d["data"][0]["id"])')
asc versions update \
    --version-id "$VERSION_ID" \
    --copyright "${COPYRIGHT_HOLDER:-2026 Novarock}"

echo "==> [8/10] Uploading 12 Retina Screenshots (APP_DESKTOP 2880x1800) across en-US, zh-Hans, ja..."
LOCS_JSON=$(asc localizations list --version "$VERSION_ID" --output json)
for LOC in en-US zh-Hans ja; do
    LOC_ID=$(echo "$LOCS_JSON" | /usr/bin/python3 -c "import sys, json; d=json.load(sys.stdin); print(next(x['id'] for x in d['data'] if x['attributes']['locale']=='$LOC'))")
    echo "    Uploading screenshots for $LOC (localization ID: $LOC_ID)..."
    asc screenshots validate --path "AppStore/screenshots/$LOC" --device-type "APP_DESKTOP" --output table
    asc screenshots upload \
        --version-localization "$LOC_ID" \
        --path "AppStore/screenshots/$LOC" \
        --device-type "APP_DESKTOP" \
        --output json
done

echo "==> [9/10] Setting App Review Contact & Reviewer Notes (with live test AI gateway)..."
REVIEW_NOTES=$(/usr/bin/python3 -c '
import os, re
cfg_path = os.path.expanduser("~/.config/readlet/config.toml")
api_key = ""
gateway_url = os.environ.get("REVIEW_GATEWAY_URL", "https://api.openai.com/v1")
if os.path.exists(cfg_path):
    with open(cfg_path) as f:
        m = re.search(r"api_key\s*=\s*\"([^\"]+)\"", f.read())
        if m:
            api_key = m.group(1)
print(f"""Readlet is a macOS document reader for PDF, EPUB, and web articles with optional AI-assisted bilingual translation, page narration, and study notes.

1. Core Reading & Annotation (No API Key Required):
   - Launch Readlet and click "Load Sample Paper" on the welcome screen (or open any PDF/EPUB via Cmd+O).
   - Switch between Original and Bilingual views (Cmd+1 / Cmd+2), highlight text in 8 colors, add margin notes, and organize cards in the Mind Map panel.

2. Testing AI Features (Bilingual Translation, AI Narration & Copilot):
   - Open Settings (Cmd+,) -> AI Gateway / Provider.
   - Mode: Unified Gateway (OpenAI-compatible)
   - Base URL: {gateway_url}
   - API Key: {api_key}
   - Text / Vision Model: gemini-2.5-flash
   - Click "Verify Connection", then click "Translate Page" or start "AI Narration" in the reader toolbar.
""")
')

: "${CONTACT_FIRST_NAME:?set CONTACT_FIRST_NAME in .env.local}"
: "${CONTACT_LAST_NAME:?set CONTACT_LAST_NAME in .env.local}"
: "${CONTACT_EMAIL:?set CONTACT_EMAIL in .env.local}"
: "${CONTACT_PHONE:?set CONTACT_PHONE in .env.local}"

asc review details-create \
    --version-id "$VERSION_ID" \
    --contact-first-name "$CONTACT_FIRST_NAME" \
    --contact-last-name "$CONTACT_LAST_NAME" \
    --contact-email "$CONTACT_EMAIL" \
    --contact-phone "$CONTACT_PHONE" \
    --demo-account-required=false \
    --notes "$REVIEW_NOTES" \
    --if-exists update \
    --output json

echo "==> [10/10] Staging Build, Validating Readiness & Submitting for App Review..."
asc release stage \
    --app "$APP_ID" \
    --version "$VERSION" \
    --platform MAC_OS \
    --build-id "$BUILD_ID" \
    --metadata-dir "AppStore/asc-metadata" \
    --confirm \
    --output table

asc validate \
    --app "$APP_ID" \
    --version "$VERSION" \
    --platform MAC_OS \
    --output table

asc review submit \
    --app "$APP_ID" \
    --version-id "$VERSION_ID" \
    --build-id "$BUILD_ID" \
    --platform MAC_OS \
    --confirm \
    --output table

echo "==> Done! Checking final submission status:"
asc status --app "$APP_ID" --include builds,appstore,submission,review --output table
