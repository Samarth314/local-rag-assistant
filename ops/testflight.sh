#!/bin/zsh
# testflight.sh - archive the ATARU app and upload it to TestFlight.
#
# Works for any team member with a Developer+ role and an App Store Connect
# API key. Every internal tester's phone gets the build wirelessly ~5-15 min
# after upload. Build numbers are date-derived; the repo is never modified.
#
# One-time setup: create ~/.config/ataru/testflight.env containing
#     ASC_KEY_ID=XXXXXXXXXX          # your API key id
#     ASC_ISSUER_ID=xxxxxxxx-...     # issuer id from your keys page
#     ASC_KEY_PATH=$HOME/.config/ataru/AuthKey_XXXXXXXXXX.p8
#     ASC_SIGNING=automatic          # 'automatic' needs the cloud-managed
#                                    # distribution cert permission on your
#                                    # account; 'manual' expects the
#                                    # 'ATARU App Store' profile + cert in
#                                    # your keychain.
# and chmod 600 both files.
set -euo pipefail

CONF="$HOME/.config/ataru/testflight.env"
[ -f "$CONF" ] || { echo "missing $CONF - see header for setup"; exit 1 }
source "$CONF"
: "${ASC_KEY_ID:?}" "${ASC_ISSUER_ID:?}" "${ASC_KEY_PATH:?}"
SIGNING="${ASC_SIGNING:-automatic}"

BUILD_NUM="$(date +%Y%m%d%H%M)"
WORK="$(mktemp -d /tmp/ataru-testflight.XXXXXX)"
ARCHIVE="$WORK/ATARU.xcarchive"
cd "$(dirname "$0")/../app"

echo "== ATARU TestFlight upload, build $BUILD_NUM (signing: $SIGNING) =="
xcodegen generate >/dev/null

xcodebuild archive \
  -scheme ATARU -project ATARU.xcodeproj \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  CURRENT_PROJECT_VERSION="$BUILD_NUM" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  > "$WORK/archive.log" 2>&1 || { tail -5 "$WORK/archive.log"; echo "ARCHIVE FAILED - log: $WORK/archive.log"; exit 1 }
[ -d "$ARCHIVE" ] || { echo "archive missing"; exit 1 }

if [ "$SIGNING" = "manual" ]; then
  SIGNBLOCK='<key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Apple Distribution</string>
  <key>provisioningProfiles</key><dict>
    <key>com.aryasasikumar.ataru.ATARU</key><string>ATARU App Store</string>
  </dict>'
else
  SIGNBLOCK='<key>signingStyle</key><string>automatic</string>'
fi

cat > "$WORK/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  $SIGNBLOCK
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PLIST

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$WORK/ExportOptions.plist" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  > "$WORK/export.log" 2>&1 || { tail -5 "$WORK/export.log"; echo "UPLOAD FAILED - archive kept at $ARCHIVE, log: $WORK/export.log"; exit 1 }

grep -E "Uploaded|EXPORT SUCCEEDED" "$WORK/export.log" | head -2
echo "== build $BUILD_NUM uploaded - phones update in ~5-15 min =="
rm -rf "$WORK"
