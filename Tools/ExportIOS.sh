#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export UNITY_IOS_OUTPUT="$ROOT/UnityIOSExport"
rm -rf UnityIOSExport
set +e
"$UNITY_HOME/Contents/MacOS/Unity" \
  -batchmode -quit -nographics \
  -projectPath "$ROOT/RecoveredUnityProject" \
  -executeMethod GoreBoxIOSBuild.ExportIOS \
  -logFile "$ROOT/BuildArtifacts/UnityIOSExport.log"
RC=$?
set -e
if [ "$RC" -ne 0 ]; then
  echo "Unity export failed with $RC" > BuildArtifacts/UnityExportFailed.txt
  tail -300 BuildArtifacts/UnityIOSExport.log > BuildArtifacts/UnityIOSExportTail.txt || true
  exit "$RC"
fi
find UnityIOSExport -maxdepth 2 -type f | sort > BuildArtifacts/UnityIOSExportFiles.txt
