import struct, random
def f(x): return struct.unpack('<f', struct.pack('<I', x))[0]
def g(x): return struct.unpack('<I', struct.pack('<f', x))[0]

def round_single(av, bv, sub, rm):
    # exact result in double (single inputs exact in double)
    rv = (av - bv) if sub else (av + bv)
    # get double bits
    db = struct.unpack('<Q', struct.pack('<d', rv))[0]
    sgn = (db>>63)&1; de=(db>>52)&0x7ff; dm=db&((1<<52)-1)
    if de==0x7ff:  # inf/nan
        if dm==0: return (0xff800000|0) if sgn else 0x7f800000
        return 0x7fc00000
    if de==0 and dm==0: return 0
    se = de-1023+127
    # fraction bits: top 23 of dm, with implicit
    frac23 = (dm>>29)&0x7fffff
    g_bit = (dm>>28)&1; r_bit=(dm>>27)&1; st = 1 if (dm & ((1<<27)-1)) else 0
    lsb = frac23 & 1
    if se <= 0:
        # flush subnormal to zero (matches DUT treat-as-zero)
        return 0
    if se >= 255:
        # overflow
        if rm==0 or rm==4:  # RNE/RMM -> inf
            return (0xff800000) if sgn else 0x7f800000
        if rm==1:  # RTZ -> max normal
            return (0xff7fffff) if sgn else 0x7f7fffff
        if rm==2:  # RDN toward -inf
            return (0xff800000) if sgn else 0x7f7fffff
        if rm==3:  # RUP toward +inf
            return (0xff7fffff) if sgn else 0x7f800000
    # rounding decision
    up=False
    if rm==0: up = g_bit and (r_bit or st or lsb)
    elif rm==1: up=False
    elif rm==2: up = sgn and (g_bit or r_bit or st)
    elif rm==3: up = (not sgn) and (g_bit or r_bit or st)
    elif rm==4: up = g_bit
    frac = frac23
    e = se
    if up:
        frac += 1
        if frac >> 23:
            frac = frac & 0x7fffff
            e += 1
            if e >= 255:
                return (0xff800000) if sgn else 0x7f800000
    return (sgn<<31)|(e<<23)|(frac&0x7fffff)

random.seed(7)
rms=[0,1,2,3,4]
with open('vecs_rm.txt','w') as fh:
    # directed
    dirv=[(0x40400000,0x3fc00000,0),(0x40400000,0x3fc00000,1),(0x3f800000,0x3f800000,0),
          (0xbf800000,0x3f800000,0),(0xc0000000,0x40000000,1),(0x43e5ed24,0xc349b2ef,1),
          (0x7f7fffff,0x7f7fffff,0),(0xff7fffff,0xff7fffff,0),(0x3f000001,0x80000001,0)]
    for rm in rms:
        for a,b,sub in dirv:
            r=round_single(f(a),f(b),sub,rm)
            fh.write('%08x %08x %d %d %08x\n'%(a,b,sub,rm,r))
    for _ in range(20000):
        a=random.randint(0,0xffffffff); b=random.randint(0,0xffffffff)
        ea=(a>>23)&0xff; eb=(b>>23)&0xff
        if ea==0xff or ea==0 or eb==0xff or eb==0:
            a=(a&0x80000000)|(0x7f<<23)|(a&0x7fffff); b=(b&0x80000000)|(0x7f<<23)|(b&0x7fffff)
        sub=random.randint(0,1)
        for rm in rms:
            r=round_single(f(a),f(b),sub,rm)
            fh.write('%08x %08x %d %d %08x\n'%(a,b,sub,rm,r))
print('done')
