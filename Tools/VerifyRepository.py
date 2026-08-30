from pathlib import Path
import json, sys
root=Path(__file__).resolve().parents[1]
required=[
 'codemagic.yaml','Tools/ReassembleSource.py','Tools/RecoverProject.sh','Tools/PatchRecoveredProject.py',
 'PortOverlay/Assets/GoreBoxIOSPort/Editor/GoreBoxIOSPortSetup.cs',
 'PortOverlay/Assets/GoreBoxIOSPort/Runtime/IOSPortBootstrap.cs',
 'SourceData/ReassemblyManifest.json'
]
missing=[p for p in required if not (root/p).exists()]
chunks=list((root/'SourceData/Chunks').glob('*'))
if not chunks: missing.append('SourceData/Chunks/*')
if missing:
    print('MISSING_FILES:')
    for p in missing: print(' -',p)
    sys.exit(2)
print('REPOSITORY_OK')
print('Chunk files:',len(chunks))
