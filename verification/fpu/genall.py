import struct, random, math
def f(x): return struct.unpack('<f', struct.pack('<I', x))[0]
def g(x):
    if math.isnan(x): return 0x7fc00000
    if math.isinf(x): return 0xff800000 if x<0 else 0x7f800000
    try: return struct.unpack('<I', struct.pack('<f', x))[0]
    except OverflowError: return 0xff800000 if x<0 else 0x7f800000
def is_zero(x): return (x>>23)&0xff==0 and (x&0x7fffff)==0
def is_inf(x): return (x>>23)&0xff==0xff and (x&0x7fffff)==0
def is_nan(x): return (x>>23)&0xff==0xff and (x&0x7fffff)!=0
def sgn(x): return (x>>31)&1

def do_op(a,b,op):
    if op==0: return g(f(a)+f(b))
    if op==1: return g(f(a)-f(b))
    if op==2: return g(f(a)*f(b))
    if op==3:
        # division
        if is_nan(a) or is_nan(b): return 0x7fc00000
        if is_inf(a) and is_inf(b): return 0x7fc00000  # inf/inf = nan
        if is_zero(a) and is_zero(b): return 0x7fc00000  # 0/0 = nan
        if is_zero(b):  # x/0, x!=0 -> inf with DZ
            return 0xff800000 if sgn(a)^sgn(b) else 0x7f800000
        return g(f(a)/f(b))
    if op==4:
        if is_nan(a): return 0x7fc00000
        if is_inf(a): return a
        if sgn(a) and not is_zero(a): return 0x7fc00000  # sqrt(neg) = nan
        if is_zero(a): return 0
        return g(math.sqrt(f(a)))

random.seed(123)
with open('vecs_all.txt','w') as fh:
    dv=[(0x40400000,0x3fc00000,0),(0x40400000,0x3fc00000,1),(0x3f800000,0x3f800000,0),
        (0xbf800000,0x3f800000,0),(0xc0000000,0x40000000,1),(0x40000000,0x40000000,2),
        (0xc0000000,0x40000000,2),(0x40400000,0x40000000,3),(0x3f800000,0x40000000,3),
        (0x40000000,0x40400000,4),(0x3f800000,0x3f800000,4),(0x41200000,0x41200000,4),
        (0x7f7fffff,0x7f7fffff,2),(0x7f7fffff,0x7f7fffff,0),(0xff7fffff,0xff7fffff,0),
        (0x00000000,0x40400000,3),(0x40400000,0x00000000,3),(0x40400000,0x00000000,4),
        (0x00000000,0x00000000,4),(0x7f800000,0x40400000,2),(0x40400000,0x7f800000,3),
        (0x7f800000,0x00000000,2),(0x40400000,0x40400000,3),(0x41200000,0x41200000,3),
        (0x4b7fffff,0x4b7fffff,2),(0x7f7fffff,0x7f7fffff,3),(0x3f800000,0x3f800000,2),
        (0xbf800000,0x00000000,4),(0x3f800000,0x00000000,3)]
    for a,b,op in dv: fh.write('%08x %08x %d %08x\n'%(a,b,op,do_op(a,b,op)))
    for _ in range(40000):
        a=random.randint(0,0xffffffff); b=random.randint(0,0xffffffff)
        ea=(a>>23)&0xff; eb=(b>>23)&0xff
        if ea==0 or ea==0xff: a=(a&0x80000000)|((0x7f+random.randint(-3,3)&0xff)<<23)|(a&0x7fffff)
        if eb==0 or eb==0xff: b=(b&0x80000000)|((0x7f+random.randint(-3,3)&0xff)<<23)|(b&0x7fffff)
        op=random.randint(0,4)
        fh.write('%08x %08x %d %08x\n'%(a,b,op,do_op(a,b,op)))
print('done')
