#!/usr/bin/env python3
from pathlib import Path
import sys
ROOT=Path(__file__).resolve().parents[1]
errors=[]
def check(c,m):
    if not c: errors.append(m)
logo=(ROOT/'assets/logo.raw').read_bytes(); font=(ROOT/'assets/font.raw').read_bytes(); mod=(ROOT/'assets/neon.mod').read_bytes()
check(len(logo)==4*320//8*64, f'logo size {len(logo)} != 10240 (four 2560 byte bitplanes)')
logo_planes=[logo[i*2560:(i+1)*2560] for i in range(4)]
logo_any=bytes(a|b|c|d for a,b,c,d in zip(*logo_planes)) if len(logo)==10240 else bytes(2560)
check(len(font)==95*8, f'font size {len(font)} != 760')
check(len(mod)>=1084,'MOD shorter than header')
if len(mod)>=1084:
    check(mod[1080:1084]==b'M.K.',f'bad MOD signature {mod[1080:1084]!r}')
    sl=mod[950]; check(1<=sl<=128,f'invalid song length {sl}')
    orders=mod[952:1080]
    pats=max(orders[:sl],default=0)+1
    sample_bytes=sum(int.from_bytes(mod[20+i*30+22:20+i*30+24],'big')*2 for i in range(31))
    expected=1084+pats*1024+sample_bytes
    check(len(mod)==expected,f'MOD size {len(mod)} != parsed {expected}')
    for i in range(31):
        o=20+i*30; ln=int.from_bytes(mod[o+22:o+24],'big'); vol=mod[o+25]
        ls=int.from_bytes(mod[o+26:o+28],'big'); ll=int.from_bytes(mod[o+28:o+30],'big')
        check(vol<=64,f'sample {i+1} volume {vol} > 64')
        if ln: check(ls+ll<=ln or ll<=1,f'sample {i+1} loop exceeds sample')
    # validate pattern sample numbers and periods
    for p in range(pats):
        base=1084+p*1024
        for e in range(256):
            b0,b1,b2,b3=mod[base+e*4:base+e*4+4]
            smp=(b0&0xf0)|(b2>>4); per=((b0&0xf)<<8)|b1
            check(smp<=31,f'pattern {p} event {e}: sample {smp}')
            check(per==0 or 113<=per<=856,f'pattern {p} event {e}: period {per}')
if errors:
    print('VALIDATION FAILED')
    for x in errors: print(' -',x)
    sys.exit(1)
print('VALIDATION OK')
print(f' logo={len(logo)} font={len(font)} mod={len(mod)} songlen={mod[950]} patterns={max(mod[952:952+mod[950]])+1}')

# Static 68000 source sanity checks. This intentionally targets mistakes that
# are easy to miss when the cross-assembler is not installed on the host.
import re

def split_operands(text):
    depth=0
    for i,ch in enumerate(text):
        if ch=='(': depth += 1
        elif ch==')': depth -= 1
        elif ch==',' and depth==0:
            return text[:i].strip(), text[i+1:].strip()
    return None

def is_reg(op):
    return re.fullmatch(r'[da][0-7]',op.lower().strip()) is not None

# Symbolic indexed displacements (AUD0VOL(a6,d7.w)) were invisible to a
# numeric-only check, although the 68000 brief extension word only holds -128..127.
# hardware.i is parsed first so the symbols can be evaluated.
hw_equ={}
for _ln in (ROOT/'src/hardware.i').read_text().splitlines():
    _m=re.match(r'\s*(\w+)\s+EQU\s+(-?\$?[0-9A-Fa-f]+)\s*(?:;.*)?$',_ln)
    if _m:
        _v=_m.group(2)
        hw_equ[_m.group(1)]=int(_v.replace('$','0x'),0) if '$' in _v else int(_v,0)
def eval_disp(txt):
    txt=txt.strip()
    try: return int(txt.replace('$','0x'),0)
    except ValueError: return hw_equ.get(txt)

for rel in ('src/main.s','src/modplayer.s'):
    lines=(ROOT/rel).read_text().splitlines()
    for n,line in enumerate(lines,1):
        code=line.split(';',1)[0].strip()
        for disp in re.findall(r'(?<![\w$])(-?[\w$]+)\([^)]*,\s*[da][0-7]\.[wl]\)',code,re.I):
            v=eval_disp(disp)
            if v is not None:
                check(-128 <= v <= 127,f'{rel}:{n}: indexed displacement {disp} = {v} exceeds the 68000 brief extension word: {code}')
        # PC-relative addressing cannot be a destination, and cannot reach another hunk.
        m=re.match(r'^[a-z]+(?:\.[a-z])?\s+(.+)$',code,re.I)
        if m:
            ops=split_operands(m.group(1))
            if ops and re.search(r'\(pc\)',ops[1],re.I):
                check(False,f'{rel}:{n}: PC-relative destination is not encodable: {code}')
            if ops and re.search(r'\(pc\)',ops[0],re.I) and not re.match(r'^(lea|pea|jsr|jmp)',code,re.I):
                check(False,f'{rel}:{n}: PC-relative data access: data lives in another hunk and is addressed absolutely: {code}')
        # ADDI/SUBI/ANDI/ORI/EORI/CMPI cannot take an address register.
        m=re.match(r'^(addi|subi|andi|ori|eori|cmpi)(?:\.[bwl])?\s+(.+)$',code,re.I)
        if m:
            ops=split_operands(m.group(2))
            if ops and re.fullmatch(r'a[0-7]',ops[1].lower()):
                check(False,f'{rel}:{n}: {m.group(1)} cannot target an address register (use adda/suba/lea): {code}')
        # ADDQ/SUBQ only take 1..8; quick shift counts only 1..8.
        m=re.match(r'^(addq|subq|lsl|lsr|asl|asr|rol|ror|roxl|roxr)(?:\.[bwl])?\s+#(\S+?),',code,re.I)
        if m:
            v=eval_disp(m.group(2))
            if v is not None:
                check(1 <= v <= 8,f'{rel}:{n}: immediate count {v} is outside 1..8; use a register or ADD/SUB: {code}')
        # DMACONR, INTENAR, ... are read-only mirrors of the write registers.
        if re.search(r',\s*(DMACONR|INTENAR|INTREQR|ADKCONR|VPOSR|VHPOSR)\(',code,re.I) and not re.match(r'^(btst|cmp|cmpi|tst)\b',code,re.I):
            check(False,f'{rel}:{n}: write to a read-only custom register: {code}')
        check('(pc)' not in code.lower() or re.match(r'^(lea|pea|jsr|jmp|bsr)',code,re.I) is not None,
              f'{rel}:{n}: unexpected PC-relative operand: {code}')


# Structural DMA-memory contract: Copper and all DMA payload labels must occur
# after the chipdata section declaration in the single source translation unit.
main_src=(ROOT/'src/main.s').read_text()
chip_pos=main_src.find('section chipdata,data_c')
check(chip_pos>=0,'missing chipdata,data_c section')
for label in ('copper:','screen:','logo_data:','font_data:','audio_silence:','mod_data:'):
    m=re.search(r'(?m)^\s*'+re.escape(label)+r'\s*',main_src)
    pos=m.start() if m else -1
    check(pos>chip_pos,f'{label[:-1]} is not placed in chipdata')

# Generated music may only use commands implemented by this compact replay.
supported_fx={0x0,0xC,0xF}
if len(mod)>=1084:
    sl=mod[950]; pats=max(mod[952:952+sl],default=0)+1
    for p in range(pats):
        base=1084+p*1024
        for e in range(256):
            b2=mod[base+e*4+2]; b3=mod[base+e*4+3]
            fx=b2&0x0f
            if fx or b3:
                check(fx in supported_fx,f'pattern {p} event {e}: unsupported effect {fx:X}{b3:02X}')
                if fx==0xF:
                    check(1<=b3<=31,f'pattern {p} event {e}: unsupported BPM/zero F{b3:02X}')

# --- 68000 encoding legality ------------------------------------------------
# VASM is the authority for encodings (make assembles the program); these rules
# only keep a few historically easy mistakes from coming back.
for rel in ('src/main.s','src/modplayer.s'):
    lines=(ROOT/rel).read_text().splitlines()
    for n,line in enumerate(lines,1):
        code=line.split(';',1)[0].strip()
        if not code: continue
        m=re.match(r'^([a-z]+)\.([a-z])\s+(.+)$',code,re.I)
        if m:
            op,suf=m.group(1).lower(),m.group(2).lower()
            if op in ('bsr','bra') or re.fullmatch(r'b(eq|ne|cs|cc|pl|mi|vs|vc|hi|ls|ge|lt|gt|le|hs|lo)',op):
                check(suf!='s',f'{rel}:{n}: {op}.{suf} short branch can overflow its displacement: {code}')

# --- symbol cross-reference -------------------------------------------------
# Substitutes for the link step: every label, EQU and local label referenced by
# the single translation unit must be defined, and globals must be unique.
SOURCES=['src/hardware.i','src/main.s','src/modplayer.s']
MNEMONICS=set("""movem move moveq movea lea pea jsr bsr jmp rts rte bra nop
 bne beq blt bgt ble bge bhi blo bls bhs bcc bcs bpl bmi bvc bvs tst clr cmpi cmp
 add addi addq adda sub subi subq suba and andi or ori eor eori not lsl lsr asl asr
 rol ror roxl roxr neg ext divs divu cmpa btst bset bchg bclr dbra dbf mulu muls swap tas link unlk exg section
 include incbin incsrc cnop even align org ds dc dcb dcd equ set xdef xref export
 import global macro endm rept endr if else endif space skip""".split())
REGISTERS=set(['d%d'%i for i in range(8)]+['a%d'%i for i in range(7)]+['sp','pc','fp','sr','ccr'])
EXPORTS={'xdef','xref','export','import','global'}
TOK=re.compile(r'\.?[A-Za-z_][A-Za-z0-9_]*')
NUM=re.compile(r'[$%][0-9A-Fa-f_x]+|\b\d+\b|(?<=[A-Za-z0-9_)\]])\.[wbls]\b')

def strip_code(line):
    out=[]; i=0; n=len(line)
    while i<n:
        c=line[i]
        if c in '"\'':
            q=line[i]; i+=1
            while i<n and line[i]!=q: i+=1
            i+=1; continue
        if c==';': break
        out.append(c); i+=1
    return ''.join(out)

globs={}; locs={rel:set() for rel in SOURCES}; equdefs={}; equvals={}; refs=[]
for rel in SOURCES:
    scope=None
    for n,raw in enumerate((ROOT/rel).read_text().splitlines(),1):
        code=strip_code(raw)
        if not code.strip(): continue
        m=re.match(r'\s*(\.?[A-Za-z_][A-Za-z0-9_]*)\s*:(.*)',code)
        if m:
            name,rest=m.group(1),m.group(2)
            if name.startswith('.'): locs[rel].add(name)
            else:
                check(name not in globs,f'{rel}:{n}: duplicate global label {name} (first at {globs.get(name)})')
                globs[name]=f'{rel}:{n}'; scope=name
        else:
            m=re.match(r'\s*([A-Za-z_][A-Za-z0-9_]*)\s+(?:EQU|equ|=)\s*(.*)$',code)
            if m:
                name,rest=m.group(1),m.group(2)
                check(name not in equdefs,f'{rel}:{n}: duplicate EQU {name} (first at {equdefs.get(name)})')
                equdefs[name]=f'{rel}:{n}'
                try: equvals[name]=int(re.sub(r'^\$',r'0x',rest.strip()),0)
                except ValueError: pass
                continue
            rest=code
        prev=''
        rest_toks=TOK.findall(NUM.sub(' ',rest))
        for idx,tok in enumerate(rest_toks):
            lo=tok.lower()
            if lo in MNEMONICS or lo in REGISTERS: prev=lo; continue
            if lo in EXPORTS:
                if idx+1<len(rest_toks): globs.setdefault(rest_toks[idx+1],f'{rel}:{n} (exported)')
                prev=lo; continue
            if prev in ('section','secattr'): prev='secattr' if prev=='section' else ''; continue
            if lo=='section': prev=lo; continue
            refs.append((rel,n,scope,tok,code.strip())); prev=lo
for rel,n,scope,tok,code in refs:
    if tok.startswith('.'):
        check(tok in locs[rel],f'{rel}:{n}: undefined local label {tok} in {scope}: {code}')
    else:
        check(tok in globs or tok in equdefs,f'{rel}:{n}: undefined symbol {tok} in {scope}: {code}')

# --- data_c payload is only ever reached through the relocation table -------
# A direct code reference to a chipdata label would bake in a link time address
# and survive the copy into chip RAM, so only the reloc table may name them.
chip_labels=['screen','logo_data','font_data','audio_silence','mod_data','copper','cop_bpl1','cop_raster_color','cop_wave','cop_bars','sprites','cop_spr']
for label in chip_labels:
    for n,line in enumerate(main_src.splitlines(),1):
        code=line.split(';',1)[0]
        if not re.search(r'(?<![\w$])'+re.escape(label)+r'(?![\w$])',code): continue
        ok=re.match(r'\s*'+re.escape(label)+r':',code) or code.strip().startswith('dc.l ')
        check(bool(ok),f'main.s:{n}: chipdata label {label} used outside its definition/reloc table: {code.strip()}')

# --- Copper list structure --------------------------------------------------
# WAIT is a two word register pair: the first word is the position with bit 0
# set, the second is the mask with bit 0 clear and bit 15 set for BFD.
def label_pos(label):
    label=label.rstrip(':')
    m=re.search(r'(?m)^\s*'+re.escape(label)+r':',main_src)
    return m.start() if m else -1
def body_of(label):
    start=label_pos(label)
    if start<0: return ''
    rest=main_src[re.search(r'(?m)^\s*'+re.escape(label)+r':',main_src).end():]
    nxt=re.search(r'(?m)^[A-Za-z_][A-Za-z0-9_]*\s*:',rest)
    return rest[:nxt.start()] if nxt else rest
cop_lo=label_pos('copper:'); cop_hi=label_pos('screen:')
check(0<=cop_lo<cop_hi,'cannot locate copper: .. screen: in the chipdata section')
cop_src=main_src[cop_lo:cop_hi] if 0<=cop_lo<cop_hi else ''
cop_words=[]
for m in re.finditer(r'(?m)^\s*dc\.w\s+([^\n;]*)',cop_src):
    for item in m.group(1).split(','):
        item=item.strip()
        if not item: continue
        val=equvals.get(item)
        if val is None:
            try: val=int(re.sub(r'^\$',r'0x',item),0)
            except ValueError: val=None
        if val is not None: cop_words.append(val)
check(len(cop_words)>=2 and cop_words[-2:]==[0xFFFF,0xFFFE],f'Copper list does not end with $FFFF,$FFFE: {cop_words[-4:]}')
check(len(cop_words)%2==0,f'Copper list has an odd number of words ({len(cop_words)})')
for i in range(0,len(cop_words)-1,2):
    reg,val=cop_words[i],cop_words[i+1]
    if reg&1:                                         # WAIT/SKIP: first word has bit 0 set
        check(val&1==0,f'Copper WAIT ${reg:04X} mask word ${val:04X} must have bit 0 clear')
    else:                                             # MOVE reg, value (a value of $FFFE is legal)
        check(0<=val<=0xFFFF,f'Copper MOVE to ${reg:04X} has out of range value {val}')
        check(reg>=0x20 and reg<=0x1FE,f'Copper MOVE to ${reg:04X} is outside the custom register range')
for reg,val in ((0x08E,0x2C81),(0x090,0x2CC1),(0x092,0x0030),(0x094,0x00D0),(0x100,0x4200),(0x108,0xFFFE),(0x10A,0xFFFE)):
    pairs=[(cop_words[i],cop_words[i+1]) for i in range(0,len(cop_words)-1,2)]
    check((reg,val) in pairs,f'Copper list missing standard value ${reg:03X}=${val:04X}')
check(any(cop_words[i]==0x180 for i in range(0,len(cop_words),2)),'Copper list never sets COLOR00')
# UpdateRaster writes 2(a1) through ptr_raster, so the slot has to be a
# COLOR00 MOVE pair: register word at +0, animated colour data word at +2.
slot_m=re.search(r'(?m)^\s*cop_raster_color:',main_src)
slot=main_src[slot_m.end():slot_m.end()+48] if slot_m else ''
check(re.match(r'\s*dc\.w\s+COLOR00\s*,\s*\$[0-9A-Fa-f]{1,4}',slot) is not None,
      f'cop_raster_color is not a COLOR00 MOVE pair: {slot.strip().splitlines()[0] if slot.strip() else "missing"}')

# --- bitmap pointer patching -----------------------------------------------
# From cop_bpl1 the list is BPLnPTH/BPLnPTL MOVE pairs, so the register words sit
# at byte offsets 0/4/8/12/16/20 and the data words PatchCopper may overwrite at
# 2/6, 10/14 and 18/22. Patching the register words would corrupt the list, and
# skipping the pairs would leave the bitplanes pointing at the link time block.
bpl_lo=label_pos('cop_bpl1:'); col=main_src.find('COLOR00',bpl_lo)
bpl_regs=[equvals.get(t) for t in re.findall(r'BPL\dPT[HL]',main_src[bpl_lo:col])]
check(bpl_regs==[0x0E0,0x0E2,0x0E4,0x0E6,0x0E8,0x0EA,0x0EC,0x0EE],
      f'cop_bpl1 does not start with the BPL1..4 pointer pairs: {bpl_regs}')
data_offs=[2*(2*k+1) for k in range(4*2)]
reg_offs=[2*(2*k) for k in range(4*2)]
patch=body_of('PatchCopper')
for off in data_offs:
    check(re.search(r'(?<![\d$])%d\(a1\)'%off,patch) is not None,f'PatchCopper does not patch data offset {off}(a1)')
for off in reg_offs:
    check(re.search(r'(?<![\d$])%d\(a1\)'%off,patch) is None,f'PatchCopper overwrites register word {off}(a1)')
check('COP1LCH' in main_src and 'COPJMP1' in main_src,'COP1LCH/COPJMP1 restart missing')

# UpdateStars loops over every star with the two plane bases held in a0/a1, so it must
# address a star's byte with an indexed operand and never modify the bases: adding an
# offset into a0/a1 would walk them off the end of the bitplane.
us=body_of('UpdateStars')
check(re.search(r'(adda|suba|addq|subq|addi|subi|lea\s+[^,]*),?[^;\n]*\b(a0|a1)\s*$',
                '\n'.join(l.split(';')[0] for l in us.splitlines() if re.search(r'\b(adda|suba)\b',l))) is None
      and re.search(r'(?m)^\s*(adda|suba)[^\n]*,\s*a[01]\b',us) is None,
      'UpdateStars modifies a plane base (a0/a1), which it reuses for every star')
check(re.search(r'0\(a0,d\d\.w\)',us) is not None and re.search(r'0\(a1,d\d\.w\)',us) is not None,
      'UpdateStars no longer addresses star bytes with indexed operands on both plane bases')
code_lo=re.search(r'(?m)^\s*section\s+code\b',main_src)
code_hi=re.search(r'(?m)^\s*section\s+data\b',main_src)
check(code_lo is not None and code_hi is not None,'main.s has no code/data section pair')
if code_lo and code_hi:
    code_src=main_src[code_lo.start():code_hi.start()]
    for sub in re.findall(r'(?m)^([A-Za-z_][A-Za-z0-9_]*):',code_src):
        body=body_of(sub)
        if body.strip() and not re.search(r'(?m)^\s*rts',body):
            check(False,f'{sub} is a code section label with no rts')

# --- interrupt and DMA ordering --------------------------------------------
def order_ok(text,first,second):
    i=text.find(first); j=text.find(second)
    return i>=0 and j>=0 and i<j
startup=body_of('_start')
check(order_ok(startup,'LVO_Forbid','LVO_Disable'),'startup must Forbid before Disable (Disable yields CPU and can be preempted)')
check(startup.find('4.w')>=0 and startup.find('4.w')<startup.find('jsr'),'ExecBase must be loaded from 4.w before any jsr')
teardown=startup[startup.find('MOD_Stop'):]
check(order_ok(teardown,'LVO_Enable','LVO_Permit'),'teardown must Enable before Permit')
check(order_ok(teardown,'MOD_Stop','LoadView'),'teardown must stop Paula before the View is restored')
check(re.search(r'#\$7FFF,INTENA',main_src) and re.search(r'#\$7FFF,INTREQ',main_src),'INTENA/INTREQ are not masked before custom DMA starts')
check(equvals.get('DMAF_ALL')==0x07FF,f'DMAF_ALL ${equvals.get("DMAF_ALL",0):04X} should be $07FF')
check(equvals.get('DMAF_AUDIO')==0x000F and equvals.get('DMAF_COPPER')==0x0080 and equvals.get('DMAF_RASTER')==0x0100
      and equvals.get('DMAF_MASTER')==0x0200 and equvals.get('DMAF_BLITTER')==0x0040 and equvals.get('DMAF_DISK')==0x0010
      and equvals.get('DMAF_SPRITE')==0x0020 and equvals.get('DMAF_BLITHOG')==0x0400 and equvals.get('DMAF_SYSTEM')==0x07F0,
      'DMAF bit assignments are wrong for OCS/ECS (hardware/dmabits.h)')
check(equvals.get('MEMF_CHIP')==0x0002 and equvals.get('MEMF_ANY')==0x8000,'MEMF constants are wrong')
check(equvals.get('LVO_LoadView')==-222 and equvals.get('LVO_WaitTOF')==-270 and equvals.get('LVO_OwnBlitter')==-456
      and equvals.get('LVO_DisownBlitter')==-462 and equvals.get('LVO_AllocMem')==-198 and equvals.get('LVO_TypeOfMem')==-534,
      'graphics/Exec library offsets are wrong')
check(equvals.get('GfxBase_ActiView')==34 and equvals.get('GfxBase_copinit')==38,'GfxBase offsets are wrong')
# The allocator's return value cannot be trusted blindly: without TypeOfMem the
# demo would hand fast RAM to the Copper, the bitplanes and Paula DMA.
_alloc=body_of('AllocChipMem')
check('LVO_TypeOfMem' in _alloc and 'MEMF_CHIP' in _alloc,
      'AllocChipMem must verify MEMF_CHIP with TypeOfMem before using the block for DMA')
check(re.search(r'LVO_TypeOfMem\(a6\)',_alloc) is not None
      and _alloc.find('LVO_TypeOfMem')<_alloc.find('LVO_CopyMem'),
      'the chip memory check must happen before the payload is copied')
check(re.search(r'jsr\s+LVO_FreeMem',_alloc) is not None,
      'a non-chip allocation must be released with FreeMem rather than leaked')
check(equvals.get('SILENCE_WORD')==0x8080,'SILENCE_WORD must be $8080 (unsigned 8 bit silence)')


# The library base must be in a6 (AmigaOS calling convention). Kickstart's Exec never reads
# it, which hides a wrong base register; AROS's Exec does and crashes.
for _n,_l in enumerate(main_src.splitlines(),1):
    _c=_l.split(';')[0]
    _m=re.match(r'\s*jsr\s+LVO_\w+\((a[0-7])\)',_c)
    if _m: check(_m.group(1)=='a6',f'main.s:{_n}: library call with the base in {_m.group(1)}; the convention is a6: {_c.strip()}')

# --- Exec register calling convention ---------------------------------------
# AmigaOS passes arguments in register order, and the register class is decided
# by the argument type: a pointer goes in the next available a-register, anything
# else in the next d-register. ExecBase/GfxBase travel in the jsr operand and do
# not consume a slot. Passing a pointer in d0 (or a length in a0) silently calls
# the function with garbage, so the class of each argument is checked here.
LVO_ARGS={
    'LVO_OpenLibrary'   :['a1','d0'],   # OpenLibrary(libName=a1, version=d0)
    'LVO_CloseLibrary'  :['a1'],        # CloseLibrary(library=a1)
    'LVO_LoadView'      :['a1'],        # LoadView(view=a1)
    'LVO_AllocMem'      :['d0','d1'],   # AllocMem(byteSize=d0, requirements=d1)
    'LVO_FreeMem'       :['a1','d0'],   # FreeMem(memoryBlock=a1, byteSize=d0)
    'LVO_TypeOfMem'     :['a1'],        # TypeOfMem(address=a1)
    'LVO_CopyMem'       :['a0','a1','d0'],  # CopyMem(source=a0, dest=a1, size=d0)
    'LVO_Forbid'        :[], 'LVO_Permit':[], 'LVO_Enable':[], 'LVO_Disable':[],
    'LVO_WaitTOF'       :[], 'LVO_OwnBlitter':[], 'LVO_WaitBlit':[],
    'LVO_DisownBlitter' :[],
}
# An argument register counts as loaded if one of these set it in the lines
# immediately preceding the jsr. The window is deliberately small so scratch
# registers used by unrelated code cannot be mistaken for arguments.
ARG_WRITE=re.compile(r'^\s*(?:move[alq]?\.?[lwqb]?|movea[wl]?|lea|sub\.l|clr\.[lw]?|moveq)\s+[^,]*,\s*([ad][0-7])\b')
WINDOW=5
def arg_windows(src):
    """Yield (callee, base, registers written in the WINDOW lines before the jsr)."""
    lines=src.splitlines()
    for i,ln in enumerate(lines):
        code=ln.split(';')[0]
        m=re.match(r'\s*(?:jsr|jmp)\s+(LVO_\w+)\(([ad][0-7])\)',code)
        if not m: continue
        regs=set()
        # Stop at the previous call: library calls clobber d0/d1/a0/a1, so an argument
        # register set before it is not an argument of this one.
        for prev in reversed(lines[max(0,i-WINDOW):i]):
            if re.match(r'\s*(?:jsr|bsr|jmp)\b',prev): break
            regs.update(ARG_WRITE.findall(prev.split(';')[0]))
        yield m.group(1),m.group(2),regs
_calls=list(arg_windows(main_src))
check(len(_calls)>=14,f'calling-convention scan found only {len(_calls)} library calls; the jsr pattern is broken')
for callee,base,regs in _calls:
    if callee not in LVO_ARGS:
        errors.append(f'unknown library call {callee}: no argument convention recorded')
        continue
    want=LVO_ARGS[callee]
    for n,slot in enumerate(want,1):
        if slot not in regs:
            errors.append(f'{callee} expects {slot} to hold argument {n} but it is not set before the jsr')
    # The classic mistake is loading an argument into the wrong register class
    # (a pointer in a d-register or a length in an a-register). Flag an argument
    # that was written in the window but none of the expected slots.
    if want and not any(s in regs for s in want):
        touched=sorted(r for r in regs if r not in ('a5','a6'))
        if touched:
            errors.append(f'{callee} arguments are in the wrong registers: set {",".join(touched)} but expected {",".join(want)}')
check(equvals.get('LVO_CopyMem')==-624 and equvals.get('LVO_FreeMem')==-210 and equvals.get('LVO_CloseLibrary')==-414
      and equvals.get('LVO_Forbid')==-132 and equvals.get('LVO_Permit')==-138 and equvals.get('LVO_Enable')==-126
      and equvals.get('LVO_Disable')==-120 and equvals.get('LVO_OpenLibrary')==-552,
      'Exec LVO offsets for memory/copy/scheduling calls are wrong')

# --- audio sample sanity ----------------------------------------------------
# Paula plays 8 bit samples as unsigned, so a correct waveform is centred on
# 128. Masking a signed wave with &255 pins it near full scale and clicks on
# every loop point, and a hat that never decays never sounds like a hat.
import math
def rms(d): return math.sqrt(sum((v-128)**2 for v in d)/len(d)) if d else 0.0
if len(mod)>=1084:
    off=1084+pats*1024
    for i in range(31):
        o=20+i*30; name=mod[o:o+22].split(b'\0')[0].decode('latin-1').strip()
        ln=int.from_bytes(mod[o+22:o+24],'big')*2; ls=int.from_bytes(mod[o+26:o+28],'big')*2
        if not ln: continue
        d=mod[off+ls:off+ls+ln]
        check(len(d)==ln,f'sample {i+1} {name!r}: data truncated at {len(d)} of {ln} bytes')
        if not d: continue
        mean=sum(d)/len(d)
        check(96<=mean<=160,f'sample {i+1} {name!r}: mean {mean:.1f} is not centred on 128 (signed data written raw?)')
        if name in ('LEAD','KICK'):
            step=max(abs(d[j]-d[j-1]) for j in range(1,len(d)))
            check(step<=64,f'sample {i+1} {name!r}: {step} sample step suggests a DC jump')
        if name=='HAT':
            q=len(d)//4
            check(rms(d[-q:])<=0.6*rms(d[:q]),f'sample HAT does not decay (rms {rms(d[:q]):.1f} -> {rms(d[-q:]):.1f})')
        off+=ln

# --- logo geometry ----------------------------------------------------------
# A logo wider than 320 pixels is clipped on both sides, which is invisible in
# the raw file but obvious on screen.
logo_cols=[x for x in range(320) if any(logo_any[y*40+(x>>3)]>>(7-(x&7))&1 for y in range(64))]
check(bool(logo_cols),'logo is empty')
if logo_cols:
    check(min(logo_cols)>=1 and max(logo_cols)<=318,
          f'logo ink spans x={min(logo_cols)}..{max(logo_cols)}, too wide for a 320 pixel screen')
    rows=[y for y in range(64) if any(logo_any[y*40+x] for x in range(40))]
    check(min(rows)>=1 and max(rows)<=62,f'logo ink spans y={min(rows)}..{max(rows)}, outside the 64 pixel band')
    for ch in (32,33,65,77,86):
        cell=font[ch*8:ch*8+8]
        check(any(cell),f'font glyph {ch} is blank')

if errors:
    print('STATIC SOURCE VALIDATION FAILED')
    for x in errors: print(' -',x)
    sys.exit(1)
print('68000 SOURCE SANITY OK')
print(f' symbols={len(globs)} equ={len(equvals)} locals={sum(len(v) for v in locs.values())} copper_words={len(cop_words)}')
