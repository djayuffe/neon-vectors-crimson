        include "hardware.i"

SCREEN_W_BYTES  EQU 40
SCREEN_H        EQU 256
PLANE_SIZE      EQU SCREEN_W_BYTES*SCREEN_H
PLANE_LONGS     EQU PLANE_SIZE/4
SCREEN_LONGS    EQU PLANE_LONGS*6   ; four display planes, two of them double-buffered
CHIPDATA_SIZE   EQU chipdata_end-chipdata_begin
FRAME_SYNC_LINE EQU 300     ; first line below the display window (DIWSTOP = line 300)
SILENCE_WORD    EQU $0000   ; Paula uses signed 8-bit PCM: zero is silence

; Screen layout (lines are screen rows; display line = row + 44).
LOGO_Y          EQU 8       ; 64 line logo band
LOGO_H          EQU 64
MID_Y0          EQU 76      ; stars and wireframe live in rows 76..195
MID_H           EQU 120
MID_CX          EQU 160
MID_CY          EQU 136
SCROLL_Y        EQU 200     ; 16 line scroller strip
SCROLL_H        EQU 16

NBALLS          EQU 8       ; hardware sprite ring
SPR_BYTES       EQU 80      ; per page: header 4 + up to 16 lines of 4 + terminator 4, rounded
SPR_PAGES       EQU NBALLS*3 ; one prebuilt page per sprite and ball size
RING_R          EQU 70
RING_TILT       EQU 40      ; tilt of the ring plane (256 = a full turn)
BALL_NEAR       EQU 285     ; distance below which a ball is drawn big (16 px)
BALL_MID        EQU 325     ; ... medium (12 px) below this, else small (8 px)

FLOOR_H         EQU 34      ; copper-bar floor rows (222..255)
NBARS           EQU 4

; Starfield: NSTARS points with (x, y, z); z runs from ZMAX down to ZMIN and wraps.
NSTARS          EQU 64
STAR_SIZE       EQU 10      ; x.w y.w z.w offset.w mask.b class.b
ZMIN            EQU 32
ZRANGE          EQU 224
ZSPEED          EQU 2
ZMID            EQU 150     ; z <= ZMID: mid distance;  z <= ZNEAR: near
ZNEAR           EQU 80
PROJ_F          EQU 128     ; star projection scale

; Wireframe: 7-bit sine table, perspective D/(z+ZOFF).
WIRE_D          EQU 220
WIRE_ZOFF       EQU 300
CUBE_S          EQU 42      ; cube vertices are (+-42, +-42, +-42)
INNER_S         EQU 18      ; inner cube half-size
OCTA_S          EQU 28      ; octahedron vertices are (+-28,0,0), (0,+-28,0), (0,0,+-28)
WIRE_SWAY       EQU 64      ; sideways swing, pixels
WIRE_ZOOM       EQU 18      ; breathing, distance units

; Runtime pointer slots. AllocChipMem copies the whole data_c block into chip
; RAM and rewrites every one of these long words to point into the copy, so no
; code may use a chipdata label as an address directly.
ptr_screen   equ reloc_table+0
ptr_logo     equ reloc_table+4
ptr_font     equ reloc_table+8
ptr_silence  equ reloc_table+12
ptr_mod      equ reloc_table+16
ptr_copper   equ reloc_table+20
ptr_cop_bpl1 equ reloc_table+24
ptr_raster   equ reloc_table+28
ptr_wave     equ reloc_table+32
ptr_bars     equ reloc_table+36
ptr_sprites  equ reloc_table+40
ptr_cop_spr  equ reloc_table+44

        section code,code
        xdef    _start
_start:
        movem.l d0-d7/a0-a6,-(sp)

; --- capture the system display state ---------------------------------------
; COP1LC is a write side custom register and cannot be read back, so the
; documented system startup list pointer is taken from GfxBase->copinit.
; All data below is addressed absolutely: the hunk loader relocates it, whereas
; PC-relative addressing cannot reach another hunk and cannot be a destination.
        move.l  4.w,a6
        lea     gfx_name,a1                 ; OpenLibrary(a1 = name, d0 = version)
        moveq   #0,d0                       ; (OldOpenLibrary is obsolete and traps under AROS)
        jsr     LVO_OpenLibrary(a6)
        move.l  d0,gfx_base
        beq     .open_fail
        move.l  d0,a0
        move.l  GfxBase_ActiView(a0),old_view
        move.l  GfxBase_copinit(a0),old_copper

; --- move every DMA visible payload into chip RAM ---------------------------
; Done while interrupts are still enabled: AllocMem must not be called from a
; Forbid/Disable section. The copy makes the demo work even if the loader
; ignored the data_c chip memory flag.
        bsr     AllocChipMem
        tst.l   d0
        beq     .alloc_fail

; --- detach the system view before touching the chipset --------------------
; Still with interrupts enabled, because WaitTOF() relies on the vertical
; blank interrupt owned by graphics.library.
        move.l  gfx_base,a6
        sub.l   a1,a1                      ; LoadView(a1 = NULL) detaches the View
        jsr     LVO_LoadView(a6)
        jsr     LVO_WaitTOF(a6)
        jsr     LVO_WaitTOF(a6)
        jsr     LVO_OwnBlitter(a6)
        jsr     LVO_WaitBlit(a6)

; --- snapshot the registers this demo overwrites ---------------------------
        lea     CUSTOM,a6
        move.w  DMACONR(a6),old_dmacon
        move.w  INTENAR(a6),old_intena
        move.w  ADKCONR(a6),old_adkcon

; --- take the chipset away from the operating system -----------------------
; Forbid() first, so no task switch can happen between Forbid and Disable.
        move.l  4.w,a6                     ; library base travels in a6, as on every Amiga library
        jsr     LVO_Forbid(a6)
        jsr     LVO_Disable(a6)
        lea     CUSTOM,a6

        move.w  #$7FFF,INTENA(a6)          ; clear every interrupt enable
        move.w  #$7FFF,INTREQ(a6)          ; acknowledge every interrupt
        move.w  #DMAF_ALL,DMACON(a6)       ; stop all DMA
        move.w  #$7FFF,ADKCON(a6)          ; clear every ADKCON bit: no UART/disk mods

        bsr     ClearScreen
        bsr     DrawLogo
        bsr     InitStars
        bsr     PatchCopper
        bsr     InitSprites
        bsr     MOD_Init

        move.l  ptr_copper,d0
        move.l  d0,COP1LCH(a6)
        move.w  #0,COPJMP1(a6)
; Blitter and sprite DMA are on for the wireframe and the ball ring. Audio DMA stays off here: a channel enabled before MOD_Row has loaded its
; location and length would play 128 KB of arbitrary memory as noise. Each
; channel is switched on by its first note.
        move.w  #(DMAF_SETCLR|DMAF_MASTER|DMAF_RASTER|DMAF_COPPER|DMAF_BLITTER|DMAF_SPRITE),DMACON(a6)

; --- main loop --------------------------------------------------------------
; One iteration per PAL frame: WaitFrameSync returns as the beam leaves the
; display window, so everything drawn below lands in the frame shown next.
.main:
        bsr     WaitFrameSync
        bsr     BlitWait                   ; last frame's wireframe blits must be finished
        bsr     WireSwap                   ; show the buffer drawn last frame
        addq.w  #1,frame_no
        bsr     UpdateSection              ; pick this frame's scene settings
        bsr     UpdateWave                 ; Copper rows above the beam first
        bsr     UpdateBars
        bsr     UpdateSprites              ; also before the beam reaches the ring
        bsr     UpdateRaster
        bsr     UpdateStars
        bsr     UpdateScroller
        bsr     MOD_Tick                   ; (timing-critical drawing first: the tick may wait on the blitter-free Paula setup)
        bsr     DrawWire                   ; draw the next frame into the hidden buffer
        btst    #6,CIAAPRA                 ; left mouse button, active low
        bne     .main

; --- teardown ---------------------------------------------------------------
; Stop the demo first, then hand the View back, then the Copper: LoadView only
; installs the View, it does not restart the system Copper list.
        lea     CUSTOM,a6
        bsr     BlitWait                   ; no blit may still be writing chip RAM
        bsr     MOD_Stop
        lea     CUSTOM,a6
        move.w  #$7FFF,INTENA(a6)
        move.w  #$7FFF,INTREQ(a6)
        move.w  #DMAF_ALL,DMACON(a6)

        move.l  gfx_base,a6
        move.l  old_view,a1                ; LoadView(a1 = View)
        jsr     LVO_LoadView(a6)

        lea     CUSTOM,a6
        move.l  old_copper,d0
        move.l  d0,COP1LCH(a6)
        move.w  #0,COPJMP1(a6)

; Restore the saved register values as SET/CLR writes, which is the only way
; to write the read-side DMACONR/INTENAR/ADKCONR state back. Audio DMA is
; deliberately left off: Paula location/length state is not snapshottable.
; BPLCON0/1/2 and the modulos are not restored by hand: LoadView and the
; restarted system Copper list rewrite them on the next frame.
        move.w  old_adkcon,d0
        andi.w  #$7FFF,d0
        ori.w   #$8000,d0
        move.w  d0,ADKCON(a6)
        move.w  old_intena,d0
        andi.w  #$7FFF,d0
        ori.w   #$8000,d0
        move.w  d0,INTENA(a6)
        move.w  old_dmacon,d0
        andi.w  #DMAF_SYSTEM,d0            ; everything except audio 0-3
        ori.w   #$8000,d0
        move.w  d0,DMACON(a6)

; The vertical-blank interrupt must be enabled again before the first WaitTOF: WaitTOF
; sleeps until that interrupt fires, so waiting with INTENA still masked hangs forever.
        move.l  4.w,a6
        jsr     LVO_Enable(a6)             ; interrupts before any wait
        jsr     LVO_Permit(a6)

        move.l  gfx_base,a6
        jsr     LVO_WaitTOF(a6)
        jsr     LVO_WaitTOF(a6)
        jsr     LVO_DisownBlitter(a6)

; The hardware no longer reads the payload block, so it can be returned.
        move.l  4.w,a6
        move.l  chip_base,a1               ; FreeMem(a1 = block, d0 = size)
        move.l  #CHIPDATA_SIZE,d0
        jsr     LVO_FreeMem(a6)

        move.l  gfx_base,a1                ; CloseLibrary(a1 = library)
        jsr     LVO_CloseLibrary(a6)
        movem.l (sp)+,d0-d7/a0-a6
        moveq   #RETURN_OK,d0
        rts

.open_fail:
        movem.l (sp)+,d0-d7/a0-a6
        moveq   #RETURN_FAIL,d0
        rts

.alloc_fail:
        move.l  4.w,a6
        move.l  gfx_base,a1
        jsr     LVO_CloseLibrary(a6)
        movem.l (sp)+,d0-d7/a0-a6
        moveq   #RETURN_FAIL,d0
        rts

; ---------------------------------------------------------------------------
; Chip memory. The data_c block is one contiguous run, so it is copied as a
; whole and every label inside it is re-based in one pass.
; ---------------------------------------------------------------------------
AllocChipMem:
        move.l  4.w,a6
        move.l  #CHIPDATA_SIZE,d0          ; AllocMem(d0 = size, d1 = flags)
        move.l  #MEMF_CHIP,d1
        jsr     LVO_AllocMem(a6)
        move.l  d0,chip_base
        beq     .no_mem

; Confirm what the allocator returned instead of assuming it: bitplane, Copper
; and Paula DMA cannot be pointed at fast RAM, so a non chip block is a failure
; and the memory is handed straight back.
        move.l  d0,a1                      ; TypeOfMem(a1 = address)
        jsr     LVO_TypeOfMem(a6)
        andi.l  #MEMF_CHIP,d0
        bne     .have_mem
        move.l  chip_base,a1               ; FreeMem(a1 = block, d0 = size)
        move.l  #CHIPDATA_SIZE,d0
        jsr     LVO_FreeMem(a6)
        clr.l   chip_base
        bra     .no_mem
.have_mem:

; Copy the assembled payload block into the allocated memory with Exec's
; CopyMem(a0 = source, a1 = dest, d0 = size).
        lea     chipdata_begin,a0
        move.l  chip_base,a1
        move.l  #CHIPDATA_SIZE,d0
        jsr     LVO_CopyMem(a6)

; Re-base every long in reloc_table: runtime = base + (assembled - block).
        lea     chipdata_begin,a6
        move.l  chip_base,a5
        lea     reloc_table,a4
        move.w  #RELOC_COUNT-1,d6
.reloc:
        move.l  (a4),d0
        sub.l   a6,d0
        add.l   a5,d0
        move.l  d0,(a4)+
        dbra    d6,.reloc

        move.l  chip_base,d0
        rts
.no_mem:
        moveq   #0,d0
        rts

; ---------------------------------------------------------------------------
; Beam position helpers.
;
; A 68000 longword read uses two bus cycles. Re-read VPOSR after the pair
; and retry if V8 changed, avoiding a torn line at the 255/256 boundary or
; frame wrap. Preserve d1 because WaitLines uses it across calls.
; a6 must be CUSTOM. Only d0 is clobbered.
; ---------------------------------------------------------------------------
BeamLine:
        move.l  d1,-(sp)
.retry:
        move.l  VPOSR(a6),d0
        move.w  VPOSR(a6),d1
        swap    d0
        eor.w   d0,d1
        btst    #0,d1
        bne     .retry
        swap    d0
        lsr.l   #8,d0
        andi.w  #$01FF,d0
        move.l  (sp)+,d1
        rts

; Sync to the first line below the display window, once per frame. The loop
; first leaves the sync zone, so a frame whose work finished below the sync
; line is not counted twice: one call per frame gives the tracker tick rate of
; 50 Hz on both the 312 and the 313 line PAL frame.
;
; The intro is PAL only. On a 262 line NTSC frame line 300 never arrives, which
; would hang a machine that has interrupts disabled, so the wait also ends when
; the beam wraps to the top of the frame (the intro then runs, badly timed,
; instead of locking up, and the mouse button still exits).
WaitFrameSync:
.leave:
        bsr     BeamLine
        cmp.w   #FRAME_SYNC_LINE,d0
        bhs     .leave
.enter:
        move.w  d0,d2                      ; previous line
        bsr     BeamLine
        cmp.w   #FRAME_SYNC_LINE,d0
        bhs     .synced
        cmp.w   d2,d0
        bhs     .enter                     ; still counting up
.synced:
        rts

; Wait for d3.b raster lines to pass. a6 must be CUSTOM.
WaitLines:
.w1:
        bsr     BeamLine
        move.w  d0,d1
.w2:
        bsr     BeamLine
        cmp.w   d1,d0
        beq     .w2
        subq.b  #1,d3
        bne     .w1
        rts

; ---------------------------------------------------------------------------
; Screen setup.
; ---------------------------------------------------------------------------
ClearScreen:
        move.l  ptr_screen,a0
        moveq   #0,d0
        move.w  #SCREEN_LONGS-1,d7
.cs:
        move.l  d0,(a0)+
        dbra    d7,.cs
        rts

; The logo has four planes of LOGO_H rows. Plane 0 and 2 go into their plane, planes 1 and 3
; into both buffers of their plane (the object code only ever touches the middle band).
DrawLogo:
        move.l  ptr_logo,a0
        move.l  ptr_screen,a1
        lea     LOGO_Y*SCREEN_W_BYTES(a1),a2
        bsr     CopyLogoPlane              ; plane 0
        lea     PLANE_SIZE+LOGO_Y*SCREEN_W_BYTES(a1),a2
        bsr     CopyLogoPlane              ; plane 1, buffer 0
        lea     -(SCREEN_W_BYTES*LOGO_H)(a0),a0
        lea     PLANE_SIZE*2+LOGO_Y*SCREEN_W_BYTES(a1),a2
        bsr     CopyLogoPlane              ; plane 1, buffer 1
        lea     PLANE_SIZE*3+LOGO_Y*SCREEN_W_BYTES(a1),a2
        bsr     CopyLogoPlane              ; plane 2
        move.l  a1,a2
        adda.l  #PLANE_SIZE*4+LOGO_Y*SCREEN_W_BYTES,a2
        bsr     CopyLogoPlane              ; plane 3, buffer 0
        lea     -(SCREEN_W_BYTES*LOGO_H)(a0),a0
        move.l  a1,a2
        adda.l  #PLANE_SIZE*5+LOGO_Y*SCREEN_W_BYTES,a2
        bsr     CopyLogoPlane              ; plane 3, buffer 1
        rts

; in: a0 = source (advanced past the plane), a2 = destination
CopyLogoPlane:
        move.w  #(SCREEN_W_BYTES*LOGO_H/4)-1,d7
.c:
        move.l  (a0)+,(a2)+
        dbra    d7,.c
        rts

; Rewrite the three bitplane pointer pairs in the copied Copper list. The list is
; stored as MOVE pairs, so the register words sit at byte offsets 0/4/8/12/16/20
; and the data words that PatchCopper overwrites at 2/6, 10/14 and 18/22.
; The Copper plane pointers are 2 bytes before the plane (the extra fetch word). The
; screen block holds plane 0, the two buffers of plane 1, plane 2 and the two buffers
; of plane 3, in that order; planes 1 and 3 (the 3D object planes) are double-buffered
; and the display uses whichever buffer of each is currently in front.
PatchCopper:
        move.l  ptr_cop_bpl1,a1
        move.l  ptr_screen,d3
        subq.l  #2,d3                      ; every plane starts one word early: BPLCON1 scroll fetches it
        move.l  d3,d0
        move.w  d0,6(a1)                   ; BPL1PTL
        swap    d0
        move.w  d0,2(a1)                   ; BPL1PTH
        moveq   #0,d0
        move.w  wire_front,d0
        addq.w  #1,d0
        mulu    #PLANE_SIZE,d0
        add.l   d3,d0
        move.w  d0,14(a1)                  ; BPL2PTL: plane 1, the front buffer
        swap    d0
        move.w  d0,10(a1)                  ; BPL2PTH
        move.l  d3,d0
        addi.l  #PLANE_SIZE*3,d0
        move.w  d0,22(a1)                  ; BPL3PTL
        swap    d0
        move.w  d0,18(a1)                  ; BPL3PTH
        moveq   #0,d0
        move.w  wire_front,d0
        addq.w  #4,d0
        mulu    #PLANE_SIZE,d0
        add.l   d3,d0
        move.w  d0,30(a1)                  ; BPL4PTL: plane 3, the front buffer
        swap    d0
        move.w  d0,26(a1)                  ; BPL4PTH
        rts

; Flip the wireframe buffers and point the Copper at the one drawn last frame.
WireSwap:
        eori.w  #1,wire_front
        bsr     PatchCopper
        rts

; ---------------------------------------------------------------------------
; Wavy logo. Every logo row has its own BPLCON1 move in the Copper list (cop_wave,
; 16 bytes per row, value at +14). Each frame the 64 values follow a precomputed layered wave of
; the row and the frame count (table wave_tab: 2..14 pixels of horizontal scroll, the
; same nibble for both playfields). Rows start at the Copper's WAIT, so this must finish before the
; beam reaches the logo; it runs first in the frame.
; ---------------------------------------------------------------------------
UpdateWave:
        move.l  ptr_wave,a1
        lea     wave_tab,a2
        move.w  frame_no,d0
        lsl.w   #3,d0                      ; byte offset: four wave steps per frame
        andi.w  #510,d0
        moveq   #LOGO_H-1,d7
.w:
        move.w  0(a2,d0.w),14(a1)          ; BPLCON1 value for this row
        addq.w  #6,d0                      ; three entries per logo row
        andi.w  #510,d0
        lea     16(a1),a1
        dbra    d7,.w
        rts

; ---------------------------------------------------------------------------
; Copper-bar floor. The 34 floor rows (cop_bars, 8 bytes per row, COLOR00 value at +6)
; are first reset to the static ramp, then NBARS bars of 8 rows are painted over them,
; each moving on its own sine; later bars are in front.
; ---------------------------------------------------------------------------
UpdateBars:
        move.l  ptr_bars,a1
        lea     floor_base,a2
        move.l  a1,a3
        moveq   #FLOOR_H-1,d7
.base:
        move.w  (a2)+,6(a3)
        lea     8(a3),a3
        dbra    d7,.base
        lea     bar_motion,a2
        lea     bar_colors,a3
        moveq   #0,d6
.bar:
        move.w  frame_no,d0
        move.w  d6,d1
        addq.w  #2,d1
        mulu    d1,d0                      ; frame * (bar + 2): each bar has its own speed
        move.w  d6,d1
        lsl.w   #6,d1
        add.w   d1,d0                      ; + 64 steps of phase per bar
        andi.w  #255,d0
        add.w   d0,d0
        move.w  0(a2,d0.w),d0
        moveq   #8-1,d7
.row:
        tst.w   d0
        bmi     .skip
        cmp.w   #FLOOR_H,d0
        bge     .skip
        move.w  d0,d1
        lsl.w   #3,d1
        move.w  (a3),6(a1,d1.w)
.skip:
        addq.l  #2,a3
        addq.w  #1,d0
        dbra    d7,.row
        addq.w  #1,d6
        cmp.w   #NBARS,d6
        blo     .bar
        rts

; ---------------------------------------------------------------------------
; Animated Copper colour slot. This is the COLOR00 pair at raster line $80, so
; the CPU animated band and the Copper side of the list cannot fight: the
; update happens below the display window, the Copper reads the slot at line 128.
; ---------------------------------------------------------------------------
UpdateRaster:
        addq.w  #1,phase
        move.w  phase,d0
        andi.w  #$1F,d0
        lea     raster_colors,a0
        add.w   d0,d0
        move.w  0(a0,d0.w),d1
        move.l  ptr_raster,a1
        move.w  d1,2(a1)
        rts

; ---------------------------------------------------------------------------
; 3D starfield. Each star is (x, y, z); z falls by the current scene speed per frame and the star
; is projected as screen = centre + coordinate * PROJ_F / z, so near stars move
; faster and further from the centre than far ones. When z reaches ZMIN the star
; is sent to the back with a new x and y.
;
; Depth is shown with brightness, using the planes that are free in the middle
; band: far = plane 2 only, mid = plane 0 only, near = planes 0 and 2. The
; palette turns those three combinations into three brightnesses.
;
; Every star remembers the byte offset, bit mask and class (bit 0 = plane 2,
; bit 1 = plane 0) it was drawn with, so the next frame erases exactly that.
; ---------------------------------------------------------------------------
Rand:                                      ; 16 bit LCG; result in d0.w
        move.w  rng_seed,d0
        mulu    #25173,d0
        addi.l  #13849,d0
        move.w  d0,rng_seed
        rts

InitStars:
        move.w  #1,rng_seed
        lea     stars,a2
        moveq   #NSTARS-1,d7
.is:
        bsr     Rand
        andi.w  #511,d0
        subi.w  #255,d0
        move.w  d0,(a2)                    ; x -255..256
        bsr     Rand
        andi.w  #255,d0
        subi.w  #128,d0
        muls    #5,d0
        asr.l   #3,d0
        move.w  d0,2(a2)                   ; y -80..79
        bsr     Rand
        andi.w  #255,d0
        mulu    #ZRANGE,d0
        lsr.l   #8,d0
        addi.w  #ZMIN,d0
        move.w  d0,4(a2)                   ; z ZMIN..ZMIN+ZRANGE-1
        clr.w   6(a2)
        clr.b   8(a2)
        clr.b   9(a2)                      ; nothing drawn yet
        lea     STAR_SIZE(a2),a2
        dbra    d7,.is
        rts

UpdateStars:
        move.l  ptr_screen,a0              ; plane 0
        lea     PLANE_SIZE*3(a0),a1        ; plane 2
        lea     stars,a2
; Erase every star at its remembered position first, so two stars sharing a
; byte cannot cancel each other's pixel.
        moveq   #NSTARS-1,d7
.er:
        move.b  9(a2),d0
        beq     .ernext
        move.w  6(a2),d2
        move.b  8(a2),d1
        not.b   d1
        btst    #0,d0
        beq     .er0
        and.b   d1,0(a1,d2.w)
.er0:
        btst    #1,d0
        beq     .er1
        and.b   d1,0(a0,d2.w)
.er1:
        clr.b   9(a2)
.ernext:
        lea     STAR_SIZE(a2),a2
        dbra    d7,.er

        lea     stars,a2
        lea     recip_star,a3
        movea.w sec_zspeed,a5              ; cache scene speed outside the star loop
        lea     row_offsets,a4
        moveq   #NSTARS-1,d7
.dr:
        move.w  4(a2),d3
        sub.w   a5,d3
        cmp.w   #ZMIN,d3
        bge     .zok
        addi.w  #ZRANGE,d3                 ; back to the far end, new lane
        bsr     Rand
        andi.w  #511,d0
        subi.w  #255,d0
        move.w  d0,(a2)
        bsr     Rand
        andi.w  #255,d0
        subi.w  #128,d0
        muls    #5,d0
        asr.l   #3,d0
        move.w  d0,2(a2)
.zok:
        move.w  d3,4(a2)
        move.w  d3,d6
        add.w   d6,d6
        move.w  0(a3,d6.w),d6              ; PROJ_F * 256 / z
        move.w  (a2),d0
        muls    d6,d0
        asr.l   #8,d0                      ; x * PROJ_F / z
        addi.w  #MID_CX,d0                 ; screen x
        cmp.w   #320,d0
        bhs     .skip                      ; unsigned: also catches negative x
        move.w  2(a2),d1
        muls    d6,d1
        asr.l   #8,d1
        addi.w  #MID_CY,d1                 ; screen y
        move.w  d1,d2
        subi.w  #MID_Y0,d2
        cmp.w   #MID_H,d2
        bhs     .skip
        add.w   d1,d1
        move.w  0(a4,d1.w),d1              ; y * 40 from a word-offset table
        move.w  d0,d2
        lsr.w   #3,d2
        add.w   d2,d1                      ; byte offset of the star
        move.w  d1,6(a2)
        andi.w  #7,d0
        moveq   #-128,d4
        lsr.b   d0,d4                      ; MSB-first pixel mask
        move.b  d4,8(a2)
        moveq   #1,d5                      ; far: plane 2 only
        cmp.w   #ZMID,d3
        bgt     .far
        moveq   #2,d5                      ; mid: plane 0 only
        cmp.w   #ZNEAR,d3
        bgt     .mid
        moveq   #3,d5                      ; near: both star planes
        or.b    d4,0(a1,d1.w)
.mid:
        or.b    d4,0(a0,d1.w)
        bra     .remember
.far:
        or.b    d4,0(a1,d1.w)
.remember:
        move.b  d5,9(a2)
.skip:
.dnext:
        lea     STAR_SIZE(a2),a2
        dbra    d7,.dr
        rts

; ---------------------------------------------------------------------------
; Scroller. Every update shifts the sixteen scroller rows one pixel left. A row
; is 40 bytes, so it is shifted as ten big endian longwords with ROXL, from the
; rightmost longword to the leftmost: each longword's bit 31 falls into X and
; enters the next longword to its left at bit 0. Rows and planes are 4-byte
; aligned, so the long accesses are legal on a 68000. Longwords roughly halve
; the cost of a word loop, which keeps the whole frame inside the vblank window.
;
; MOVEQ does not touch X, so X is cleared explicitly before each row; MOVE,
; SUBQ on an address register and DBRA all leave X alone between two shifts.
; ---------------------------------------------------------------------------
UpdateScroller:
        addq.b  #1,scroll_div
        cmp.b   #2,scroll_div
        blo     .done
        clr.b   scroll_div

        move.l  ptr_screen,a0
        adda.l  #SCROLL_Y*SCREEN_W_BYTES,a0
        moveq   #SCROLL_H-1,d7
.sc_row:
        lea     SCREEN_W_BYTES-4(a0),a4    ; last longword of the row
        moveq   #SCREEN_W_BYTES/4-1,d6
        andi    #$EF,ccr                   ; X = 0 enters the rightmost longword
.sc_long:
        move.l  (a4),d1
        roxl.l  #1,d1
        move.l  d1,(a4)
        subq.l  #4,a4
        dbra    d6,.sc_long
        lea     SCREEN_W_BYTES(a0),a0
        dbra    d7,.sc_row

        addq.b  #1,glyph_col
        cmp.b   #8,glyph_col
        blo     .sc_insert
        clr.b   glyph_col
        addq.l  #1,scroll_ptr
        move.l  scroll_ptr,a1
        tst.b   (a1)
        bne     .sc_insert
        lea     scroll_text,a1
        move.l  a1,scroll_ptr
.sc_insert:
        move.l  scroll_ptr,a1
        moveq   #0,d0
        move.b  (a1),d0
        sub.w   #32,d0
        bpl     .sc_chr_ok
        moveq   #0,d0                     ; below the font, render a blank
.sc_chr_ok:
        cmp.w   #95,d0
        blo     .sc_chr_range
        moveq   #0,d0                     ; above the font, render a blank
.sc_chr_range:
        lsl.w   #3,d0
        move.l  ptr_font,a2
        adda.l  d0,a2
        moveq   #0,d1
        move.b  glyph_col,d1
        moveq   #7,d2
        sub.w   d1,d2                      ; bit of this column inside the byte
        move.l  ptr_screen,a0
        adda.l  #(SCROLL_Y*SCREEN_W_BYTES)+SCREEN_W_BYTES-1,a0
        moveq   #7,d7
.sc_glyph:                                 ; every font row is drawn on two lines
        move.b  (a2)+,d3
        btst    d2,d3
        beq     .sc_zero
        bset    #0,(a0)
        bset    #0,SCREEN_W_BYTES(a0)
        bra     .sc_next
.sc_zero:
        bclr    #0,(a0)
        bclr    #0,SCREEN_W_BYTES(a0)
.sc_next:
        lea     SCREEN_W_BYTES*2(a0),a0
        dbra    d7,.sc_glyph
.done:
        rts

; ---------------------------------------------------------------------------
; Hardware sprite ring: eight shaded balls on a tilted ring that spins, rolls and
; wobbles in 3D around the wireframe. The sprite hardware draws them; the CPU only
; rewrites each sprite's small buffer (position words and a 16 line bitmap) once a
; frame, early, before the beam reaches the ring.
;
; Per ball: a point on the ring is rotated by the tilt (about x) and roll (about z),
; so with y = 0 the 3x3 matrix needs only five coefficients:
;     x'' = (x0*A + z0*B) >> 7      A = cos(roll)            B = sin(tilt)*sin(roll) >> 7
;     y'' = (x0*C + z0*D) >> 7      C = sin(roll)            D = -(sin(tilt)*cos(roll) >> 7)
;     z'' = (z0*F) >> 7             F = cos(tilt)
; and projected with the reciprocal table. Balls are sorted by distance and the nearest
; get the lowest sprite numbers (the sprite hardware puts a lower number in front), which
; also gives them the brightest sprite-pair palette. Size (16/12/8 pixels) follows distance.
; ---------------------------------------------------------------------------
; Every sprite gets three prebuilt pages (one per ball size): position words, the shaded
; ball bitmap, and the end-of-sprite zero long. Per frame only the header words of the
; chosen page and the sprite's Copper pointer change, so no bitmap is ever copied.
InitSprites:
        move.l  ptr_sprites,a1
        moveq   #NBALLS-1,d7
.sprite:
        lea     ball_bitmaps,a2
        moveq   #16,d2
        bsr     .page
        lea     64+ball_bitmaps,a2
        moveq   #12,d2
        bsr     .page
        lea     112+ball_bitmaps,a2
        moveq   #8,d2
        bsr     .page
        dbra    d7,.sprite
        rts
.page:                                     ; a1 = page, a2 = bitmap, d2 = lines; a1 advances one page
        move.l  a1,a3
        clr.l   (a3)+                      ; header, set per frame
        move.w  d2,d0
        subq.w  #1,d0
.l:
        move.l  (a2)+,(a3)+
        dbra    d0,.l
        clr.l   (a3)                       ; terminator
        lea     SPR_BYTES(a1),a1
        rts

; in: d0 = angle; a4 = sintab. out: d1 = sin, d2 = cos (scaled by 127)
SinCos:
        andi.w  #255,d0
        add.w   d0,d0
        move.w  0(a4,d0.w),d1
        addi.w  #128,d0
        andi.w  #511,d0
        move.w  0(a4,d0.w),d2
        rts

UpdateSprites:
        lea     sintab,a4
        move.w  frame_no,d0
        add.w   d0,d0                      ; the tilt wobbles with 2 * frame
        bsr     SinCos
        asr.w   #4,d1
        addi.w  #RING_TILT,d1
        move.w  d1,d0                      ; tilt angle
        bsr     SinCos
        move.w  d1,r_stilt
        move.w  d2,r_ctilt
        move.w  frame_no,d0                ; roll = frame
        bsr     SinCos
        move.w  d1,r_sroll
        move.w  d2,r_croll
; coefficients
        move.w  r_croll,r_a
        move.w  r_stilt,d0
        muls    r_sroll,d0
        asr.l   #7,d0
        move.w  d0,r_b
        move.w  r_sroll,r_c
        move.w  r_stilt,d0
        muls    r_croll,d0
        asr.l   #7,d0
        neg.w   d0
        move.w  d0,r_d
        move.w  r_ctilt,r_f
; the balls
        lea     ball_zc,a1
        lea     ball_sx,a2
        lea     ball_sy,a3
        lea     recip_wire,a5
        moveq   #0,d7                      ; ball number
.ball:
        move.w  frame_no,d0
        move.w  d0,d1
        add.w   d1,d1
        add.w   d1,d0                      ; 3 * frame: the spin
        move.w  d7,d1
        lsl.w   #5,d1                      ; 32 steps between balls
        add.w   d1,d0
        andi.w  #255,d0
        lsl.w   #2,d0
        lea     ring_tab,a0
        move.w  0(a0,d0.w),d2              ; x0 = RING_R * cos >> 7
        move.w  2(a0,d0.w),d1              ; z0 = RING_R * sin >> 7
        move.w  d2,d3
        muls    r_a,d3
        move.w  d1,d4
        muls    r_b,d4
        add.l   d4,d3
        asr.l   #7,d3                      ; x''
        move.w  d2,d4
        muls    r_c,d4
        move.w  d1,d5
        muls    r_d,d5
        add.l   d5,d4
        asr.l   #7,d4                      ; y''
        muls    r_f,d1
        asr.l   #7,d1                      ; z''
        addi.w  #WIRE_ZOFF,d1              ; distance
        move.w  d1,(a1)+
        add.w   d1,d1
        move.w  0(a5,d1.w),d1              ; D*256/distance
        muls    d1,d3
        asr.l   #8,d3
        add.w   wire_cx,d3
        move.w  d3,(a2)+                   ; screen x
        muls    d1,d4
        asr.l   #8,d4
        addi.w  #MID_CY,d4
        move.w  d4,(a3)+                   ; screen y
        addq.w  #1,d7
        cmp.w   #NBALLS,d7
        blo     .ball
; stable insertion sort of the ball numbers by distance, nearest first
        lea     ball_order,a1
        moveq   #0,d0
.init:
        move.w  d0,(a1)+
        addq.w  #1,d0
        cmp.w   #NBALLS,d0
        blo     .init
        lea     ball_order,a1
        lea     ball_zc,a2
        moveq   #1,d6                      ; j
.sj:
        move.w  d6,d0
        add.w   d0,d0
        move.w  0(a1,d0.w),d4              ; key = order[j]
        move.w  d4,d0
        add.w   d0,d0
        move.w  0(a2,d0.w),d5              ; its distance
        move.w  d6,d3                      ; insertion position
.si:
        tst.w   d3
        beq     .place
        move.w  d3,d0
        subq.w  #1,d0
        add.w   d0,d0                      ; byte offset of order[position-1]
        move.w  0(a1,d0.w),d1
        add.w   d1,d1
        move.w  0(a2,d1.w),d2              ; distance of that ball
        cmp.w   d5,d2
        ble     .place                     ; not further than the key: stable, stop
        move.w  0(a1,d0.w),2(a1,d0.w)      ; shift it up
        subq.w  #1,d3
        bra     .si
.place:
        move.w  d3,d0
        add.w   d0,d0
        move.w  d4,0(a1,d0.w)
        addq.w  #1,d6
        cmp.w   #NBALLS,d6
        blo     .sj
; write the sprites, rank 0 = nearest = sprite 0
        moveq   #0,d7
.wr:
        move.w  d7,d0
        add.w   d0,d0
        lea     ball_order,a1
        move.w  0(a1,d0.w),d6              ; ball number
        move.w  d6,d0
        add.w   d0,d0
        lea     ball_zc,a1
        move.w  0(a1,d0.w),d3              ; distance
        lea     ball_sx,a1
        move.w  0(a1,d0.w),d4              ; screen x
        lea     ball_sy,a1
        move.w  0(a1,d0.w),d5              ; screen y
        moveq   #16,d2
        moveq   #0,d6                      ; size class
        cmp.w   #BALL_NEAR,d3
        blt     .sized
        moveq   #12,d2
        moveq   #1,d6
        cmp.w   #BALL_MID,d3
        blt     .sized
        moveq   #8,d2
        moveq   #2,d6
.sized:
        move.w  d5,d0
        addi.w  #44,d0                     ; display line of the ball's centre
        move.w  d2,d1
        lsr.w   #1,d1
        sub.w   d1,d0                      ; VSTART
        move.w  d0,d1
        add.w   d2,d1                      ; VSTOP
        move.w  d4,d3
        addi.w  #$81-8,d3                  ; HSTART: $81 is the window's left edge, minus half the sprite
        move.w  d0,d4
        andi.w  #255,d4
        lsl.w   #8,d4
        move.w  d3,d5
        lsr.w   #1,d5
        andi.w  #255,d5
        or.w    d5,d4                      ; SPRxPOS
        move.w  d1,d5
        andi.w  #255,d5
        lsl.w   #8,d5
        btst    #8,d0
        beq     .v0
        ori.w   #4,d5
.v0:
        btst    #8,d1
        beq     .v1
        ori.w   #2,d5
.v1:
        andi.w  #1,d3
        or.w    d3,d5                      ; SPRxCTL
; page = sprites + (rank * 3 + size class) * SPR_BYTES, class 0 = 16 px, 1 = 12, 2 = 8
        move.w  d7,d0
        add.w   d0,d0
        add.w   d7,d0                      ; rank * 3
        add.w   d6,d0                      ; + size class
        mulu    #SPR_BYTES,d0
        move.l  ptr_sprites,a1
        adda.l  d0,a1
        move.w  d4,(a1)
        move.w  d5,2(a1)                   ; header words
        move.l  ptr_cop_spr,a2             ; point this sprite's Copper pointer pair at the page
        move.w  d7,d0
        lsl.w   #3,d0
        adda.w  d0,a2
        move.l  a1,d0
        move.w  d0,6(a2)
        swap    d0
        move.w  d0,2(a2)
        addq.w  #1,d7
        cmp.w   #NBALLS,d7
        blo     .wr
        rts

; ---------------------------------------------------------------------------
; Wireframe. A cube (objects' vertices 0..7) and an octahedron (8..13) rotate in
; opposite directions. Each frame: the hidden buffer's band is cleared by the
; blitter while the CPU builds the rotation matrices and projects the vertices,
; then every edge is drawn with the blitter in line mode. The buffer becomes
; visible only after WireSwap, so the picture never shows a half-drawn frame.
; ---------------------------------------------------------------------------
BlitWait:                                  ; a6 = CUSTOM
        btst    #6,DMACONR(a6)             ; dummy read: older Agnus revisions need it
.w:
        btst    #6,DMACONR(a6)             ; BBUSY
        bne     .w
        rts

DrawWire:
        lea     CUSTOM,a6
        move.l  ptr_screen,a0
        moveq   #0,d0
        move.w  wire_front,d0
        eori.w  #1,d0                      ; the hidden buffer
        addq.w  #1,d0
        mulu    #PLANE_SIZE,d0
        adda.l  d0,a0                      ; a0 = hidden wireframe buffer

        bsr     BlitWait
        move.w  #$0100,BLTCON0(a6)         ; D only, minterm 0: clear
        move.w  #0,BLTCON1(a6)
        move.w  #0,BLTDMOD(a6)
        lea     MID_Y0*SCREEN_W_BYTES(a0),a1
        move.l  a1,BLTDPTH(a6)
        move.w  #(MID_H<<6)|(SCREEN_W_BYTES/2),BLTSIZE(a6)

        move.w  sec_spin,d0
        add.w   d0,ang_x
        add.w   d0,ang_z
        move.w  d0,d1
        add.w   d0,d0
        add.w   d1,d0                      ; 3 * spin
        add.w   d0,ang_y
; Motion path: the object sways left and right and breathes towards and away from the eye.
        lea     sintab,a2
        move.w  ang_x,d0
        andi.w  #255,d0
        add.w   d0,d0
        move.w  0(a2,d0.w),d0
        muls    #WIRE_SWAY,d0
        asr.l   #7,d0
        addi.w  #MID_CX,d0
        move.w  d0,wire_cx
        move.w  ang_y,d0
        andi.w  #255,d0
        add.w   d0,d0
        move.w  0(a2,d0.w),d0
        muls    #WIRE_ZOOM,d0
        asr.l   #7,d0
        addi.w  #WIRE_ZOFF,d0
        move.w  d0,wire_zoff
        lea     proj,a3
; Cube: angles (x, y, z).
        move.w  ang_x,d0
        move.w  ang_y,d1
        move.w  ang_z,d2
        bsr     CalcMatrix
        lea     verts,a1
        moveq   #8-1,d7
        move.w  sec_cube,d6
        bsr     TransformVerts
; Octahedron turns the other way.
        move.w  ang_z,d0
        add.w   d0,d0
        move.w  ang_x,d1
        neg.w   d1
        move.w  ang_y,d2
        neg.w   d2
        bsr     CalcMatrix
        moveq   #6-1,d7
        move.w  sec_octa,d6
        bsr     TransformVerts             ; a1 continues at the octahedron vertices
; Inner cube: the cube's vertex table again, small, tumbling on its own axes.
        move.w  ang_y,d0
        add.w   d0,d0
        move.w  ang_z,d1
        neg.w   d1
        move.w  ang_x,d2
        lsl.w   #2,d2
        bsr     CalcMatrix
        lea     verts,a1
        moveq   #8-1,d7
        move.w  sec_inner,d6
        bsr     TransformVerts

        bsr     BlitWait                   ; the clear must be done before lines go in
        move.w  #SCREEN_W_BYTES,BLTCMOD(a6)    ; registers every line shares: set once
        move.w  #SCREEN_W_BYTES,BLTDMOD(a6)
        move.w  #$8000,BLTADAT(a6)
        move.w  #$FFFF,BLTBDAT(a6)
        move.w  #$FFFF,BLTAFWM(a6)
        move.w  #$FFFF,BLTALWM(a6)
        lea     proj,a3
        btst    #0,sec_mask+1
        beq     .no_cube
        lea     edges,a4
        lea     edges+24,a5
        bsr     DrawEdges
.no_cube:
        btst    #1,sec_mask+1
        beq     .no_octa
        lea     edges+24,a4
        lea     edges+48,a5
        bsr     DrawEdges
.no_octa:
        btst    #2,sec_mask+1
        beq     .no_inner
        lea     edges+48,a4
        lea     edges_end,a5
        bsr     DrawEdges
.no_inner:
        rts

; a3 = proj, a4 = first edge, a5 = end of the edge range
DrawEdges:
.edge:
        moveq   #0,d4
        move.b  (a4)+,d4
        lsl.w   #2,d4
        move.w  0(a3,d4.w),d0
        move.w  2(a3,d4.w),d1
        moveq   #0,d4
        move.b  (a4)+,d4
        lsl.w   #2,d4
        move.w  0(a3,d4.w),d2
        move.w  2(a3,d4.w),d3
        bsr     BlitLine
        cmpa.l  a5,a4
        blo     .edge
        rts

; Demo sections: 8 scenes of 256 frames. Each row of sec_tab is
; star speed, spin, cube size, octahedron size, inner cube size, visible objects (bit 0 cube, 1 octa, 2 inner).
UpdateSection:
        move.w  frame_no,d0
        lsr.w   #8,d0
        andi.w  #7,d0
        mulu    #12,d0
        lea     sec_tab,a0
        add.w   d0,a0
        move.w  (a0)+,sec_zspeed
        move.w  (a0)+,sec_spin
        move.w  (a0)+,sec_cube
        move.w  (a0)+,sec_octa
        move.w  (a0)+,sec_inner
        move.w  (a0)+,sec_mask
        rts

; (d0.w * d1.w) >> 7, result in d0. Used for the 7 bit fixed point matrix.
Mul7:
        muls    d1,d0
        asr.l   #7,d0
        rts

; in: d0 = angle x, d1 = angle y, d2 = angle z (0..255 is a full turn)
; out: mat[0..8] = Rz * Ry * Rx, scaled by 128.  Clobbers d0-d2, a2, a4 (a1 and a3 are
; the caller's vertex pointers and must survive).
CalcMatrix:
        lea     sintab,a4
        andi.w  #255,d0
        add.w   d0,d0
        move.w  0(a4,d0.w),sx
        addi.w  #128,d0                    ; +64 entries of 2 bytes: cosine
        andi.w  #511,d0
        move.w  0(a4,d0.w),cx
        andi.w  #255,d1
        add.w   d1,d1
        move.w  0(a4,d1.w),sy
        addi.w  #128,d1
        andi.w  #511,d1
        move.w  0(a4,d1.w),cy
        andi.w  #255,d2
        add.w   d2,d2
        move.w  0(a4,d2.w),sz
        addi.w  #128,d2
        andi.w  #511,d2
        move.w  0(a4,d2.w),cz
        lea     mat,a2
; m00 = cz*cy
        move.w  cz,d0
        move.w  cy,d1
        bsr     Mul7
        move.w  d0,(a2)
; m01 = cz*sy*sx - sz*cx
        move.w  cz,d0
        move.w  sy,d1
        bsr     Mul7
        move.w  sx,d1
        bsr     Mul7
        move.w  d0,d2
        move.w  sz,d0
        move.w  cx,d1
        bsr     Mul7
        sub.w   d0,d2
        move.w  d2,2(a2)
; m02 = cz*sy*cx + sz*sx
        move.w  cz,d0
        move.w  sy,d1
        bsr     Mul7
        move.w  cx,d1
        bsr     Mul7
        move.w  d0,d2
        move.w  sz,d0
        move.w  sx,d1
        bsr     Mul7
        add.w   d0,d2
        move.w  d2,4(a2)
; m10 = sz*cy
        move.w  sz,d0
        move.w  cy,d1
        bsr     Mul7
        move.w  d0,6(a2)
; m11 = sz*sy*sx + cz*cx
        move.w  sz,d0
        move.w  sy,d1
        bsr     Mul7
        move.w  sx,d1
        bsr     Mul7
        move.w  d0,d2
        move.w  cz,d0
        move.w  cx,d1
        bsr     Mul7
        add.w   d0,d2
        move.w  d2,8(a2)
; m12 = sz*sy*cx - cz*sx
        move.w  sz,d0
        move.w  sy,d1
        bsr     Mul7
        move.w  cx,d1
        bsr     Mul7
        move.w  d0,d2
        move.w  cz,d0
        move.w  sx,d1
        bsr     Mul7
        sub.w   d0,d2
        move.w  d2,10(a2)
; m20 = -sy
        move.w  sy,d0
        neg.w   d0
        move.w  d0,12(a2)
; m21 = cy*sx
        move.w  cy,d0
        move.w  sx,d1
        bsr     Mul7
        move.w  d0,14(a2)
; m22 = cy*cx
        move.w  cy,d0
        move.w  cx,d1
        bsr     Mul7
        move.w  d0,16(a2)
        rts

; in: a1 = vertices (x.w, y.w, z.w), d7 = count - 1, d6 = coordinate magnitude, a3 = output
; Vertex coordinates are 0 or +-d6 (cube +-42, octahedron +-28), so the rotation needs no
; multiplication per vertex: the nine products matrix * d6 are formed once and a vertex
; is the sum of +-columns. The result equals the full matrix product exactly. Then the
; perspective projection: screen = centre + r * WIRE_D / (z + wire_zoff) via a reciprocal
; table. a1 and a3 are left after the last vertex so objects can be chained.
; Clobbers d0-d6, a2, a4, a5.
TransformVerts:
        lea     mat,a2
        lea     tcol,a5
        moveq   #0,d0                      ; column
.col:
        move.w  0(a2),d1                   ; the three rows of column d0: mat[row*3+col]
        muls    d6,d1
        move.l  d1,0(a5)
        move.w  6(a2),d1
        muls    d6,d1
        move.l  d1,4(a5)
        move.w  12(a2),d1
        muls    d6,d1
        move.l  d1,8(a5)
        addq.l  #2,a2
        lea     12(a5),a5
        addq.w  #1,d0
        cmp.w   #3,d0
        blo     .col
        lea     recip_wire,a4
        lea     tcol,a5
.tv:
        moveq   #0,d3                      ; x'
        moveq   #0,d4                      ; y'
        moveq   #0,d5                      ; z'
        move.w  (a1)+,d0
        beq     .nx
        bmi     .mx
        add.l   0(a5),d3
        add.l   4(a5),d4
        add.l   8(a5),d5
        bra     .nx
.mx:
        sub.l   0(a5),d3
        sub.l   4(a5),d4
        sub.l   8(a5),d5
.nx:
        move.w  (a1)+,d0
        beq     .ny
        bmi     .my
        add.l   12(a5),d3
        add.l   16(a5),d4
        add.l   20(a5),d5
        bra     .ny
.my:
        sub.l   12(a5),d3
        sub.l   16(a5),d4
        sub.l   20(a5),d5
.ny:
        move.w  (a1)+,d0
        beq     .nz
        bmi     .mz
        add.l   24(a5),d3
        add.l   28(a5),d4
        add.l   32(a5),d5
        bra     .nz
.mz:
        sub.l   24(a5),d3
        sub.l   28(a5),d4
        sub.l   32(a5),d5
.nz:
        asr.l   #7,d3                      ; rotated x
        asr.l   #7,d4                      ; rotated y
        asr.l   #7,d5                      ; rotated z
        add.w   wire_zoff,d5               ; distance from the eye
        add.w   d5,d5
        move.w  0(a4,d5.w),d5              ; WIRE_D * 256 / distance
        muls    d5,d3
        asr.l   #8,d3
        add.w   wire_cx,d3
        muls    d5,d4
        asr.l   #8,d4
        addi.w  #MID_CY,d4
        move.w  d3,(a3)+
        move.w  d4,(a3)+
        dbra    d7,.tv
        rts

; Draw a line with the blitter in line mode (Hardware Reference Manual, "Line Mode").
; in: d0 = x1, d1 = y1, d2 = x2, d3 = y2, a0 = bitplane (40 bytes per row), a6 = CUSTOM
; The endpoints must be on the bitplane: there is no clipping. DrawWire presets the
; registers that never change between lines (A and B data, word masks, C/D modulo).
; Octant bits (BLTCON1 bits 4-2) come from the manual's table 6-3; dmaj/dmin are the
; larger/smaller of |dx|, |dy|; BLTAPT = 4*dmin - 2*dmaj, BLTAMOD = 4*(dmin-dmaj),
; BLTBMOD = 4*dmin; BLTSIZE = (dmaj+1 rows, 2 words). ONEDOT is left clear, which
; is what makes shallow lines solid (it is only for area-fill edges).
BlitLine:
        move.w  d1,d6
        lsl.w   #3,d6                      ; y*8
        move.w  d6,d7
        lsl.w   #2,d7                      ; y*32
        add.w   d7,d6                      ; y*40
        move.w  d0,d7
        lsr.w   #3,d7
        andi.w  #$FFFE,d7                  ; word containing the first pixel
        add.w   d7,d6
        lea     0(a0,d6.w),a1
        sub.w   d0,d2                      ; dx
        sub.w   d1,d3                      ; dy
        moveq   #0,d4                      ; bit 0: left, bit 1: up, bit 2: steep
        tst.w   d2
        bpl     .dxpos
        neg.w   d2
        addq.w  #1,d4
.dxpos:
        tst.w   d3
        bpl     .dypos
        neg.w   d3
        addq.w  #2,d4
.dypos:
        cmp.w   d2,d3
        bls     .shallow                   ; |dy| <= |dx|: x is the long axis
        exg     d2,d3                      ; d2 = dmaj, d3 = dmin
        addq.w  #4,d4
.shallow:
        lea     octants,a2
        move.b  0(a2,d4.w),d4              ; BLTCON1 octant bits + LINE
        move.w  d3,d5
        asl.w   #2,d5                      ; 4 * dmin
        move.w  d2,d7
        asl.w   #2,d7                      ; 4 * dmaj
        move.w  d7,d6
        asr.w   #1,d6                      ; 2 * dmaj
        neg.w   d6
        add.w   d5,d6                      ; 4*dmin - 2*dmaj
        bpl     .nosign
        ori.w   #$0040,d4                  ; SIGN
.nosign:
        move.w  d5,d1
        sub.w   d7,d1                      ; BLTAMOD = 4*(dmin - dmaj)
        andi.w  #15,d0
        ror.w   #4,d0                      ; A shift = x1 & 15, in bits 15-12
        ori.w   #$0BCA,d0                  ; use A, C, D; D = A*B + ~A*C
        addq.w  #1,d2
        lsl.w   #6,d2
        addq.w  #2,d2                      ; BLTSIZE
        ext.l   d6
        btst    #6,DMACONR(a6)
.bw:
        btst    #6,DMACONR(a6)
        bne     .bw
        move.w  d0,BLTCON0(a6)
        move.w  d4,BLTCON1(a6)
        move.l  d6,BLTAPTH(a6)
        move.w  d1,BLTAMOD(a6)
        move.w  d5,BLTBMOD(a6)
        move.l  a1,BLTCPTH(a6)
        move.l  a1,BLTDPTH(a6)
        move.w  d2,BLTSIZE(a6)
        rts

        include "modplayer.s"

        section data,data
old_dmacon:  dc.w 0
old_intena:  dc.w 0
old_adkcon:  dc.w 0
phase:       dc.w 0
scroll_div:  dc.b 0
glyph_col:   dc.b 0
        even
old_copper:  dc.l 0
old_view:    dc.l 0
gfx_base:    dc.l 0
chip_base:   dc.l 0
scroll_ptr:  dc.l scroll_text
rng_seed:    dc.w 1
r_stilt:     dc.w 0             ; ball ring: sin/cos of the tilt and roll, and the matrix coefficients
r_ctilt:     dc.w 0
r_sroll:     dc.w 0
r_croll:     dc.w 0
r_a:         dc.w 0
r_b:         dc.w 0
r_c:         dc.w 0
r_d:         dc.w 0
r_f:         dc.w 0
ball_zc:     ds.w NBALLS        ; per ball: distance, screen x, screen y
ball_sx:     ds.w NBALLS
ball_sy:     ds.w NBALLS
ball_order:  ds.w NBALLS        ; ball numbers, nearest first
frame_no:    dc.w 0
wire_cx:     dc.w MID_CX
wire_zoff:   dc.w WIRE_ZOFF
wire_front:  dc.w 0             ; index of the wireframe buffer being displayed
ang_x:       dc.w 0
ang_y:       dc.w 0
ang_z:       dc.w 0
sx:          dc.w 0             ; sin/cos of the current object's angles, scaled by 127
cx:          dc.w 0
sy:          dc.w 0
cy:          dc.w 0
sz:          dc.w 0
cz:          dc.w 0
mat:         ds.w 9             ; 3x3 rotation matrix, scaled by 128
tcol:        ds.l 9             ; matrix * vertex magnitude, by column
sec_zspeed:  dc.w 2
sec_spin:    dc.w 1
sec_cube:    dc.w CUBE_S
sec_octa:    dc.w OCTA_S
sec_inner:   dc.w INNER_S
sec_mask:    dc.w 7
sec_tab:
        dc.w 2,1,42,28,18,7            ; 0 intro: all three
        dc.w 2,1,42,28,18,1            ; 1 cube alone
        dc.w 7,1,42,28,34,4            ; 2 warp: fast stars, big inner cube
        dc.w 2,2,42,40,18,2            ; 3 big octahedron
        dc.w 3,1,42,28,18,7            ; 4 all three, quicker stars
        dc.w 2,2,42,36,30,6            ; 5 octahedron + inner cube
        dc.w 8,2,42,28,18,1            ; 6 warp: fastest stars, cube
        dc.w 3,2,42,28,18,7            ; 7 finale: all three, fast spin
proj:        ds.w 22*2          ; projected (x, y) of the 22 wireframe vertices
stars:       ds.b NSTARS*STAR_SIZE

; The twelve DMA visible labels as link-time addresses. AllocChipMem rewrites
; every long word in place, so ptr_* slots hold runtime chip RAM addresses.
        even
reloc_table:
        dc.l screen,logo_data,font_data,audio_silence,mod_data,copper,cop_bpl1,cop_raster_color
        dc.l cop_wave,cop_bars,sprites,cop_spr
RELOC_COUNT     EQU 12

gfx_name:    dc.b "graphics.library",0
        even

scroll_text:
        dc.b "   UBER CRACKING SERVICE PRESENTS - NEON VECTORS CRIMSON - COPPER FIRE AND ICE-COLD VECTORS. FOUR CHANNELS. EIGHT INSTRUMENTS. ONE AMIGA. - GREETINGS TO THE CODERS - PIXEL PUSHERS - TRACKER MUSICIANS - AND EVERYONE KEEPING THE RASTERS RACING. - LEFT MOUSE TO RETURN TO REALITY.   ",0
scroll_text_end:
        even

; Byte offset of each display row; used in the time-critical star loop.
row_offsets:
        dc.w 0,40,80,120,160,200,240,280,320,360,400,440,480,520,560,600
        dc.w 640,680,720,760,800,840,880,920,960,1000,1040,1080,1120,1160,1200,1240
        dc.w 1280,1320,1360,1400,1440,1480,1520,1560,1600,1640,1680,1720,1760,1800,1840,1880
        dc.w 1920,1960,2000,2040,2080,2120,2160,2200,2240,2280,2320,2360,2400,2440,2480,2520
        dc.w 2560,2600,2640,2680,2720,2760,2800,2840,2880,2920,2960,3000,3040,3080,3120,3160
        dc.w 3200,3240,3280,3320,3360,3400,3440,3480,3520,3560,3600,3640,3680,3720,3760,3800
        dc.w 3840,3880,3920,3960,4000,4040,4080,4120,4160,4200,4240,4280,4320,4360,4400,4440
        dc.w 4480,4520,4560,4600,4640,4680,4720,4760,4800,4840,4880,4920,4960,5000,5040,5080
        dc.w 5120,5160,5200,5240,5280,5320,5360,5400,5440,5480,5520,5560,5600,5640,5680,5720
        dc.w 5760,5800,5840,5880,5920,5960,6000,6040,6080,6120,6160,6200,6240,6280,6320,6360
        dc.w 6400,6440,6480,6520,6560,6600,6640,6680,6720,6760,6800,6840,6880,6920,6960,7000
        dc.w 7040,7080,7120,7160,7200,7240,7280,7320,7360,7400,7440,7480,7520,7560,7600,7640
        dc.w 7680,7720,7760,7800,7840,7880,7920,7960,8000,8040,8080,8120,8160,8200,8240,8280
        dc.w 8320,8360,8400,8440,8480,8520,8560,8600,8640,8680,8720,8760,8800,8840,8880,8920
        dc.w 8960,9000,9040,9080,9120,9160,9200,9240,9280,9320,9360,9400,9440,9480,9520,9560
        dc.w 9600,9640,9680,9720,9760,9800,9840,9880,9920,9960,10000,10040,10080,10120,10160,10200

raster_colors:
        dc.w $210,$210,$310,$410,$521,$721,$921,$B32,$C43,$D64,$E95,$FB7,$FCA,$FDC,$FEE,$FFF
        dc.w $FFF,$FFF,$FEE,$FDC,$FCA,$FB7,$E95,$D64,$D43,$B32,$921,$721,$521,$410,$310,$210

; BLTCON1 octant bits and LINE for index (steep*4 + up*2 + left); manual table 6-3.
octants:
        dc.b $11,$15,$19,$1D       ; shallow: right/down, left/down, right/up, left/up
        dc.b $01,$09,$05,$0D       ; steep:   right/down, left/down, right/up, left/up

; Wireframe model. Vertices 0..7: a cube of half-size 42 (bit 0 = x, bit 1 = y,
; bit 2 = z of the index). Vertices 8..13: an octahedron of radius 28.
verts:
        dc.w -42,-42,-42,  42,-42,-42, -42, 42,-42,  42, 42,-42
        dc.w -42,-42, 42,  42,-42, 42, -42, 42, 42,  42, 42, 42
        dc.w  28,  0,  0, -28,  0,  0,   0, 28,  0,   0,-28,  0
        dc.w   0,  0, 28,   0,  0,-28
edges:
        dc.b 0,1, 2,3, 4,5, 6,7        ; cube: along x
        dc.b 0,2, 1,3, 4,6, 5,7        ;       along y
        dc.b 0,4, 1,5, 2,6, 3,7        ;       along z
        dc.b 8,10, 8,11, 8,12, 8,13    ; octahedron
        dc.b 9,10, 9,11, 9,12, 9,13
        dc.b 10,12, 10,13, 11,12, 11,13
        dc.b 14,15, 16,17, 18,19, 20,21 ; inner cube: along x
        dc.b 14,16, 15,17, 18,20, 19,21 ;              along y
        dc.b 14,18, 15,19, 16,20, 17,21 ;              along z
edges_end:

; (x0, z0) of the ball ring for every angle (tools/gen_tables.py ring_tab).
ring_tab:
        dc.w 69,0,69,1,69,3,69,4,68,6,68,8,68,10,68,12
        dc.w 68,13,67,15,67,16,66,18,66,20,66,21,65,23,64,25
        dc.w 63,26,63,27,62,29,61,31,61,32,60,34,59,35,58,37
        dc.w 57,38,56,39,55,41,54,42,53,44,52,45,51,46,50,48
        dc.w 49,49,48,50,46,51,45,52,44,53,42,54,41,55,39,56
        dc.w 38,57,37,58,35,59,34,60,32,61,31,61,29,62,27,63
        dc.w 26,63,25,64,23,65,21,66,20,66,18,66,16,67,15,67
        dc.w 13,68,12,68,10,68,8,68,6,68,4,69,3,69,1,69
        dc.w 0,69,-2,69,-4,69,-5,69,-7,68,-9,68,-11,68,-13,68
        dc.w -14,68,-16,67,-17,67,-19,66,-21,66,-22,66,-24,65,-26,64
        dc.w -27,63,-28,63,-30,62,-32,61,-33,61,-35,60,-36,59,-38,58
        dc.w -39,57,-40,56,-42,55,-43,54,-45,53,-46,52,-47,51,-49,50
        dc.w -50,49,-51,48,-52,46,-53,45,-54,44,-55,42,-56,41,-57,39
        dc.w -58,38,-59,37,-60,35,-61,34,-62,32,-62,31,-63,29,-64,27
        dc.w -64,26,-65,25,-66,23,-67,21,-67,20,-67,18,-68,16,-68,15
        dc.w -69,13,-69,12,-69,10,-69,8,-69,6,-70,4,-70,3,-70,1
        dc.w -70,0,-70,-2,-70,-4,-70,-5,-69,-7,-69,-9,-69,-11,-69,-13
        dc.w -69,-14,-68,-16,-68,-17,-67,-19,-67,-21,-67,-22,-66,-24,-65,-26
        dc.w -64,-27,-64,-28,-63,-30,-62,-32,-62,-33,-61,-35,-60,-36,-59,-38
        dc.w -58,-39,-57,-40,-56,-42,-55,-43,-54,-45,-53,-46,-52,-47,-51,-49
        dc.w -50,-50,-49,-51,-47,-52,-46,-53,-45,-54,-43,-55,-42,-56,-40,-57
        dc.w -39,-58,-38,-59,-36,-60,-35,-61,-33,-62,-32,-62,-30,-63,-28,-64
        dc.w -27,-64,-26,-65,-24,-66,-22,-67,-21,-67,-19,-67,-17,-68,-16,-68
        dc.w -14,-69,-13,-69,-11,-69,-9,-69,-7,-69,-5,-70,-4,-70,-2,-70
        dc.w 0,-70,1,-70,3,-70,4,-70,6,-69,8,-69,10,-69,12,-69
        dc.w 13,-69,15,-68,16,-68,18,-67,20,-67,21,-67,23,-66,25,-65
        dc.w 26,-64,27,-64,29,-63,31,-62,32,-62,34,-61,35,-60,37,-59
        dc.w 38,-58,39,-57,41,-56,42,-55,44,-54,45,-53,46,-52,48,-51
        dc.w 49,-50,50,-49,51,-47,52,-46,53,-45,54,-43,55,-42,56,-40
        dc.w 57,-39,58,-38,59,-36,60,-35,61,-33,61,-32,62,-30,63,-28
        dc.w 63,-27,64,-26,65,-24,66,-22,66,-21,66,-19,67,-17,67,-16
        dc.w 68,-14,68,-13,68,-11,68,-9,68,-7,69,-5,69,-4,69,-2

; Hardware sprite balls: 16, 12 and 8 line bitmaps (planes A, B per line), tools/gen_tables.py balls.
ball_bitmaps:
        dc.w $700,$7E0,$1F88,$1FF0,$3F84,$3FF8,$7F86,$7FF8
        dc.w $7F86,$7FF8,$7F07,$FFF8,$7E0F,$FFF0,$7C1F,$FFE0
        dc.w $01F,$FFE0,$03F,$FFC0,$80FF,$7F00,$3FE,$7C00
        dc.w $7FFE,$000,$3FFC,$000,$1FF8,$000,$7E0,$000
        dc.w $300,$3C0,$F90,$FE0,$1F88,$1FF0,$1F08,$1FF0
        dc.w $3F1C,$3FE0,$1C1C,$3FE0,$03C,$3FC0,$07C,$3F80
        dc.w $1F8,$1E00,$1FF8,$000,$FF0,$000,$3C0,$000
        dc.w $300,$3C0,$7A0,$7C0,$F30,$FC0,$E30,$FC0
        dc.w $070,$F80,$0F0,$F00,$7E0,$000,$3C0,$000

; Wavy logo values (tools/gen_tables.py wave_tab).
wave_tab:
        dc.w $088,$088,$088,$099,$099,$099,$099,$099,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0BB,$0BB
        dc.w $0BB,$0BB,$0BB,$0BB,$0CC,$0CC,$0CC,$0CC,$0CC,$0CC,$0CC,$0CC,$0CC,$0DD,$0DD,$0DD
        dc.w $0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD
        dc.w $0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0CC,$0CC,$0CC,$0CC,$0CC
        dc.w $0CC,$0CC,$0CC,$0CC,$0CC,$0BB,$0BB,$0BB,$0BB,$0BB,$0BB,$0BB,$0BB,$0BB,$0AA,$0AA
        dc.w $0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$099,$099,$099,$099,$099,$099,$099,$099
        dc.w $099,$099,$099,$099,$099,$099,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088
        dc.w $088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088
        dc.w $088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088
        dc.w $088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$077,$077,$077,$077,$077
        dc.w $077,$077,$077,$077,$077,$077,$077,$077,$077,$066,$066,$066,$066,$066,$066,$066
        dc.w $066,$066,$066,$055,$055,$055,$055,$055,$055,$055,$055,$055,$044,$044,$044,$044
        dc.w $044,$044,$044,$044,$044,$044,$033,$033,$033,$033,$033,$033,$033,$033,$033,$033
        dc.w $033,$033,$033,$033,$033,$033,$033,$033,$033,$033,$033,$033,$033,$033,$033,$033
        dc.w $033,$033,$033,$033,$044,$044,$044,$044,$044,$044,$044,$044,$044,$055,$055,$055
        dc.w $055,$055,$055,$066,$066,$066,$066,$066,$066,$077,$077,$077,$077,$077,$088,$088

; Copper-bar floor: the static ramp and the 4 bars x 8 rows of colour (tools/gen_tables.py).
bar_motion:
        dc.w $00D,$00D,$00D,$00D,$00E,$00E,$00E,$00F,$00F,$00F,$010,$010,$010,$011,$011,$011
        dc.w $011,$012,$012,$012,$013,$013,$013,$013,$014,$014,$014,$014,$015,$015,$015,$015
        dc.w $016,$016,$016,$016,$016,$017,$017,$017,$017,$017,$018,$018,$018,$018,$018,$018
        dc.w $018,$018,$019,$019,$019,$019,$019,$019,$019,$019,$019,$019,$019,$019,$019,$019
        dc.w $019,$019,$019,$019,$019,$019,$019,$019,$019,$019,$019,$019,$019,$019,$019,$018
        dc.w $018,$018,$018,$018,$018,$018,$018,$017,$017,$017,$017,$017,$016,$016,$016,$016
        dc.w $016,$015,$015,$015,$015,$014,$014,$014,$014,$013,$013,$013,$013,$012,$012,$012
        dc.w $011,$011,$011,$011,$010,$010,$010,$00F,$00F,$00F,$00E,$00E,$00E,$00D,$00D,$00D
        dc.w $00D,$00C,$00C,$00C,$00B,$00B,$00B,$00A,$00A,$00A,$009,$009,$009,$008,$008,$008
        dc.w $008,$007,$007,$007,$006,$006,$006,$006,$005,$005,$005,$005,$004,$004,$004,$004
        dc.w $003,$003,$003,$003,$003,$002,$002,$002,$002,$002,$001,$001,$001,$001,$001,$001
        dc.w $001,$001,$000,$000,$000,$000,$000,$000,$000,$000,$000,$000,$000,$000,$000,$000
        dc.w $000,$000,$000,$000,$000,$000,$000,$000,$000,$000,$000,$000,$000,$000,$000,$001
        dc.w $001,$001,$001,$001,$001,$001,$001,$002,$002,$002,$002,$002,$003,$003,$003,$003
        dc.w $003,$004,$004,$004,$004,$005,$005,$005,$005,$006,$006,$006,$006,$007,$007,$007
        dc.w $008,$008,$008,$008,$009,$009,$009,$00A,$00A,$00A,$00B,$00B,$00B,$00C,$00C,$00C

floor_base:
        dc.w $100,$100,$100,$100,$100,$100,$100,$100,$100,$100,$211,$211,$211,$211,$211,$211
        dc.w $211,$211,$211,$211,$211,$311,$311,$311,$311,$311,$411,$411,$411,$411,$411,$511
        dc.w $511,$511
bar_colors:
        dc.w $401,$812,$B44,$F77,$F77,$B44,$812,$401
        dc.w $421,$842,$B74,$FB7,$FB7,$B74,$842,$421
        dc.w $432,$862,$BB4,$FE8,$FE8,$BB4,$862,$432
        dc.w $413,$826,$B49,$F8C,$F8C,$B49,$826,$413

; Reciprocals that replace divisions in the inner loops (tools/gen_tables.py):
; recip_star[z] = round(PROJ_F*256/z), recip_wire[zc] = round(WIRE_D*256/zc), so
; screen offset = (coordinate * recip) >> 8. One MULS is cheaper than one DIVS.
recip_star:
        dc.w 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        dc.w 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        dc.w 1024,993,964,936,910,886,862,840,819,799,780,762,745,728,712,697
        dc.w 683,669,655,643,630,618,607,596,585,575,565,555,546,537,529,520
        dc.w 512,504,496,489,482,475,468,462,455,449,443,437,431,426,420,415
        dc.w 410,405,400,395,390,386,381,377,372,368,364,360,356,352,349,345
        dc.w 341,338,334,331,328,324,321,318,315,312,309,306,303,301,298,295
        dc.w 293,290,287,285,282,280,278,275,273,271,269,266,264,262,260,258
        dc.w 256,254,252,250,248,246,245,243,241,239,237,236,234,232,231,229
        dc.w 228,226,224,223,221,220,218,217,216,214,213,211,210,209,207,206
        dc.w 205,204,202,201,200,199,197,196,195,194,193,192,191,189,188,187
        dc.w 186,185,184,183,182,181,180,179,178,177,176,175,174,173,172,172
        dc.w 171,170,169,168,167,166,165,165,164,163,162,161,161,160,159,158
        dc.w 158,157,156,155,155,154,153,152,152,151,150,150,149,148,148,147
        dc.w 146,146,145,144,144,143,142,142,141,141,140,139,139,138,138,137
        dc.w 137,136,135,135,134,134,133,133,132,132,131,131,130,130,129,129
recip_wire:
        dc.w 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        dc.w 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        dc.w 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        dc.w 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        dc.w 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        dc.w 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        dc.w 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        dc.w 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        dc.w 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        dc.w 0,0,0,0,0,0,375,373,371,368,366,363,361,359,356,354
        dc.w 352,350,348,346,343,341,339,337,335,333,331,329,327,326,324,322
        dc.w 320,318,316,315,313,311,309,308,306,304,303,301,300,298,296,295
        dc.w 293,292,290,289,287,286,284,283,282,280,279,277,276,275,273,272
        dc.w 271,269,268,267,266,264,263,262,261,260,258,257,256,255,254,253
        dc.w 251,250,249,248,247,246,245,244,243,242,241,240,239,238,237,236
        dc.w 235,234,233,232,231,230,229,228,227,226,225,224,223,223,222,221
        dc.w 220,219,218,217,217,216,215,214,213,213,212,211,210,209,209,208
        dc.w 207,206,206,205,204,203,203,202,201,200,200,199,198,198,197,196
        dc.w 196,195,194,194,193,192,192,191,190,190,189,188,188,187,186,186
        dc.w 185,185,184,183,183,182,182,181,181,180,179,179,178,178,177,177
        dc.w 176,175,175,174,174,173,173,172,172,171,171,170,170,169,169,168
        dc.w 168,167,167,166,166,165,165,164,164,163,163,162,162,161,161,160
        dc.w 160,160,159,159,158,158,157,157,156,156,156,155,155,154,154,153
        dc.w 153,153,152,152,151,151,151,150,150,149,149,149,148,148,147,147
        dc.w 147,146,146,146,145,145,144,144,144,143,143,143,142,142,142,141
        dc.w 141,140,140,140,139,139,139,138,138,138,137,137,137,136,136,136

; 256 entries, one turn, amplitude 127 (tools/gen_tables.py sintab).
sintab:
        dc.w 0,3,6,9,12,16,19,22,25,28,31,34,37,40,43,46
        dc.w 49,51,54,57,60,63,65,68,71,73,76,78,81,83,85,88
        dc.w 90,92,94,96,98,100,102,104,106,107,109,111,112,113,115,116
        dc.w 117,118,120,121,122,122,123,124,125,125,126,126,126,127,127,127
        dc.w 127,127,127,127,126,126,126,125,125,124,123,122,122,121,120,118
        dc.w 117,116,115,113,112,111,109,107,106,104,102,100,98,96,94,92
        dc.w 90,88,85,83,81,78,76,73,71,68,65,63,60,57,54,51
        dc.w 49,46,43,40,37,34,31,28,25,22,19,16,12,9,6,3
        dc.w 0,-3,-6,-9,-12,-16,-19,-22,-25,-28,-31,-34,-37,-40,-43,-46
        dc.w -49,-51,-54,-57,-60,-63,-65,-68,-71,-73,-76,-78,-81,-83,-85,-88
        dc.w -90,-92,-94,-96,-98,-100,-102,-104,-106,-107,-109,-111,-112,-113,-115,-116
        dc.w -117,-118,-120,-121,-122,-122,-123,-124,-125,-125,-126,-126,-126,-127,-127,-127
        dc.w -127,-127,-127,-127,-126,-126,-126,-125,-125,-124,-123,-122,-122,-121,-120,-118
        dc.w -117,-116,-115,-113,-112,-111,-109,-107,-106,-104,-102,-100,-98,-96,-94,-92
        dc.w -90,-88,-85,-83,-81,-78,-76,-73,-71,-68,-65,-63,-60,-57,-54,-51
        dc.w -49,-46,-43,-40,-37,-34,-31,-28,-25,-22,-19,-16,-12,-9,-6,-3
        even

; ---------------------------------------------------------------------------
; All DMA visible payloads. The block is copied into freshly allocated chip
; RAM at run time, so the loader may place it anywhere without breaking the
; Copper, the bitplanes, the Paula samples or the silent terminal word.
;
; Copper WAIT is a two word instruction: word one is the beam position with
; bit0 set, word two is the comparison mask with bit0 clear and bit15 set for
; blitter finished. $xx01,$FFFE therefore waits for vertical position $xx with
; every vertical and horizontal bit compared, and $FFFF,$FFFE never matches,
; which parks the list until the next vertical blank reloads COP1LC.
; ---------------------------------------------------------------------------
        section chipdata,data_c
        cnop 0,4
chipdata_begin:
copper:
        dc.w DIWSTRT,$2C81,DIWSTOP,$2CC1
        dc.w DDFSTRT,$0030,DDFSTOP,$00D0   ; one extra word per line (BPLCON1 scroll), see BPLxMOD
        dc.w BPLCON0,$4200,BPLCON1,$0000,BPLCON2,$0010   ; single playfield uses PF2P bits 5..3; 4 bitplanes; sprites 4-7 (the far balls) go behind the playfield
        dc.w BPL1MOD,$FFFE,BPL2MOD,$FFFE   ; 21 words fetched, 20 words per line: step back 2 bytes
cop_bpl1:
        dc.w BPL1PTH,0,BPL1PTL,0
        dc.w BPL2PTH,0,BPL2PTL,0
        dc.w BPL3PTH,0,BPL3PTL,0
        dc.w BPL4PTH,0,BPL4PTL,0
; The logo's 16 colour palette (tools/gen_tables.py palette); the Copper reloads a
; different palette below the logo for the stars and objects.
        dc.w COLOR00,$001,COLOR01,$100,COLOR02,$631,COLOR03,$963
        dc.w COLOR04,$FC4,COLOR05,$FE9,COLOR06,$FFC,COLOR07,$FFF
        dc.w COLOR08,$422,COLOR09,$211,COLOR10,$624,COLOR11,$A46
        dc.w COLOR12,$E79,COLOR13,$FCD,COLOR14,$D42,COLOR15,$FFF
; Hardware sprites: eight pointer pairs (the Copper reloads them every frame; PatchSprites
; fills in the runtime addresses once) and the colours of the four sprite pairs.
cop_spr:
        dc.w SPR0PTH,0,SPR0PTL,0
        dc.w SPR1PTH,0,SPR1PTL,0
        dc.w SPR2PTH,0,SPR2PTL,0
        dc.w SPR3PTH,0,SPR3PTL,0
        dc.w SPR4PTH,0,SPR4PTL,0
        dc.w SPR5PTH,0,SPR5PTL,0
        dc.w SPR6PTH,0,SPR6PTL,0
        dc.w SPR7PTH,0,SPR7PTL,0
        dc.w COLOR17,$A50,COLOR18,$FB3,COLOR19,$FFD,COLOR21,$711
        dc.w COLOR22,$D43,COLOR23,$FC9,COLOR25,$146,COLOR26,$4AF
        dc.w COLOR27,$CEF,COLOR29,$113,COLOR30,$35A,COLOR31,$8BE

; Colour work per raster line (tools/gen_tables.py copper). In the logo band COLOR00 and
; COLOR04 get a gradient on every row; below it the palette is reloaded: COLOR01 is the
; mid-distance star, COLOR04/05 the far and near stars, and any index with bitplane 1 or 3
; set belongs to the 3D objects, so an object always hides the stars behind it.
cop_wave:                                   ; 64 rows, 16 bytes each (BPLCON1 value at +14)
        dc.w $3401,$FFFE,COLOR00,$0001,COLOR04,$0FFF,BPLCON1,$0088
        dc.w $3501,$FFFE,COLOR00,$0001,COLOR04,$0FFF,BPLCON1,$0088
        dc.w $3601,$FFFE,COLOR00,$0001,COLOR04,$0FFF,BPLCON1,$0088
        dc.w $3701,$FFFE,COLOR00,$0001,COLOR04,$0FFF,BPLCON1,$0088
        dc.w $3801,$FFFE,COLOR00,$0001,COLOR04,$0FFF,BPLCON1,$0088
        dc.w $3901,$FFFE,COLOR00,$0001,COLOR04,$0FFF,BPLCON1,$0088
        dc.w $3A01,$FFFE,COLOR00,$0001,COLOR04,$0FFE,BPLCON1,$0088
        dc.w $3B01,$FFFE,COLOR00,$0001,COLOR04,$0FFE,BPLCON1,$0088
        dc.w $3C01,$FFFE,COLOR00,$0001,COLOR04,$0FFE,BPLCON1,$0088
        dc.w $3D01,$FFFE,COLOR00,$0001,COLOR04,$0FED,BPLCON1,$0088
        dc.w $3E01,$FFFE,COLOR00,$0001,COLOR04,$0FED,BPLCON1,$0088
        dc.w $3F01,$FFFE,COLOR00,$0001,COLOR04,$0FED,BPLCON1,$0088
        dc.w $4001,$FFFE,COLOR00,$0001,COLOR04,$0FEC,BPLCON1,$0088
        dc.w $4101,$FFFE,COLOR00,$0001,COLOR04,$0FEC,BPLCON1,$0088
        dc.w $4201,$FFFE,COLOR00,$0001,COLOR04,$0FEB,BPLCON1,$0088
        dc.w $4301,$FFFE,COLOR00,$0001,COLOR04,$0FDB,BPLCON1,$0088
        dc.w $4401,$FFFE,COLOR00,$0101,COLOR04,$0FDA,BPLCON1,$0088
        dc.w $4501,$FFFE,COLOR00,$0101,COLOR04,$0FDA,BPLCON1,$0088
        dc.w $4601,$FFFE,COLOR00,$0101,COLOR04,$0FD9,BPLCON1,$0088
        dc.w $4701,$FFFE,COLOR00,$0101,COLOR04,$0FC9,BPLCON1,$0088
        dc.w $4801,$FFFE,COLOR00,$0101,COLOR04,$0FC8,BPLCON1,$0088
        dc.w $4901,$FFFE,COLOR00,$0101,COLOR04,$0FC8,BPLCON1,$0088
        dc.w $4A01,$FFFE,COLOR00,$0101,COLOR04,$0FC7,BPLCON1,$0088
        dc.w $4B01,$FFFE,COLOR00,$0101,COLOR04,$0FB6,BPLCON1,$0088
        dc.w $4C01,$FFFE,COLOR00,$0101,COLOR04,$0FB6,BPLCON1,$0088
        dc.w $4D01,$FFFE,COLOR00,$0101,COLOR04,$0FA6,BPLCON1,$0088
        dc.w $4E01,$FFFE,COLOR00,$0101,COLOR04,$0FA6,BPLCON1,$0088
        dc.w $4F01,$FFFE,COLOR00,$0101,COLOR04,$0EA5,BPLCON1,$0088
        dc.w $5001,$FFFE,COLOR00,$0101,COLOR04,$0E95,BPLCON1,$0088
        dc.w $5101,$FFFE,COLOR00,$0101,COLOR04,$0E95,BPLCON1,$0088
        dc.w $5201,$FFFE,COLOR00,$0101,COLOR04,$0E85,BPLCON1,$0088
        dc.w $5301,$FFFE,COLOR00,$0101,COLOR04,$0E85,BPLCON1,$0088
        dc.w $5401,$FFFE,COLOR00,$0111,COLOR04,$0D74,BPLCON1,$0088
        dc.w $5501,$FFFE,COLOR00,$0111,COLOR04,$0D74,BPLCON1,$0088
        dc.w $5601,$FFFE,COLOR00,$0111,COLOR04,$0D74,BPLCON1,$0088
        dc.w $5701,$FFFE,COLOR00,$0111,COLOR04,$0D64,BPLCON1,$0088
        dc.w $5801,$FFFE,COLOR00,$0111,COLOR04,$0D64,BPLCON1,$0088
        dc.w $5901,$FFFE,COLOR00,$0111,COLOR04,$0D54,BPLCON1,$0088
        dc.w $5A01,$FFFE,COLOR00,$0111,COLOR04,$0C53,BPLCON1,$0088
        dc.w $5B01,$FFFE,COLOR00,$0111,COLOR04,$0C43,BPLCON1,$0088
        dc.w $5C01,$FFFE,COLOR00,$0111,COLOR04,$0C43,BPLCON1,$0088
        dc.w $5D01,$FFFE,COLOR00,$0111,COLOR04,$0C43,BPLCON1,$0088
        dc.w $5E01,$FFFE,COLOR00,$0111,COLOR04,$0C43,BPLCON1,$0088
        dc.w $5F01,$FFFE,COLOR00,$0111,COLOR04,$0C43,BPLCON1,$0088
        dc.w $6001,$FFFE,COLOR00,$0111,COLOR04,$0C43,BPLCON1,$0088
        dc.w $6101,$FFFE,COLOR00,$0111,COLOR04,$0C43,BPLCON1,$0088
        dc.w $6201,$FFFE,COLOR00,$0111,COLOR04,$0C43,BPLCON1,$0088
        dc.w $6301,$FFFE,COLOR00,$0111,COLOR04,$0C43,BPLCON1,$0088
        dc.w $6401,$FFFE,COLOR00,$0211,COLOR04,$0C43,BPLCON1,$0088
        dc.w $6501,$FFFE,COLOR00,$0211,COLOR04,$0C43,BPLCON1,$0088
        dc.w $6601,$FFFE,COLOR00,$0211,COLOR04,$0C43,BPLCON1,$0088
        dc.w $6701,$FFFE,COLOR00,$0211,COLOR04,$0C43,BPLCON1,$0088
        dc.w $6801,$FFFE,COLOR00,$0211,COLOR04,$0C43,BPLCON1,$0088
        dc.w $6901,$FFFE,COLOR00,$0211,COLOR04,$0C43,BPLCON1,$0088
        dc.w $6A01,$FFFE,COLOR00,$0211,COLOR04,$0C43,BPLCON1,$0088
        dc.w $6B01,$FFFE,COLOR00,$0211,COLOR04,$0C43,BPLCON1,$0088
        dc.w $6C01,$FFFE,COLOR00,$0211,COLOR04,$0C43,BPLCON1,$0088
        dc.w $6D01,$FFFE,COLOR00,$0211,COLOR04,$0C43,BPLCON1,$0088
        dc.w $6E01,$FFFE,COLOR00,$0211,COLOR04,$0C43,BPLCON1,$0088
        dc.w $6F01,$FFFE,COLOR00,$0211,COLOR04,$0C43,BPLCON1,$0088
        dc.w $7001,$FFFE,COLOR00,$0211,COLOR04,$0C43,BPLCON1,$0088
        dc.w $7101,$FFFE,COLOR00,$0211,COLOR04,$0C43,BPLCON1,$0088
        dc.w $7201,$FFFE,COLOR00,$0211,COLOR04,$0C43,BPLCON1,$0088
        dc.w $7301,$FFFE,COLOR00,$0211,COLOR04,$0C43,BPLCON1,$0088
        dc.w $7401,$FFFE                    ; y=72: animated slot, then the wave ends
cop_raster_color:
        dc.w COLOR00,$013                   ; animated by UpdateRaster each frame
        dc.w BPLCON1,$0000
        dc.w COLOR01,$89A,COLOR02,$6DF,COLOR03,$6DF,COLOR04,$456
        dc.w COLOR05,$DDE,COLOR06,$6DF,COLOR07,$6DF,COLOR08,$57B
        dc.w COLOR09,$57B,COLOR10,$BDF,COLOR11,$BDF,COLOR12,$57B
        dc.w COLOR13,$57B,COLOR14,$BDF,COLOR15,$BDF
        dc.w $7801,$FFFE,COLOR00,$0001,COLOR01,$089A
        dc.w $8001,$FFFE,COLOR00,$0001
        dc.w $8801,$FFFE,COLOR00,$0001
        dc.w $9001,$FFFE,COLOR00,$0001
        dc.w $9801,$FFFE,COLOR00,$0012
        dc.w $A001,$FFFE,COLOR00,$0012
        dc.w $A801,$FFFE,COLOR00,$0012
        dc.w $B001,$FFFE,COLOR00,$0012
        dc.w $B801,$FFFE,COLOR00,$0012
        dc.w $C001,$FFFE,COLOR00,$0012
        dc.w $C801,$FFFE,COLOR00,$0012
        dc.w $D001,$FFFE,COLOR00,$0001
        dc.w $D801,$FFFE,COLOR00,$0001
        dc.w $E001,$FFFE,COLOR00,$0001
        dc.w $E801,$FFFE,COLOR00,$0001
        dc.w $F001,$FFFE,COLOR00,$0001
        dc.w $F101,$FFFE,COLOR00,$0B43
        dc.w $F201,$FFFE,COLOR00,$0211
        dc.w $F401,$FFFE,COLOR01,$0FC9
        dc.w $F601,$FFFE,COLOR01,$0FDB
        dc.w $F801,$FFFE,COLOR01,$0FEC
        dc.w $FA01,$FFFE,COLOR01,$0FFE
        dc.w $FC01,$FFFE,COLOR01,$0FEE
        dc.w $FE01,$FFFE,COLOR01,$0ECB
        dc.w $FFDF,$FFFE                    ; wrap: lines below are 256 + WAIT line
        dc.w $0001,$FFFE,COLOR01,$0E98
        dc.w $0201,$FFFE,COLOR01,$0D75
        dc.w $0601,$FFFE,COLOR00,$0B43
        dc.w $0701,$FFFE,COLOR00,$0001
cop_bars:                                   ; 34 rows of WAIT + COLOR00, 8 bytes each (value at +6)
        dc.w $0A01,$FFFE,COLOR00,$0100
        dc.w $0B01,$FFFE,COLOR00,$0100
        dc.w $0C01,$FFFE,COLOR00,$0100
        dc.w $0D01,$FFFE,COLOR00,$0100
        dc.w $0E01,$FFFE,COLOR00,$0100
        dc.w $0F01,$FFFE,COLOR00,$0100
        dc.w $1001,$FFFE,COLOR00,$0100
        dc.w $1101,$FFFE,COLOR00,$0100
        dc.w $1201,$FFFE,COLOR00,$0100
        dc.w $1301,$FFFE,COLOR00,$0100
        dc.w $1401,$FFFE,COLOR00,$0211
        dc.w $1501,$FFFE,COLOR00,$0211
        dc.w $1601,$FFFE,COLOR00,$0211
        dc.w $1701,$FFFE,COLOR00,$0211
        dc.w $1801,$FFFE,COLOR00,$0211
        dc.w $1901,$FFFE,COLOR00,$0211
        dc.w $1A01,$FFFE,COLOR00,$0211
        dc.w $1B01,$FFFE,COLOR00,$0211
        dc.w $1C01,$FFFE,COLOR00,$0211
        dc.w $1D01,$FFFE,COLOR00,$0211
        dc.w $1E01,$FFFE,COLOR00,$0211
        dc.w $1F01,$FFFE,COLOR00,$0311
        dc.w $2001,$FFFE,COLOR00,$0311
        dc.w $2101,$FFFE,COLOR00,$0311
        dc.w $2201,$FFFE,COLOR00,$0311
        dc.w $2301,$FFFE,COLOR00,$0311
        dc.w $2401,$FFFE,COLOR00,$0411
        dc.w $2501,$FFFE,COLOR00,$0411
        dc.w $2601,$FFFE,COLOR00,$0411
        dc.w $2701,$FFFE,COLOR00,$0411
        dc.w $2801,$FFFE,COLOR00,$0411
        dc.w $2901,$FFFE,COLOR00,$0511
        dc.w $2A01,$FFFE,COLOR00,$0511
        dc.w $2B01,$FFFE,COLOR00,$0511
        dc.w $FFFF,$FFFE

        cnop 0,4
sprites:    ds.b SPR_BYTES*SPR_PAGES    ; prebuilt sprite pages: per sprite one for each ball size
        cnop 0,4
        dc.l 0                      ; the word fetched left of line 0 (planes start 2 bytes early)
screen:     ds.b PLANE_SIZE*6   ; plane 0 | plane 1 buffers 0,1 | plane 2 | plane 3 buffers 0,1
logo_data:  incbin "assets/logo.raw"
font_data:  incbin "assets/font.raw"
        even
audio_silence: dc.w SILENCE_WORD  ; signed 8-bit silence
mod_data:   incbin "assets/neon.mod"
        even
chipdata_end:
