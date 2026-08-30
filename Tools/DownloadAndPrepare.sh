#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p BuildArtifacts CloudPayload
if [ -z "${SOURCE_ARCHIVE_URL:-}" ]; then
  echo "SOURCE_ARCHIVE_URL is empty." | tee BuildArtifacts/DownloadError.txt
  echo "Set it in Codemagic Environment variables to the direct URL of GoreBoxSource.zip." | tee -a BuildArtifacts/DownloadError.txt
  exit 10
fi
rm -f CloudPayload/GoreBoxSource.zip
curl -fL --retry 3 --retry-delay 3 "$SOURCE_ARCHIVE_URL" -o CloudPayload/GoreBoxSource.zip 2>&1 | tee BuildArtifacts/Download.log
unzip -t CloudPayload/GoreBoxSource.zip > BuildArtifacts/ZipTest.txt
rm -rf CloudPayload/Unpacked
mkdir -p CloudPayload/Unpacked
unzip -q CloudPayload/GoreBoxSource.zip -d CloudPayload/Unpacked
# Find the Stage1 root regardless of whether the ZIP has a wrapping folder.
STAGE_ROOT=""
while IFS= read -r p; do
  candidate="$(dirname "$p")"
  if [ -f "$candidate/Tools/RecoverProject.sh" ] && [ -d "$candidate/SourceData" ]; then
    STAGE_ROOT="$candidate"
    break
  fi
done < <(find CloudPayload/Unpacked -type f -name codemagic.yaml 2>/dev/null)
if [ -z "$STAGE_ROOT" ]; then
  while IFS= read -r p; do
    candidate="$(dirname "$(dirname "$p")")"
    if [ -f "$candidate/Tools/RecoverProject.sh" ]; then
      STAGE_ROOT="$candidate"
      break
    fi
  done < <(find CloudPayload/Unpacked -type f -name ReassemblyManifest.json 2>/dev/null)
fi
if [ -z "$STAGE_ROOT" ]; then
  echo "Could not find Stage1 root in source archive." | tee BuildArtifacts/PrepareError.txt
  find CloudPayload/Unpacked -maxdepth 4 -type f | sort | head -300 > BuildArtifacts/ArchiveFileList.txt
  exit 11
fi
printf '%s\n' "$STAGE_ROOT" > BuildArtifacts/StageRoot.txt
rm -rf StageWorkspace
cp -R "$STAGE_ROOT" StageWorkspace
find StageWorkspace -maxdepth 3 -type f | sort > BuildArtifacts/StageWorkspaceFiles.txt
