import re,sys,subprocess,struct
valid=open('valid.txt').read()
ent={}
for h in (0,1):
    for l in open(f'out{h}.txt',errors='replace'):
        m=re.match(r'^([0-9A-F]{5}) (\d+) (.*?)\s*$',l)
        if not m: continue
        a=int(m[1],16); op=h*32768+(a-0x10000)//10
        ent[op]=(a,int(m[2]),m[3])
print('entries',len(ent))
mis=[]
for op in range(65536):
    a,n,t=ent[op]
    mine= not t.startswith('DC.W')
    if mine!=(valid[op]=='1'): mis.append((op,t))
print('validity mismatches',len(mis))
for op,t in mis[:60]: print(f'{op:04X} musashi={valid[op]} {t}')
# assemble
ext=[int(x,16) for x in open('ext.txt').read().split(',')] if False else None
for h in (0,1):
    lines=[]; idx=[]
    for op in range(h*32768,(h+1)*32768):
        a,n,t=ent[op]
        if t.startswith('DC.W'): continue
        lines.append(f' org ${a:X}\n {t}\n'); idx.append(op)
    open(f'ra{h}.asm','w').write(''.join(lines))
bad=0; ok=0
for h in (0,1):
    ra=open(f'ra{h}.bin','rb').read(); sl=open(f'slots{h}.bin','rb').read()
    base=None
    for op in range(h*32768,(h+1)*32768):
        a,n,t=ent[op]
        if t.startswith('DC.W'): continue
        if base is None: base=a
        got=ra[a-base:a-base+n]; exp=sl[(a-0x10000):(a-0x10000)+n]
        if got!=exp:
            bad+=1
            if bad<=40: print(f'{op:04X} {t:30s} exp {exp.hex()} got {got.hex()}')
        else: ok+=1
print('roundtrip ok',ok,'bad',bad)
