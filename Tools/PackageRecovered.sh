#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [ ! -d RecoveredUnityProject/Assets ]; then
  echo "No recovered project" > BuildArtifacts/PackageError.txt
  exit 30
fi
rm -f BuildArtifacts/GoreBox_Recovered_Unity_Project.zip
(cd RecoveredUnityProject && zip -qry "$ROOT/BuildArtifacts/GoreBox_Recovered_Unity_Project.zip" .)
ls -lh BuildArtifacts/GoreBox_Recovered_Unity_Project.zip > BuildArtifacts/RecoveredZipInfo.txt
echo "RECOVER_ONLY_COMPLETE" > BuildArtifacts/Status.txt
