; ---------------------------------------------------------------------------
; NEON VECTORS - OCS/ECS custom register offsets and AmigaOS library offsets.
;
; Every constant below is a documented hardware register offset or a Kickstart
; library vector offset (LVO). Library call sites use the LVO_* names instead of
; raw negative displacements so a transposed call cannot be written by accident.
;
; Register conventions used by the call sites (from the Exec/graphics autodocs):
;   OpenLibrary(a1=name, d0=version)      CloseLibrary(a1=library)
;   AllocMem(d0=size, d1=flags)           FreeMem(a1=block, d0=size)
;   TypeOfMem(a1=address)                 CopyMem(a0=source, a1=dest, d0=size)
;   LoadView(a1=view)                     the library base is ALWAYS in a6
; ---------------------------------------------------------------------------

CUSTOM      EQU $DFF000

DMACONR     EQU $002       ; read: active DMA, write: same bits as DMACON (CLR)
VPOSR       EQU $004       ; bit15 LOF, bit0 V8
VHPOSR      EQU $006       ; bits15-8 V7..V0, bits7-0 H8..H1
ADKCONR     EQU $010
INTENAR     EQU $01C
INTREQR     EQU $01E
COP1LCH     EQU $080
COP1LCL     EQU $082
COPJMP1     EQU $088
COPJMP2     EQU $08A
DIWSTRT     EQU $08E
DIWSTOP     EQU $090
DDFSTRT     EQU $092
DDFSTOP     EQU $094
DMACON      EQU $096
INTENA      EQU $09A
INTREQ      EQU $09C
ADKCON      EQU $09E
; Blitter (line mode and D-only clear are used). BLTSIZE starts the blit and is written last.
BLTCON0     EQU $040
BLTCON1     EQU $042
BLTAFWM     EQU $044
BLTALWM     EQU $046
BLTCPTH     EQU $048
BLTBPTH     EQU $04C
BLTAPTH     EQU $050
BLTDPTH     EQU $054
BLTSIZE     EQU $058
BLTCMOD     EQU $060
BLTBMOD     EQU $062
BLTAMOD     EQU $064
BLTDMOD     EQU $066
BLTBDAT     EQU $072
BLTADAT     EQU $074
AUD0LCH     EQU $0A0
AUD0LEN     EQU $0A4       ; the four Paula channels are 16 bytes apart
AUD0PER     EQU $0A6
AUD0VOL     EQU $0A8
AUD1LCH     EQU $0B0
AUD2LCH     EQU $0C0
AUD3LCH     EQU $0D0
BPL1PTH     EQU $0E0
BPL1PTL     EQU $0E2
BPL2PTH     EQU $0E4
BPL2PTL     EQU $0E6
BPL3PTH     EQU $0E8
BPL3PTL     EQU $0EA
BPL4PTH     EQU $0EC
BPL4PTL     EQU $0EE
BPL5PTH     EQU $0F0
BPL5PTL     EQU $0F2
BPL6PTH     EQU $0F4
BPL6PTL     EQU $0F6
BPLCON0     EQU $100
BPLCON1     EQU $102
BPLCON2     EQU $104
BPL1MOD     EQU $108
BPL2MOD     EQU $10A
SPR0PTH     EQU $120
SPR0PTL     EQU $122
SPR1PTH     EQU $124
SPR1PTL     EQU $126
SPR2PTH     EQU $128
SPR2PTL     EQU $12A
SPR3PTH     EQU $12C
SPR3PTL     EQU $12E
SPR4PTH     EQU $130
SPR4PTL     EQU $132
SPR5PTH     EQU $134
SPR5PTL     EQU $136
SPR6PTH     EQU $138
SPR6PTL     EQU $13A
SPR7PTH     EQU $13C
SPR7PTL     EQU $13E
COLOR00     EQU $180
COLOR01     EQU $182
COLOR02     EQU $184
COLOR03     EQU $186
COLOR04     EQU $188
COLOR05     EQU $18A
COLOR06     EQU $18C
COLOR07     EQU $18E
COLOR08     EQU $190
COLOR09     EQU $192
COLOR10     EQU $194
COLOR11     EQU $196
COLOR12     EQU $198
COLOR13     EQU $19A
COLOR14     EQU $19C
COLOR15     EQU $19E
COLOR16     EQU $1A0
COLOR17     EQU $1A2
COLOR18     EQU $1A4
COLOR19     EQU $1A6
COLOR20     EQU $1A8
COLOR21     EQU $1AA
COLOR22     EQU $1AC
COLOR23     EQU $1AE
COLOR24     EQU $1B0
COLOR25     EQU $1B2
COLOR26     EQU $1B4
COLOR27     EQU $1B6
COLOR28     EQU $1B8
COLOR29     EQU $1BA
COLOR30     EQU $1BC
COLOR31     EQU $1BE
CIAAPRA     EQU $BFE001

; DMACONR/DMACON enable bits (hardware/dmabits.h): audio 0-3, disk 4,
; sprite 5, blitter 6, copper 7, bitplane (raster) 8, master (DMAEN) 9,
; blitter-priority 10. Bits 13/14 of DMACONR are the read-only BZERO/BBUSY.
DMAF_SETCLR  EQU $8000
DMAF_AUDIO   EQU $000F
DMAF_DISK    EQU $0010
DMAF_SPRITE  EQU $0020
DMAF_BLITTER EQU $0040
DMAF_COPPER  EQU $0080
DMAF_RASTER  EQU $0100
DMAF_MASTER  EQU $0200
DMAF_BLITHOG EQU $0400
DMAF_ALL     EQU $07FF      ; every allocatable DMA channel
DMAF_SYSTEM  EQU $07F0      ; everything except audio 0-3, restored on exit

; Exec.library library vector offsets.
LVO_Disable       EQU -120
LVO_Enable        EQU -126
LVO_Forbid        EQU -132
LVO_Permit        EQU -138
LVO_AllocMem      EQU -198
LVO_FreeMem       EQU -210
LVO_CopyMem       EQU -624
LVO_OpenLibrary    EQU -552
LVO_CloseLibrary  EQU -414
LVO_TypeOfMem     EQU -534

; graphics.library library vector offsets.
LVO_LoadView      EQU -222
LVO_WaitBlit      EQU -228
LVO_WaitTOF       EQU -270
LVO_OwnBlitter    EQU -456
LVO_DisownBlitter EQU -462

; GfxBase positive offsets.
GfxBase_ActiView  EQU 34
GfxBase_copinit   EQU 38

; AllocMem requirement flags.
MEMF_ANY   EQU $00008000
MEMF_CHIP  EQU $00000002
MEMF_FAST  EQU $00000004
MEMF_CLEAR EQU $00010000

; AmigaDOS return codes.
RETURN_OK   EQU 0
RETURN_FAIL EQU 20
