#!/bin/bash
set -euo pipefail
mkdir -p BuildArtifacts
missing=0
for n in UNITY_EMAIL UNITY_PASSWORD UNITY_SERIAL; do
  if [ -z "${!n:-}" ]; then
    echo "$n is not set" | tee -a BuildArtifacts/UnityCredentialsMissing.txt
    missing=1
  fi
done
if [ "$missing" -ne 0 ]; then
  echo "Codemagic cloud Unity builds require a Unity Plus or Pro license." | tee -a BuildArtifacts/UnityCredentialsMissing.txt
  exit 40
fi
