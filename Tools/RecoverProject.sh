#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p BuildArtifacts RuntimeTools
printf 'Stage 1 build started\n' > BuildArtifacts/BuildStarted.txt
python3 Tools/VerifyRepository.py | tee BuildArtifacts/RepositoryCheck.txt
python3 Tools/ReassembleSource.py | tee BuildArtifacts/ReassemblyLog.txt
rm -rf RuntimeTools/AssetRipperCLI RecoveredUnityProject

echo "Installing/checking dotnet" | tee BuildArtifacts/AssetRipperBuildLog.txt
if ! command -v dotnet >/dev/null 2>&1; then
  brew install dotnet 2>&1 | tee -a BuildArtifacts/AssetRipperBuildLog.txt
fi

echo "Cloning AssetRipper CLI" | tee -a BuildArtifacts/AssetRipperBuildLog.txt
git clone --depth 1 https://github.com/nowl-it/AssetRipperCLI.git RuntimeTools/AssetRipperCLI 2>&1 | tee -a BuildArtifacts/AssetRipperBuildLog.txt
cd RuntimeTools/AssetRipperCLI
SLN="$(find . -maxdepth 2 \( -name '*.slnx' -o -name '*.sln' \) | head -1)"
if [ -z "$SLN" ]; then echo "AssetRipper solution not found" | tee -a "$ROOT/BuildArtifacts/AssetRipperBuildLog.txt"; exit 2; fi
dotnet build "$SLN" -c Release 2>&1 | tee -a "$ROOT/BuildArtifacts/AssetRipperBuildLog.txt"
cd "$ROOT"
AR="$(find RuntimeTools/AssetRipperCLI -type f -name AssetRipper -perm -111 2>/dev/null | head -1 || true)"
ARDLL="$(find RuntimeTools/AssetRipperCLI -type f -name 'AssetRipper*.dll' | grep -E '/bin/Release/' | grep -vE 'Tests|testhost' | head -1 || true)"
ARGS=(--cli --input "$ROOT/SourceData/GameRoot/assets/bin/Data" --output "$ROOT/RecoveredUnityProject" --mode Unity --disable-script-import true --ignore-streaming-assets false --log-path "$ROOT/BuildArtifacts/RecoveryLog.txt")
if [ -n "$AR" ]; then
  echo "Using executable: $AR" | tee -a BuildArtifacts/AssetRipperBuildLog.txt
  "$AR" "${ARGS[@]}"
elif [ -n "$ARDLL" ]; then
  echo "Using DLL: $ARDLL" | tee -a BuildArtifacts/AssetRipperBuildLog.txt
  dotnet "$ARDLL" "${ARGS[@]}"
else
  echo "Could not locate AssetRipper CLI after build" | tee -a BuildArtifacts/AssetRipperBuildLog.txt
  exit 3
fi
if [ ! -d RecoveredUnityProject/Assets ]; then
  echo "AssetRipper returned without Assets folder" | tee BuildArtifacts/RecoveryFailure.txt
  exit 4
fi
mkdir -p RecoveredUnityProject/Assets/GoreBoxIOSPort
cp -R PortOverlay/Assets/GoreBoxIOSPort/. RecoveredUnityProject/Assets/GoreBoxIOSPort/
python3 Tools/PatchRecoveredProject.py | tee BuildArtifacts/PatchLog.txt
rm -f BuildArtifacts/GoreBox_13.7.9_REAL_Recovered_Unity_Project.zip
(cd RecoveredUnityProject && zip -qry "$ROOT/BuildArtifacts/GoreBox_13.7.9_REAL_Recovered_Unity_Project.zip" .)
python3 - <<'PY'
from pathlib import Path
p=Path('BuildArtifacts/GoreBox_13.7.9_REAL_Recovered_Unity_Project.zip')
if not p.exists() or p.stat().st_size<1024:
    raise SystemExit('Recovered project ZIP missing or empty')
print('ZIP_OK',p.stat().st_size)
PY
printf 'Stage 1 build completed successfully\n' > BuildArtifacts/BuildCompleted.txt
ls -lh BuildArtifacts
