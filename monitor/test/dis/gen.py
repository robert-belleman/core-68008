import struct,sys
ext=[int(x,16) for x in sys.argv[1].split(',')]
for half in (0,1):
    with open(f'slots{half}.bin','wb') as f:
        for op in range(half*32768,(half+1)*32768):
            f.write(struct.pack('>5H',op,*ext))
