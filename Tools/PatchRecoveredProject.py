from pathlib import Path
import json, os, shutil
root=Path(__file__).resolve().parents[1]
p=root/'RecoveredUnityProject'
# Remove obvious Android-native binaries if AssetRipper copied them into Assets.
patterns=('libRF_CNative_andr','RFLib_DotNet_2018_andr','libil2cpp.so','libunity.so','libmain.so')
removed=[]
for f in list((p/'Assets').rglob('*')) if (p/'Assets').exists() else []:
    if f.is_file() and any(x.lower() in f.name.lower() for x in patterns):
        removed.append(str(f.relative_to(p)))
        f.unlink(missing_ok=True)
# Search recovered scenes and make a small report.
scenes=[]
for f in (p/'Assets').rglob('*.unity') if (p/'Assets').exists() else []:
    scenes.append(str(f.relative_to(p)))
report={'removed_android_native':removed,'scene_count':len(scenes),'scenes':sorted(scenes)}
(root/'BuildArtifacts').mkdir(exist_ok=True)
(root/'BuildArtifacts'/'Stage1Report.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
print('Scenes recovered:',len(scenes))
for s in scenes[:30]: print(' ',s)
