#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [ ! -f StageWorkspace/Tools/RecoverProject.sh ]; then
  echo "RecoverProject.sh missing" | tee BuildArtifacts/RecoveryError.txt
  exit 20
fi
# Keep Stage1 logs, but copy them to the top-level artifact folder even if recovery fails.
set +e
( cd StageWorkspace && bash Tools/RecoverProject.sh ) 2>&1 | tee BuildArtifacts/RecoveryConsole.txt
RC=${PIPESTATUS[0]}
set -e
if [ -d StageWorkspace/BuildArtifacts ]; then
  mkdir -p BuildArtifacts/Stage1
  cp -R StageWorkspace/BuildArtifacts/. BuildArtifacts/Stage1/ || true
fi
if [ "$RC" -ne 0 ]; then
  echo "Stage1 recovery exited with $RC" | tee BuildArtifacts/RecoveryFailed.txt
  exit "$RC"
fi
if [ ! -d StageWorkspace/RecoveredUnityProject/Assets ]; then
  echo "Recovered Unity project has no Assets directory" | tee BuildArtifacts/RecoveryFailed.txt
  exit 21
fi
rm -rf RecoveredUnityProject
cp -R StageWorkspace/RecoveredUnityProject RecoveredUnityProject
printf 'RECOVERY_OK\n' > BuildArtifacts/RecoveryOK.txt
