import struct, random, math

def f(x): return struct.unpack('<f', struct.pack('<I', x))[0]
def is_zero(x): return (x>>23)&0xff==0 and (x&0x7fffff)==0
def is_inf(x): return (x>>23)&0xff==0xff and (x&0x7fffff)==0
def is_nan(x): return (x>>23)&0xff==0xff and (x&0x7fffff)!=0
def sgn(x): return (x>>31)&1

def to_single(x, rm):
    if math.isnan(x): return 0x7fc00000
    if math.isinf(x): return 0xff800000 if x<0 else 0x7f800000
    if x==0.0:
        return 0x80000000 if math.copysign(1.0,x)<0 else 0
    db = struct.unpack('<Q', struct.pack('<d', x))[0]
    s=(db>>63)&1; exp=(db>>52)&0x7ff; mant=db&0xfffffffffffff
    if exp==0: mant=0
    else: mant|=1<<52
    ue = exp-1023
    es = ue+127
    sh = 29
    dropped = mant & ((1<<sh)-1)
    m24 = mant >> sh
    g=(dropped>>(sh-1))&1
    r=(dropped>>(sh-2))&1
    s_bit = 1 if (dropped & ((1<<(sh-2))-1)) else 0
    lsb=m24&1
    ru=False
    if rm==0: ru=bool(g&(r|s_bit|lsb))
    elif rm==1: ru=False
    elif rm==2: ru=bool(s and (g|r|s_bit))
    elif rm==3: ru=bool((not s) and (g|r|s_bit))
    elif rm==4: ru=bool(g)
    if ru: m24+=1
    if m24>>24:
        m24>>=1; es+=1
    if es>=255:
        if rm in (0,4): return (s<<31)|(0xff<<23)|0
        if rm==1: return (s<<31)|(0xfe<<23)|0x7fffff
        if rm==2: return (s<<31)|(0xff<<23)|0 if s else (s<<31)|(0xfe<<23)|0x7fffff
        if rm==3: return (s<<31)|(0xfe<<23)|0x7fffff if s else (s<<31)|(0xff<<23)|0
    if es<=0:
        sh2=1-es
        if sh2>=24: m24=0
        else: m24>>=sh2
        es=0
    return (s<<31)|((es&0xff)<<23)|(m24&0x7fffff)

def do_op(a,b,op,rm):
    if op==0: return to_single(f(a)+f(b),rm)
    if op==1: return to_single(f(a)-f(b),rm)
    if op==2: return to_single(f(a)*f(b),rm)
    if op==3:
        if is_nan(a) or is_nan(b): return 0x7fc00000
        if is_inf(a) and is_inf(b): return 0x7fc00000
        if is_zero(a) and is_zero(b): return 0x7fc00000
        if is_zero(b): return 0xff800000 if sgn(a)^sgn(b) else 0x7f800000
        return to_single(f(a)/f(b),rm)
    if op==4:
        if is_nan(a): return 0x7fc00000
        if is_inf(a): return a
        if sgn(a) and not is_zero(a): return 0x7fc00000
        if is_zero(a): return 0
        return to_single(math.sqrt(f(a)),rm)

random.seed(99)
with open('vecs_rm_all.txt','w') as fh:
    for a,b,op,rm in [
        (0x40000000,0x40000000,0,0),(0x40000000,0x40000000,0,1),
        (0x3f800001,0x3f800001,0,0),(0x3f800001,0x3f800001,0,3),
        (0x40000000,0x40000000,2,0),(0x40000000,0x40000000,2,4),
        (0x3f800000,0x40000000,3,0),(0x3f800000,0x40000000,3,1),
        (0x40000000,0x40400000,4,0),(0x40000000,0x40400000,4,2),
        (0x7f7fffff,0x7f7fffff,2,0),(0x7f7fffff,0x7f7fffff,2,1),
        (0x00800000,0x3f800000,3,0),(0x00800000,0x3f800000,3,2),
        (0x00800000,0x3f800000,4,0),
    ]:
        fh.write('%08x %08x %d %d %08x\n'%(a,b,op,rm,do_op(a,b,op,rm)))
    for _ in range(20000):
        a=random.randint(0,0xffffffff); b=random.randint(0,0xffffffff)
        ea=(a>>23)&0xff; eb=(b>>23)&0xff
        if ea==0 or ea==0xff: a=(a&0x80000000)|((0x7f+random.randint(-3,3)&0xff)<<23)|(a&0x7fffff)
        if eb==0 or eb==0xff: b=(b&0x80000000)|((0x7f+random.randint(-3,3)&0xff)<<23)|(b&0x7fffff)
        op=random.randint(0,4); rm=random.randint(0,4)
        fh.write('%08x %08x %d %d %08x\n'%(a,b,op,rm,do_op(a,b,op,rm)))
print('done')
