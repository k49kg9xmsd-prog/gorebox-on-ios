from pathlib import Path
import hashlib, json, shutil
root=Path(__file__).resolve().parents[1]
manifest=json.loads((root/'SourceData/ReassemblyManifest.json').read_text(encoding='utf-8'))
chunkdir=root/'SourceData/Chunks'
for item in manifest:
    out=root/item['output']
    if item['parts'] is None:
        if not out.exists():
            raise SystemExit(f'Missing required visible source file: {out.relative_to(root)}')
        data=out.read_bytes()
        if len(data)!=item['size'] or hashlib.sha256(data).hexdigest()!=item['sha256']:
            raise SystemExit(f'Bad source file: {out.relative_to(root)}')
        print('verified',out.relative_to(root),len(data))
        continue
    out.parent.mkdir(parents=True,exist_ok=True)
    h=hashlib.sha256(); total=0
    with out.open('wb') as w:
        for part in item['parts']:
            p=chunkdir/part['name']
            if not p.exists(): raise SystemExit(f'Missing chunk: {p.relative_to(root)}')
            b=p.read_bytes()
            if len(b)!=part['size'] or hashlib.sha256(b).hexdigest()!=part['sha256']:
                raise SystemExit(f'Bad chunk: {p.relative_to(root)}')
            w.write(b); h.update(b); total+=len(b)
    if total!=item['size'] or h.hexdigest()!=item['sha256']:
        raise SystemExit(f'Reassembled hash mismatch: {out.relative_to(root)}')
    print('rebuilt',out.relative_to(root),total)
print('SOURCE_REASSEMBLY_OK')
