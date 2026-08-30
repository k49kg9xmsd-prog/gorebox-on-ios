#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p RecoveredUnityProject/Assets/Editor
cp UnityOverlay/Assets/Editor/GoreBoxIOSBuild.cs RecoveredUnityProject/Assets/Editor/GoreBoxIOSBuild.cs
# Make sure ProjectSettings exists; AssetRipper normally generates it.
if [ ! -f RecoveredUnityProject/ProjectSettings/ProjectVersion.txt ]; then
  mkdir -p RecoveredUnityProject/ProjectSettings
  cat > RecoveredUnityProject/ProjectSettings/ProjectVersion.txt <<'EOF'
m_EditorVersion: 2021.3.28f1
m_EditorVersionWithRevision: 2021.3.28f1 (232e59c3f087)
EOF
fi
