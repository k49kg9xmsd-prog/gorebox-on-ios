#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PROJ="$(find UnityIOSExport -maxdepth 2 -name 'Unity-iPhone.xcodeproj' -print -quit)"
if [ -z "$PROJ" ]; then
  echo "Unity-iPhone.xcodeproj not found" > BuildArtifacts/XcodeProjectMissing.txt
  exit 50
fi
DERIVED="$ROOT/XcodeDerivedData"
rm -rf "$DERIVED" Payload
set +e
xcodebuild build \
  -project "$PROJ" \
  -scheme Unity-iPhone \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= \
  2>&1 | tee BuildArtifacts/XcodeBuild.log
RC=${PIPESTATUS[0]}
set -e
if [ "$RC" -ne 0 ]; then
  tail -300 BuildArtifacts/XcodeBuild.log > BuildArtifacts/XcodeBuildTail.txt || true
  exit "$RC"
fi
APP="$(find "$DERIVED/Build/Products/Release-iphoneos" -maxdepth 1 -name '*.app' -print -quit)"
if [ -z "$APP" ]; then
  echo "No .app produced" > BuildArtifacts/AppMissing.txt
  exit 51
fi
mkdir -p Payload
cp -R "$APP" Payload/
rm -f BuildArtifacts/GoreBox-iOS-unsigned.ipa
zip -qry BuildArtifacts/GoreBox-iOS-unsigned.ipa Payload
ls -lh BuildArtifacts/GoreBox-iOS-unsigned.ipa > BuildArtifacts/IPAInfo.txt
echo "IPA_CREATED_UNSIGNED" > BuildArtifacts/Status.txt
