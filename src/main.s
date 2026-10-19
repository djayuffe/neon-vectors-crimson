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
        bsr     UpdateAurora
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
        move.w  frame_no,d1
        lsr.w   #8,d1
        andi.w  #7,d1
        lsl.w   #8,d1
        add.w   d1,d1                     ; 512 bytes per scene, ordinary RAM
        adda.w  d1,a2
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
        move.w  frame_no,d0
        lsr.w   #8,d0
        andi.w  #7,d0
        lsl.w   #8,d0                      ; 256 bytes per scene
        adda.w  d0,a3
        move.w  visual_pulse,d0
        lsr.w   #2,d0                      ; 15-frame envelope -> four light levels
        lsl.w   #6,d0                      ; 64 bytes per brightness bank
        adda.w  d0,a3
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

; Reuse the fifteen existing middle-band COLOR00 slots as an interference curtain.
; Only colour words change: no extra Copper instructions or display planes.
UpdateAurora:
        lea     aurora_colors,a2
        move.w  frame_no,d0
        move.w  d0,d1
        lsr.w   #8,d1
        andi.w  #7,d1
        lsl.w   #8,d1
        add.w   d1,d1
        adda.w  d1,a2
        andi.w  #510,d0                    ; one colour step per two frames
        move.l  ptr_raster,a1
        lea     cop_aurora-cop_raster_color(a1),a1
        move.w  0(a2,d0.w),6(a1)
        lea     12(a1),a1                 ; first band also reloads COLOR01
        moveq   #13,d7
.band:
        addi.w  #26,d0                    ; thirteen phase steps per band
        andi.w  #510,d0
        move.w  0(a2,d0.w),6(a1)
        addq.l  #8,a1
        dbra    d7,.band
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
        add.w   sec_tilt,d1
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
        lea     ring_tab,a4
        move.w  frame_no,d0
        lsr.w   #8,d0
        andi.w  #7,d0
        lsl.w   #8,d0
        lsl.w   #2,d0                     ; 1024 bytes per closed orbit
        adda.w  d0,a4
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
        move.l  a4,a0
        move.w  0(a0,d0.w),d2              ; x0 from the scene curve
        move.w  2(a0,d0.w),d1              ; z0 from the scene curve
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
        tst.w   visual_pulse
        beq     .no_pulse
        subq.w  #1,visual_pulse
.no_pulse:
        move.w  frame_no,d0
        lsr.w   #8,d0
        andi.w  #7,d0
        move.w  d0,d1
        add.w   d1,d1
        lea     ring_tilts,a1
        move.w  0(a1,d1.w),sec_tilt
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
visual_pulse: dc.w 0            ; actual MOD onsets drive a short light envelope
sec_tilt:    dc.w RING_TILT
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
ring_tilts: dc.w 40,24,56,44,32,64,20,48
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

aurora_colors:
        dc.w $101,$111,$111,$111,$111,$111,$111,$111,$111,$111,$111,$211,$211,$211,$211,$211
        dc.w $211,$211,$211,$211,$211,$211,$211,$211,$111,$111,$111,$111,$111,$111,$111,$111
        dc.w $101,$101,$101,$101,$101,$101,$101,$101,$001,$001,$001,$001,$001,$001,$001,$001
        dc.w $001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001
        dc.w $001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001
        dc.w $001,$001,$001,$001,$001,$001,$001,$001,$001,$101,$101,$101,$101,$101,$101,$101
        dc.w $101,$111,$111,$111,$111,$111,$111,$111,$111,$211,$211,$211,$211,$211,$211,$211
        dc.w $211,$211,$211,$211,$211,$211,$111,$111,$111,$111,$111,$111,$111,$111,$111,$111
        dc.w $111,$101,$101,$101,$101,$101,$101,$101,$101,$101,$101,$101,$101,$101,$101,$101
        dc.w $101,$101,$101,$101,$101,$101,$101,$101,$101,$101,$101,$101,$101,$101,$101,$101
        dc.w $101,$111,$111,$111,$111,$111,$211,$211,$211,$211,$211,$211,$211,$211,$211,$311
        dc.w $311,$311,$311,$321,$321,$321,$321,$421,$421,$421,$421,$421,$421,$421,$421,$421
        dc.w $421,$421,$421,$421,$421,$421,$421,$421,$421,$421,$321,$321,$321,$321,$311,$311
        dc.w $311,$311,$211,$211,$211,$211,$211,$211,$211,$211,$211,$111,$111,$111,$111,$111
        dc.w $111,$101,$101,$101,$101,$101,$101,$101,$101,$101,$101,$101,$101,$101,$101,$101
        dc.w $101,$101,$101,$101,$101,$101,$101,$101,$101,$101,$101,$101,$101,$101,$101,$101
        dc.w $312,$312,$312,$312,$312,$312,$312,$312,$312,$312,$312,$212,$212,$212,$212,$202
        dc.w $202,$202,$102,$102,$102,$102,$101,$101,$101,$101,$001,$001,$001,$001,$001,$001
        dc.w $001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001
        dc.w $001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$101,$101,$101,$101
        dc.w $102,$102,$102,$102,$102,$202,$202,$202,$202,$202,$202,$202,$212,$212,$212,$212
        dc.w $212,$212,$202,$202,$202,$202,$202,$202,$202,$202,$102,$102,$102,$102,$102,$102
        dc.w $102,$102,$102,$102,$101,$101,$101,$101,$101,$101,$101,$102,$102,$102,$102,$102
        dc.w $102,$102,$102,$102,$202,$202,$202,$202,$202,$212,$212,$212,$212,$212,$312,$312
        dc.w $312,$312,$312,$312,$312,$312,$312,$312,$312,$312,$312,$212,$212,$212,$212,$202
        dc.w $202,$202,$102,$102,$102,$102,$101,$101,$101,$101,$001,$001,$001,$001,$001,$001
        dc.w $001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001
        dc.w $001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$101,$101,$101,$101
        dc.w $101,$102,$102,$102,$102,$202,$202,$202,$202,$202,$202,$202,$212,$212,$212,$212
        dc.w $212,$212,$202,$202,$202,$202,$202,$202,$202,$202,$102,$102,$102,$102,$102,$102
        dc.w $102,$102,$102,$102,$101,$101,$101,$101,$101,$101,$101,$102,$102,$102,$102,$102
        dc.w $102,$102,$102,$102,$202,$202,$202,$202,$202,$212,$212,$212,$212,$212,$312,$312
        dc.w $135,$135,$135,$135,$135,$135,$134,$124,$124,$124,$123,$123,$013,$013,$012,$012
        dc.w $012,$012,$002,$002,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001
        dc.w $001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$002,$012,$012,$012
        dc.w $012,$012,$012,$012,$012,$012,$012,$013,$013,$013,$013,$013,$013,$013,$012,$012
        dc.w $012,$012,$012,$012,$012,$012,$012,$012,$012,$012,$012,$012,$012,$012,$012,$012
        dc.w $012,$012,$012,$012,$012,$012,$012,$013,$013,$013,$013,$123,$123,$123,$123,$123
        dc.w $123,$124,$124,$124,$124,$124,$123,$123,$123,$123,$123,$013,$013,$013,$012,$012
        dc.w $012,$012,$012,$002,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001
        dc.w $001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$002,$002,$012
        dc.w $012,$012,$012,$013,$013,$123,$123,$124,$124,$124,$124,$124,$124,$124,$134,$134
        dc.w $124,$124,$124,$124,$124,$124,$124,$123,$123,$123,$013,$013,$013,$012,$012,$012
        dc.w $012,$012,$012,$012,$012,$002,$002,$002,$002,$002,$002,$002,$002,$002,$002,$002
        dc.w $012,$012,$012,$012,$012,$012,$012,$012,$012,$012,$012,$012,$012,$012,$012,$012
        dc.w $012,$012,$012,$012,$012,$012,$002,$002,$002,$001,$001,$001,$001,$001,$001,$001
        dc.w $001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$002,$012,$012
        dc.w $012,$012,$012,$013,$013,$123,$123,$124,$124,$124,$124,$134,$135,$135,$135,$135
        dc.w $331,$331,$331,$321,$321,$321,$321,$321,$321,$321,$321,$321,$221,$221,$221,$221
        dc.w $221,$211,$211,$211,$211,$211,$211,$111,$111,$111,$111,$111,$111,$111,$111,$111
        dc.w $111,$111,$111,$111,$111,$111,$111,$111,$111,$111,$111,$111,$111,$111,$111,$111
        dc.w $111,$111,$111,$111,$111,$111,$211,$211,$211,$211,$211,$211,$211,$221,$221,$221
        dc.w $221,$221,$221,$221,$221,$321,$321,$321,$321,$321,$321,$321,$321,$321,$321,$221
        dc.w $221,$221,$221,$221,$221,$221,$211,$211,$211,$211,$211,$211,$111,$111,$111,$111
        dc.w $111,$111,$111,$111,$101,$101,$101,$001,$001,$001,$001,$001,$001,$001,$001,$001
        dc.w $001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001
        dc.w $001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001
        dc.w $001,$001,$001,$001,$101,$101,$101,$101,$111,$111,$111,$111,$111,$111,$111,$111
        dc.w $111,$111,$111,$111,$111,$111,$111,$111,$111,$111,$111,$111,$111,$111,$111,$111
        dc.w $111,$111,$111,$111,$101,$101,$101,$101,$001,$001,$001,$001,$001,$001,$001,$001
        dc.w $001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001
        dc.w $001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$101,$101,$111,$111,$111,$111
        dc.w $111,$111,$111,$111,$111,$211,$211,$211,$211,$221,$221,$221,$221,$321,$321,$321
        dc.w $321,$321,$321,$321,$321,$331,$331,$331,$431,$431,$431,$431,$431,$431,$431,$431
        dc.w $112,$112,$112,$112,$112,$112,$112,$112,$112,$112,$112,$112,$112,$112,$102,$102
        dc.w $102,$102,$102,$102,$102,$102,$112,$112,$112,$112,$112,$112,$112,$112,$112,$112
        dc.w $112,$112,$112,$213,$213,$213,$213,$213,$213,$213,$213,$213,$213,$213,$213,$213
        dc.w $213,$213,$213,$213,$213,$213,$213,$213,$213,$213,$112,$112,$112,$112,$112,$112
        dc.w $112,$102,$102,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001
        dc.w $001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001
        dc.w $001,$001,$001,$001,$001,$001,$001,$001,$102,$102,$102,$112,$112,$112,$112,$112
        dc.w $112,$112,$112,$112,$112,$112,$112,$213,$213,$213,$213,$213,$112,$112,$112,$112
        dc.w $112,$112,$112,$112,$112,$112,$112,$112,$112,$112,$112,$112,$112,$112,$102,$102
        dc.w $102,$102,$102,$102,$102,$102,$112,$112,$112,$112,$112,$112,$112,$112,$112,$112
        dc.w $112,$112,$112,$213,$213,$213,$213,$213,$213,$213,$213,$213,$213,$213,$213,$213
        dc.w $213,$213,$213,$213,$213,$213,$213,$213,$213,$213,$112,$112,$112,$112,$112,$112
        dc.w $112,$102,$102,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001
        dc.w $001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001
        dc.w $001,$001,$001,$001,$001,$001,$001,$001,$102,$102,$102,$112,$112,$112,$112,$112
        dc.w $112,$112,$112,$112,$112,$112,$112,$213,$213,$213,$213,$213,$112,$112,$112,$112
        dc.w $001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$012,$012,$012,$012,$012
        dc.w $012,$012,$012,$012,$023,$023,$123,$123,$123,$134,$134,$134,$134,$134,$145,$145
        dc.w $145,$145,$145,$145,$145,$134,$134,$134,$134,$134,$123,$123,$023,$023,$012,$012
        dc.w $012,$012,$012,$012,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001
        dc.w $001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$012,$012,$012
        dc.w $012,$012,$012,$012,$023,$023,$023,$023,$023,$123,$123,$123,$123,$123,$123,$123
        dc.w $023,$023,$023,$023,$023,$023,$023,$012,$012,$012,$012,$012,$012,$012,$012,$012
        dc.w $012,$012,$012,$012,$012,$012,$012,$012,$012,$012,$012,$012,$023,$023,$023,$023
        dc.w $023,$023,$023,$023,$023,$023,$023,$023,$023,$023,$023,$023,$023,$012,$012,$012
        dc.w $012,$012,$012,$012,$012,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001
        dc.w $001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$012,$012,$012
        dc.w $012,$012,$012,$023,$023,$123,$123,$134,$134,$134,$134,$134,$145,$145,$145,$145
        dc.w $145,$145,$145,$134,$134,$134,$134,$134,$134,$123,$123,$023,$023,$023,$012,$012
        dc.w $012,$012,$012,$012,$012,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001
        dc.w $001,$001,$001,$001,$001,$012,$012,$012,$012,$012,$012,$012,$012,$012,$012,$012
        dc.w $012,$012,$012,$012,$012,$012,$012,$012,$012,$012,$012,$012,$012,$012,$001,$001
        dc.w $001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001
        dc.w $001,$001,$001,$001,$001,$001,$001,$001,$001,$101,$101,$101,$101,$101,$101,$101
        dc.w $101,$101,$101,$201,$201,$201,$201,$201,$201,$201,$201,$311,$311,$311,$311,$311
        dc.w $311,$311,$311,$311,$311,$311,$311,$311,$311,$311,$311,$311,$311,$311,$311,$311
        dc.w $311,$311,$311,$311,$201,$201,$201,$201,$201,$201,$201,$201,$201,$201,$201,$201
        dc.w $101,$101,$101,$101,$101,$101,$101,$101,$101,$101,$101,$101,$101,$101,$101,$101
        dc.w $101,$101,$101,$101,$101,$101,$201,$201,$201,$201,$201,$201,$201,$201,$201,$201
        dc.w $311,$311,$311,$311,$311,$311,$311,$311,$411,$411,$411,$411,$411,$411,$411,$411
        dc.w $411,$411,$411,$411,$511,$411,$411,$411,$411,$411,$411,$411,$411,$411,$411,$411
        dc.w $411,$311,$311,$311,$311,$311,$311,$311,$201,$201,$201,$201,$201,$201,$201,$101
        dc.w $101,$101,$101,$101,$101,$101,$101,$101,$101,$001,$001,$001,$001,$001,$001,$001
        dc.w $001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001
        dc.w $001,$001,$001,$001,$001,$001,$101,$101,$101,$101,$101,$101,$101,$101,$101,$101
        dc.w $101,$101,$101,$101,$101,$101,$101,$101,$101,$101,$101,$101,$101,$101,$101,$101
        dc.w $101,$101,$101,$101,$101,$101,$101,$101,$101,$101,$101,$101,$101,$101,$101,$001
        dc.w $001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001
        dc.w $001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001
        dc.w $001,$101,$101,$111,$111,$111,$111,$111,$111,$111,$211,$211,$211,$211,$211,$211
        dc.w $211,$211,$222,$222,$222,$222,$211,$211,$211,$211,$211,$211,$211,$211,$211,$111
        dc.w $111,$111,$111,$111,$111,$111,$111,$111,$111,$111,$111,$111,$111,$111,$111,$111
        dc.w $111,$111,$111,$111,$111,$111,$111,$111,$111,$211,$211,$211,$211,$211,$222,$222
        dc.w $222,$222,$222,$322,$322,$322,$322,$322,$322,$322,$322,$322,$322,$322,$322,$322
        dc.w $322,$222,$222,$222,$211,$211,$211,$211,$111,$111,$111,$111,$111,$111,$101,$001
        dc.w $001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001
        dc.w $001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001
        dc.w $001,$101,$101,$111,$111,$111,$111,$111,$111,$111,$211,$211,$211,$211,$211,$211
        dc.w $211,$211,$222,$222,$222,$222,$211,$211,$211,$211,$211,$211,$211,$211,$211,$111
        dc.w $111,$111,$111,$111,$111,$111,$111,$111,$111,$111,$111,$111,$111,$111,$111,$111
        dc.w $111,$111,$111,$111,$111,$111,$111,$111,$111,$211,$211,$211,$211,$211,$222,$222
        dc.w $222,$222,$222,$322,$322,$322,$322,$322,$322,$322,$322,$322,$322,$322,$322,$322
        dc.w $322,$222,$222,$222,$211,$211,$211,$211,$111,$111,$111,$111,$111,$111,$101,$001
        dc.w $001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001,$001

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

; Eight closed sprite paths, each 256 (x0,z0) pairs (tools/gen_tables.py orbit_banks).
ring_tab:
        dc.w $045,$000,$045,$001,$045,$003,$045,$004,$044,$006,$044,$008,$044,$00A,$044,$00C
        dc.w $044,$00D,$043,$00F,$043,$010,$042,$012,$042,$014,$042,$015,$041,$017,$040,$019
        dc.w $03F,$01A,$03F,$01B,$03E,$01D,$03D,$01F,$03D,$020,$03C,$022,$03B,$023,$03A,$025
        dc.w $039,$026,$038,$027,$037,$029,$036,$02A,$035,$02C,$034,$02D,$033,$02E,$032,$030
        dc.w $031,$031,$030,$032,$02E,$033,$02D,$034,$02C,$035,$02A,$036,$029,$037,$027,$038
        dc.w $026,$039,$025,$03A,$023,$03B,$022,$03C,$020,$03D,$01F,$03D,$01D,$03E,$01B,$03F
        dc.w $01A,$03F,$019,$040,$017,$041,$015,$042,$014,$042,$012,$042,$010,$043,$00F,$043
        dc.w $00D,$044,$00C,$044,$00A,$044,$008,$044,$006,$044,$004,$045,$003,$045,$001,$045
        dc.w $000,$045,$FFFE,$045,$FFFC,$045,$FFFB,$045,$FFF9,$044,$FFF7,$044,$FFF5,$044,$FFF3,$044
        dc.w $FFF2,$044,$FFF0,$043,$FFEF,$043,$FFED,$042,$FFEB,$042,$FFEA,$042,$FFE8,$041,$FFE6,$040
        dc.w $FFE5,$03F,$FFE4,$03F,$FFE2,$03E,$FFE0,$03D,$FFDF,$03D,$FFDD,$03C,$FFDC,$03B,$FFDA,$03A
        dc.w $FFD9,$039,$FFD8,$038,$FFD6,$037,$FFD5,$036,$FFD3,$035,$FFD2,$034,$FFD1,$033,$FFCF,$032
        dc.w $FFCE,$031,$FFCD,$030,$FFCC,$02E,$FFCB,$02D,$FFCA,$02C,$FFC9,$02A,$FFC8,$029,$FFC7,$027
        dc.w $FFC6,$026,$FFC5,$025,$FFC4,$023,$FFC3,$022,$FFC2,$020,$FFC2,$01F,$FFC1,$01D,$FFC0,$01B
        dc.w $FFC0,$01A,$FFBF,$019,$FFBE,$017,$FFBD,$015,$FFBD,$014,$FFBD,$012,$FFBC,$010,$FFBC,$00F
        dc.w $FFBB,$00D,$FFBB,$00C,$FFBB,$00A,$FFBB,$008,$FFBB,$006,$FFBA,$004,$FFBA,$003,$FFBA,$001
        dc.w $FFBA,$000,$FFBA,$FFFE,$FFBA,$FFFC,$FFBA,$FFFB,$FFBB,$FFF9,$FFBB,$FFF7,$FFBB,$FFF5,$FFBB,$FFF3
        dc.w $FFBB,$FFF2,$FFBC,$FFF0,$FFBC,$FFEF,$FFBD,$FFED,$FFBD,$FFEB,$FFBD,$FFEA,$FFBE,$FFE8,$FFBF,$FFE6
        dc.w $FFC0,$FFE5,$FFC0,$FFE4,$FFC1,$FFE2,$FFC2,$FFE0,$FFC2,$FFDF,$FFC3,$FFDD,$FFC4,$FFDC,$FFC5,$FFDA
        dc.w $FFC6,$FFD9,$FFC7,$FFD8,$FFC8,$FFD6,$FFC9,$FFD5,$FFCA,$FFD3,$FFCB,$FFD2,$FFCC,$FFD1,$FFCD,$FFCF
        dc.w $FFCE,$FFCE,$FFCF,$FFCD,$FFD1,$FFCC,$FFD2,$FFCB,$FFD3,$FFCA,$FFD5,$FFC9,$FFD6,$FFC8,$FFD8,$FFC7
        dc.w $FFD9,$FFC6,$FFDA,$FFC5,$FFDC,$FFC4,$FFDD,$FFC3,$FFDF,$FFC2,$FFE0,$FFC2,$FFE2,$FFC1,$FFE4,$FFC0
        dc.w $FFE5,$FFC0,$FFE6,$FFBF,$FFE8,$FFBE,$FFEA,$FFBD,$FFEB,$FFBD,$FFED,$FFBD,$FFEF,$FFBC,$FFF0,$FFBC
        dc.w $FFF2,$FFBB,$FFF3,$FFBB,$FFF5,$FFBB,$FFF7,$FFBB,$FFF9,$FFBB,$FFFB,$FFBA,$FFFC,$FFBA,$FFFE,$FFBA
        dc.w $000,$FFBA,$001,$FFBA,$003,$FFBA,$004,$FFBA,$006,$FFBB,$008,$FFBB,$00A,$FFBB,$00C,$FFBB
        dc.w $00D,$FFBB,$00F,$FFBC,$010,$FFBC,$012,$FFBD,$014,$FFBD,$015,$FFBD,$017,$FFBE,$019,$FFBF
        dc.w $01A,$FFC0,$01B,$FFC0,$01D,$FFC1,$01F,$FFC2,$020,$FFC2,$022,$FFC3,$023,$FFC4,$025,$FFC5
        dc.w $026,$FFC6,$027,$FFC7,$029,$FFC8,$02A,$FFC9,$02C,$FFCA,$02D,$FFCB,$02E,$FFCC,$030,$FFCD
        dc.w $031,$FFCE,$032,$FFCF,$033,$FFD1,$034,$FFD2,$035,$FFD3,$036,$FFD5,$037,$FFD6,$038,$FFD8
        dc.w $039,$FFD9,$03A,$FFDA,$03B,$FFDC,$03C,$FFDD,$03D,$FFDF,$03D,$FFE0,$03E,$FFE2,$03F,$FFE4
        dc.w $03F,$FFE5,$040,$FFE6,$041,$FFE8,$042,$FFEA,$042,$FFEB,$042,$FFED,$043,$FFEF,$043,$FFF0
        dc.w $044,$FFF2,$044,$FFF3,$044,$FFF5,$044,$FFF7,$044,$FFF9,$045,$FFFB,$045,$FFFC,$045,$FFFE
        dc.w $045,$000,$045,$001,$045,$002,$045,$003,$045,$004,$044,$005,$044,$006,$044,$006
        dc.w $044,$007,$043,$008,$043,$009,$043,$00A,$042,$00B,$042,$00C,$041,$00D,$040,$00E
        dc.w $040,$00F,$03F,$00F,$03E,$010,$03E,$011,$03D,$012,$03C,$013,$03B,$014,$03A,$014
        dc.w $039,$015,$038,$016,$037,$017,$036,$017,$035,$018,$034,$019,$033,$019,$032,$01A
        dc.w $031,$01B,$030,$01B,$02E,$01C,$02D,$01D,$02C,$01D,$02A,$01E,$029,$01E,$028,$01F
        dc.w $026,$020,$025,$020,$023,$021,$022,$021,$021,$021,$01F,$022,$01E,$022,$01C,$023
        dc.w $01A,$023,$019,$023,$017,$024,$016,$024,$014,$024,$012,$025,$011,$025,$00F,$025
        dc.w $00D,$025,$00C,$025,$00A,$026,$008,$026,$007,$026,$005,$026,$003,$026,$002,$026
        dc.w $000,$026,$FFFE,$026,$FFFD,$026,$FFFB,$026,$FFF9,$026,$FFF8,$026,$FFF6,$026,$FFF4,$025
        dc.w $FFF3,$025,$FFF1,$025,$FFEF,$025,$FFEE,$025,$FFEC,$024,$FFEA,$024,$FFE9,$024,$FFE7,$023
        dc.w $FFE6,$023,$FFE4,$023,$FFE2,$022,$FFE1,$022,$FFDF,$021,$FFDE,$021,$FFDD,$021,$FFDB,$020
        dc.w $FFDA,$020,$FFD8,$01F,$FFD7,$01E,$FFD6,$01E,$FFD4,$01D,$FFD3,$01D,$FFD2,$01C,$FFD0,$01B
        dc.w $FFCF,$01B,$FFCE,$01A,$FFCD,$019,$FFCC,$019,$FFCB,$018,$FFCA,$017,$FFC9,$017,$FFC8,$016
        dc.w $FFC7,$015,$FFC6,$014,$FFC5,$014,$FFC4,$013,$FFC3,$012,$FFC2,$011,$FFC2,$010,$FFC1,$00F
        dc.w $FFC0,$00F,$FFC0,$00E,$FFBF,$00D,$FFBE,$00C,$FFBE,$00B,$FFBD,$00A,$FFBD,$009,$FFBD,$008
        dc.w $FFBC,$007,$FFBC,$006,$FFBC,$006,$FFBC,$005,$FFBB,$004,$FFBB,$003,$FFBB,$002,$FFBB,$001
        dc.w $FFBB,$000,$FFBB,$FFFF,$FFBB,$FFFE,$FFBB,$FFFD,$FFBB,$FFFC,$FFBC,$FFFB,$FFBC,$FFFA,$FFBC,$FFFA
        dc.w $FFBC,$FFF9,$FFBD,$FFF8,$FFBD,$FFF7,$FFBD,$FFF6,$FFBE,$FFF5,$FFBE,$FFF4,$FFBF,$FFF3,$FFC0,$FFF2
        dc.w $FFC0,$FFF1,$FFC1,$FFF1,$FFC2,$FFF0,$FFC2,$FFEF,$FFC3,$FFEE,$FFC4,$FFED,$FFC5,$FFEC,$FFC6,$FFEC
        dc.w $FFC7,$FFEB,$FFC8,$FFEA,$FFC9,$FFE9,$FFCA,$FFE9,$FFCB,$FFE8,$FFCC,$FFE7,$FFCD,$FFE7,$FFCE,$FFE6
        dc.w $FFCF,$FFE5,$FFD0,$FFE5,$FFD2,$FFE4,$FFD3,$FFE3,$FFD4,$FFE3,$FFD6,$FFE2,$FFD7,$FFE2,$FFD8,$FFE1
        dc.w $FFDA,$FFE0,$FFDB,$FFE0,$FFDD,$FFDF,$FFDE,$FFDF,$FFDF,$FFDF,$FFE1,$FFDE,$FFE2,$FFDE,$FFE4,$FFDD
        dc.w $FFE6,$FFDD,$FFE7,$FFDD,$FFE9,$FFDC,$FFEA,$FFDC,$FFEC,$FFDC,$FFEE,$FFDB,$FFEF,$FFDB,$FFF1,$FFDB
        dc.w $FFF3,$FFDB,$FFF4,$FFDB,$FFF6,$FFDA,$FFF8,$FFDA,$FFF9,$FFDA,$FFFB,$FFDA,$FFFD,$FFDA,$FFFE,$FFDA
        dc.w $000,$FFDA,$002,$FFDA,$003,$FFDA,$005,$FFDA,$007,$FFDA,$008,$FFDA,$00A,$FFDA,$00C,$FFDB
        dc.w $00D,$FFDB,$00F,$FFDB,$011,$FFDB,$012,$FFDB,$014,$FFDC,$016,$FFDC,$017,$FFDC,$019,$FFDD
        dc.w $01A,$FFDD,$01C,$FFDD,$01E,$FFDE,$01F,$FFDE,$021,$FFDF,$022,$FFDF,$023,$FFDF,$025,$FFE0
        dc.w $026,$FFE0,$028,$FFE1,$029,$FFE2,$02A,$FFE2,$02C,$FFE3,$02D,$FFE3,$02E,$FFE4,$030,$FFE5
        dc.w $031,$FFE5,$032,$FFE6,$033,$FFE7,$034,$FFE7,$035,$FFE8,$036,$FFE9,$037,$FFE9,$038,$FFEA
        dc.w $039,$FFEB,$03A,$FFEC,$03B,$FFEC,$03C,$FFED,$03D,$FFEE,$03E,$FFEF,$03E,$FFF0,$03F,$FFF1
        dc.w $040,$FFF1,$040,$FFF2,$041,$FFF3,$042,$FFF4,$042,$FFF5,$043,$FFF6,$043,$FFF7,$043,$FFF8
        dc.w $044,$FFF9,$044,$FFFA,$044,$FFFA,$044,$FFFB,$045,$FFFC,$045,$FFFD,$045,$FFFE,$045,$FFFF
        dc.w $03B,$000,$03B,$002,$03B,$004,$03A,$007,$03A,$009,$03A,$00B,$03A,$00D,$03A,$00F
        dc.w $03A,$011,$039,$013,$039,$015,$039,$017,$038,$019,$038,$01B,$037,$01C,$037,$01E
        dc.w $036,$020,$036,$021,$035,$023,$034,$024,$034,$025,$033,$026,$032,$028,$032,$029
        dc.w $031,$029,$030,$02A,$02F,$02B,$02E,$02C,$02D,$02C,$02C,$02C,$02B,$02D,$02A,$02D
        dc.w $029,$02D,$028,$02D,$027,$02D,$026,$02C,$025,$02C,$024,$02C,$023,$02B,$022,$02A
        dc.w $021,$029,$01F,$029,$01E,$028,$01D,$026,$01C,$025,$01A,$024,$019,$023,$018,$021
        dc.w $016,$020,$015,$01E,$014,$01C,$012,$01B,$011,$019,$010,$017,$00E,$015,$00D,$013
        dc.w $00B,$011,$00A,$00F,$009,$00D,$007,$00B,$006,$009,$004,$007,$003,$004,$001,$002
        dc.w $000,$000,$FFFF,$FFFE,$FFFD,$FFFC,$FFFC,$FFF9,$FFFA,$FFF7,$FFF9,$FFF5,$FFF7,$FFF3,$FFF6,$FFF1
        dc.w $FFF5,$FFEF,$FFF3,$FFED,$FFF2,$FFEB,$FFF0,$FFE9,$FFEF,$FFE7,$FFEE,$FFE5,$FFEC,$FFE4,$FFEB,$FFE2
        dc.w $FFEA,$FFE0,$FFE8,$FFDF,$FFE7,$FFDD,$FFE6,$FFDC,$FFE4,$FFDB,$FFE3,$FFDA,$FFE2,$FFD8,$FFE1,$FFD7
        dc.w $FFDF,$FFD7,$FFDE,$FFD6,$FFDD,$FFD5,$FFDC,$FFD4,$FFDB,$FFD4,$FFDA,$FFD4,$FFD9,$FFD3,$FFD8,$FFD3
        dc.w $FFD7,$FFD3,$FFD6,$FFD3,$FFD5,$FFD3,$FFD4,$FFD4,$FFD3,$FFD4,$FFD2,$FFD4,$FFD1,$FFD5,$FFD0,$FFD6
        dc.w $FFCF,$FFD7,$FFCE,$FFD7,$FFCE,$FFD8,$FFCD,$FFDA,$FFCC,$FFDB,$FFCC,$FFDC,$FFCB,$FFDD,$FFCA,$FFDF
        dc.w $FFCA,$FFE0,$FFC9,$FFE2,$FFC9,$FFE4,$FFC8,$FFE5,$FFC8,$FFE7,$FFC7,$FFE9,$FFC7,$FFEB,$FFC7,$FFED
        dc.w $FFC6,$FFEF,$FFC6,$FFF1,$FFC6,$FFF3,$FFC6,$FFF5,$FFC6,$FFF7,$FFC6,$FFF9,$FFC5,$FFFC,$FFC5,$FFFE
        dc.w $FFC5,$000,$FFC5,$002,$FFC5,$004,$FFC6,$007,$FFC6,$009,$FFC6,$00B,$FFC6,$00D,$FFC6,$00F
        dc.w $FFC6,$011,$FFC7,$013,$FFC7,$015,$FFC7,$017,$FFC8,$019,$FFC8,$01B,$FFC9,$01C,$FFC9,$01E
        dc.w $FFCA,$020,$FFCA,$021,$FFCB,$023,$FFCC,$024,$FFCC,$025,$FFCD,$026,$FFCE,$028,$FFCE,$029
        dc.w $FFCF,$029,$FFD0,$02A,$FFD1,$02B,$FFD2,$02C,$FFD3,$02C,$FFD4,$02C,$FFD5,$02D,$FFD6,$02D
        dc.w $FFD7,$02D,$FFD8,$02D,$FFD9,$02D,$FFDA,$02C,$FFDB,$02C,$FFDC,$02C,$FFDD,$02B,$FFDE,$02A
        dc.w $FFDF,$029,$FFE1,$029,$FFE2,$028,$FFE3,$026,$FFE4,$025,$FFE6,$024,$FFE7,$023,$FFE8,$021
        dc.w $FFEA,$020,$FFEB,$01E,$FFEC,$01C,$FFEE,$01B,$FFEF,$019,$FFF0,$017,$FFF2,$015,$FFF3,$013
        dc.w $FFF5,$011,$FFF6,$00F,$FFF7,$00D,$FFF9,$00B,$FFFA,$009,$FFFC,$007,$FFFD,$004,$FFFF,$002
        dc.w $000,$000,$001,$FFFE,$003,$FFFC,$004,$FFF9,$006,$FFF7,$007,$FFF5,$009,$FFF3,$00A,$FFF1
        dc.w $00B,$FFEF,$00D,$FFED,$00E,$FFEB,$010,$FFE9,$011,$FFE7,$012,$FFE5,$014,$FFE4,$015,$FFE2
        dc.w $016,$FFE0,$018,$FFDF,$019,$FFDD,$01A,$FFDC,$01C,$FFDB,$01D,$FFDA,$01E,$FFD8,$01F,$FFD7
        dc.w $021,$FFD7,$022,$FFD6,$023,$FFD5,$024,$FFD4,$025,$FFD4,$026,$FFD4,$027,$FFD3,$028,$FFD3
        dc.w $029,$FFD3,$02A,$FFD3,$02B,$FFD3,$02C,$FFD4,$02D,$FFD4,$02E,$FFD4,$02F,$FFD5,$030,$FFD6
        dc.w $031,$FFD7,$032,$FFD7,$032,$FFD8,$033,$FFDA,$034,$FFDB,$034,$FFDC,$035,$FFDD,$036,$FFDF
        dc.w $036,$FFE0,$037,$FFE2,$037,$FFE4,$038,$FFE5,$038,$FFE7,$039,$FFE9,$039,$FFEB,$039,$FFED
        dc.w $03A,$FFEF,$03A,$FFF1,$03A,$FFF3,$03A,$FFF5,$03A,$FFF7,$03A,$FFF9,$03B,$FFFC,$03B,$FFFE
        dc.w $045,$000,$045,$002,$045,$003,$044,$005,$044,$007,$043,$008,$042,$00A,$041,$00B
        dc.w $040,$00D,$03E,$00E,$03D,$00F,$03B,$010,$03A,$012,$038,$013,$037,$014,$035,$014
        dc.w $033,$015,$031,$016,$02F,$016,$02E,$017,$02C,$018,$02A,$018,$029,$018,$027,$019
        dc.w $026,$019,$024,$01A,$023,$01A,$022,$01A,$021,$01B,$020,$01B,$01F,$01C,$01E,$01D
        dc.w $01D,$01D,$01D,$01E,$01C,$01F,$01B,$020,$01B,$021,$01A,$022,$01A,$023,$01A,$024
        dc.w $019,$026,$019,$027,$018,$029,$018,$02A,$018,$02C,$017,$02E,$016,$02F,$016,$031
        dc.w $015,$033,$014,$035,$014,$037,$013,$038,$012,$03A,$010,$03B,$00F,$03D,$00E,$03E
        dc.w $00D,$040,$00B,$041,$00A,$042,$008,$043,$007,$044,$005,$044,$003,$045,$002,$045
        dc.w $000,$045,$FFFE,$045,$FFFD,$045,$FFFB,$044,$FFF9,$044,$FFF8,$043,$FFF6,$042,$FFF5,$041
        dc.w $FFF3,$040,$FFF2,$03E,$FFF1,$03D,$FFF0,$03B,$FFEE,$03A,$FFED,$038,$FFEC,$037,$FFEC,$035
        dc.w $FFEB,$033,$FFEA,$031,$FFEA,$02F,$FFE9,$02E,$FFE8,$02C,$FFE8,$02A,$FFE8,$029,$FFE7,$027
        dc.w $FFE7,$026,$FFE6,$024,$FFE6,$023,$FFE6,$022,$FFE5,$021,$FFE5,$020,$FFE4,$01F,$FFE3,$01E
        dc.w $FFE3,$01D,$FFE2,$01D,$FFE1,$01C,$FFE0,$01B,$FFDF,$01B,$FFDE,$01A,$FFDD,$01A,$FFDC,$01A
        dc.w $FFDA,$019,$FFD9,$019,$FFD7,$018,$FFD6,$018,$FFD4,$018,$FFD2,$017,$FFD1,$016,$FFCF,$016
        dc.w $FFCD,$015,$FFCB,$014,$FFC9,$014,$FFC8,$013,$FFC6,$012,$FFC5,$010,$FFC3,$00F,$FFC2,$00E
        dc.w $FFC0,$00D,$FFBF,$00B,$FFBE,$00A,$FFBD,$008,$FFBC,$007,$FFBC,$005,$FFBB,$003,$FFBB,$002
        dc.w $FFBB,$000,$FFBB,$FFFE,$FFBB,$FFFD,$FFBC,$FFFB,$FFBC,$FFF9,$FFBD,$FFF8,$FFBE,$FFF6,$FFBF,$FFF5
        dc.w $FFC0,$FFF3,$FFC2,$FFF2,$FFC3,$FFF1,$FFC5,$FFF0,$FFC6,$FFEE,$FFC8,$FFED,$FFC9,$FFEC,$FFCB,$FFEC
        dc.w $FFCD,$FFEB,$FFCF,$FFEA,$FFD1,$FFEA,$FFD2,$FFE9,$FFD4,$FFE8,$FFD6,$FFE8,$FFD7,$FFE8,$FFD9,$FFE7
        dc.w $FFDA,$FFE7,$FFDC,$FFE6,$FFDD,$FFE6,$FFDE,$FFE6,$FFDF,$FFE5,$FFE0,$FFE5,$FFE1,$FFE4,$FFE2,$FFE3
        dc.w $FFE3,$FFE3,$FFE3,$FFE2,$FFE4,$FFE1,$FFE5,$FFE0,$FFE5,$FFDF,$FFE6,$FFDE,$FFE6,$FFDD,$FFE6,$FFDC
        dc.w $FFE7,$FFDA,$FFE7,$FFD9,$FFE8,$FFD7,$FFE8,$FFD6,$FFE8,$FFD4,$FFE9,$FFD2,$FFEA,$FFD1,$FFEA,$FFCF
        dc.w $FFEB,$FFCD,$FFEC,$FFCB,$FFEC,$FFC9,$FFED,$FFC8,$FFEE,$FFC6,$FFF0,$FFC5,$FFF1,$FFC3,$FFF2,$FFC2
        dc.w $FFF3,$FFC0,$FFF5,$FFBF,$FFF6,$FFBE,$FFF8,$FFBD,$FFF9,$FFBC,$FFFB,$FFBC,$FFFD,$FFBB,$FFFE,$FFBB
        dc.w $000,$FFBB,$002,$FFBB,$003,$FFBB,$005,$FFBC,$007,$FFBC,$008,$FFBD,$00A,$FFBE,$00B,$FFBF
        dc.w $00D,$FFC0,$00E,$FFC2,$00F,$FFC3,$010,$FFC5,$012,$FFC6,$013,$FFC8,$014,$FFC9,$014,$FFCB
        dc.w $015,$FFCD,$016,$FFCF,$016,$FFD1,$017,$FFD2,$018,$FFD4,$018,$FFD6,$018,$FFD7,$019,$FFD9
        dc.w $019,$FFDA,$01A,$FFDC,$01A,$FFDD,$01A,$FFDE,$01B,$FFDF,$01B,$FFE0,$01C,$FFE1,$01D,$FFE2
        dc.w $01D,$FFE3,$01E,$FFE3,$01F,$FFE4,$020,$FFE5,$021,$FFE5,$022,$FFE6,$023,$FFE6,$024,$FFE6
        dc.w $026,$FFE7,$027,$FFE7,$029,$FFE8,$02A,$FFE8,$02C,$FFE8,$02E,$FFE9,$02F,$FFEA,$031,$FFEA
        dc.w $033,$FFEB,$035,$FFEC,$037,$FFEC,$038,$FFED,$03A,$FFEE,$03B,$FFF0,$03D,$FFF1,$03E,$FFF2
        dc.w $040,$FFF3,$041,$FFF5,$042,$FFF6,$043,$FFF8,$044,$FFF9,$044,$FFFB,$045,$FFFD,$045,$FFFE
        dc.w $045,$000,$045,$002,$045,$003,$044,$005,$044,$007,$043,$008,$042,$00A,$042,$00B
        dc.w $040,$00D,$03F,$00E,$03E,$010,$03D,$011,$03B,$012,$03A,$013,$038,$014,$036,$015
        dc.w $035,$016,$033,$017,$031,$017,$02F,$018,$02D,$018,$02C,$019,$02A,$019,$028,$019
        dc.w $026,$01A,$024,$01A,$023,$01A,$021,$01A,$01F,$01A,$01E,$01A,$01C,$01A,$01B,$01A
        dc.w $019,$019,$018,$019,$017,$019,$016,$019,$015,$019,$014,$019,$013,$019,$012,$019
        dc.w $011,$01A,$010,$01A,$010,$01A,$00F,$01A,$00E,$01B,$00E,$01B,$00D,$01C,$00D,$01D
        dc.w $00C,$01D,$00C,$01E,$00B,$01F,$00B,$020,$00A,$021,$00A,$022,$009,$024,$008,$025
        dc.w $008,$026,$007,$028,$006,$029,$005,$02A,$004,$02C,$003,$02D,$002,$02F,$001,$030
        dc.w $000,$032,$FFFF,$033,$FFFD,$034,$FFFC,$036,$FFFB,$037,$FFF9,$038,$FFF7,$039,$FFF6,$03A
        dc.w $FFF4,$03B,$FFF3,$03C,$FFF1,$03D,$FFEF,$03D,$FFED,$03E,$FFEB,$03E,$FFEA,$03E,$FFE8,$03E
        dc.w $FFE6,$03E,$FFE4,$03E,$FFE3,$03E,$FFE1,$03D,$FFE0,$03D,$FFDE,$03C,$FFDD,$03B,$FFDB,$03A
        dc.w $FFDA,$039,$FFD9,$038,$FFD8,$037,$FFD7,$035,$FFD6,$034,$FFD5,$032,$FFD4,$030,$FFD4,$02F
        dc.w $FFD3,$02D,$FFD3,$02B,$FFD3,$029,$FFD3,$027,$FFD3,$025,$FFD3,$023,$FFD3,$021,$FFD3,$020
        dc.w $FFD4,$01E,$FFD4,$01C,$FFD5,$01A,$FFD5,$018,$FFD6,$017,$FFD7,$015,$FFD7,$013,$FFD8,$012
        dc.w $FFD9,$010,$FFDA,$00F,$FFDB,$00D,$FFDB,$00C,$FFDC,$00B,$FFDD,$00A,$FFDE,$009,$FFDE,$008
        dc.w $FFDF,$007,$FFE0,$006,$FFE0,$005,$FFE1,$004,$FFE1,$003,$FFE1,$002,$FFE1,$001,$FFE2,$001
        dc.w $FFE2,$000,$FFE2,$FFFF,$FFE1,$FFFF,$FFE1,$FFFE,$FFE1,$FFFD,$FFE1,$FFFC,$FFE0,$FFFB,$FFE0,$FFFA
        dc.w $FFDF,$FFF9,$FFDE,$FFF8,$FFDE,$FFF7,$FFDD,$FFF6,$FFDC,$FFF5,$FFDB,$FFF4,$FFDB,$FFF3,$FFDA,$FFF1
        dc.w $FFD9,$FFF0,$FFD8,$FFEE,$FFD7,$FFED,$FFD7,$FFEB,$FFD6,$FFE9,$FFD5,$FFE8,$FFD5,$FFE6,$FFD4,$FFE4
        dc.w $FFD4,$FFE2,$FFD3,$FFE0,$FFD3,$FFDF,$FFD3,$FFDD,$FFD3,$FFDB,$FFD3,$FFD9,$FFD3,$FFD7,$FFD3,$FFD5
        dc.w $FFD3,$FFD3,$FFD4,$FFD1,$FFD4,$FFD0,$FFD5,$FFCE,$FFD6,$FFCC,$FFD7,$FFCB,$FFD8,$FFC9,$FFD9,$FFC8
        dc.w $FFDA,$FFC7,$FFDB,$FFC6,$FFDD,$FFC5,$FFDE,$FFC4,$FFE0,$FFC3,$FFE1,$FFC3,$FFE3,$FFC2,$FFE4,$FFC2
        dc.w $FFE6,$FFC2,$FFE8,$FFC2,$FFEA,$FFC2,$FFEB,$FFC2,$FFED,$FFC2,$FFEF,$FFC3,$FFF1,$FFC3,$FFF3,$FFC4
        dc.w $FFF4,$FFC5,$FFF6,$FFC6,$FFF7,$FFC7,$FFF9,$FFC8,$FFFB,$FFC9,$FFFC,$FFCA,$FFFD,$FFCC,$FFFF,$FFCD
        dc.w $000,$FFCE,$001,$FFD0,$002,$FFD1,$003,$FFD3,$004,$FFD4,$005,$FFD6,$006,$FFD7,$007,$FFD8
        dc.w $008,$FFDA,$008,$FFDB,$009,$FFDC,$00A,$FFDE,$00A,$FFDF,$00B,$FFE0,$00B,$FFE1,$00C,$FFE2
        dc.w $00C,$FFE3,$00D,$FFE3,$00D,$FFE4,$00E,$FFE5,$00E,$FFE5,$00F,$FFE6,$010,$FFE6,$010,$FFE6
        dc.w $011,$FFE6,$012,$FFE7,$013,$FFE7,$014,$FFE7,$015,$FFE7,$016,$FFE7,$017,$FFE7,$018,$FFE7
        dc.w $019,$FFE7,$01B,$FFE6,$01C,$FFE6,$01E,$FFE6,$01F,$FFE6,$021,$FFE6,$023,$FFE6,$024,$FFE6
        dc.w $026,$FFE6,$028,$FFE7,$02A,$FFE7,$02C,$FFE7,$02D,$FFE8,$02F,$FFE8,$031,$FFE9,$033,$FFE9
        dc.w $035,$FFEA,$036,$FFEB,$038,$FFEC,$03A,$FFED,$03B,$FFEE,$03D,$FFEF,$03E,$FFF0,$03F,$FFF2
        dc.w $040,$FFF3,$042,$FFF5,$042,$FFF6,$043,$FFF8,$044,$FFF9,$044,$FFFB,$045,$FFFD,$045,$FFFE
        dc.w $02F,$000,$02F,$003,$02F,$007,$02E,$00A,$02E,$00E,$02E,$011,$02D,$014,$02C,$017
        dc.w $02B,$01A,$02A,$01D,$029,$020,$028,$022,$027,$024,$026,$026,$024,$028,$023,$02A
        dc.w $021,$02B,$020,$02D,$01E,$02E,$01C,$02E,$01A,$02F,$018,$02F,$016,$02F,$014,$02F
        dc.w $012,$02E,$010,$02D,$00E,$02C,$00B,$02B,$009,$029,$007,$028,$005,$026,$002,$024
        dc.w $000,$021,$FFFE,$01F,$FFFB,$01C,$FFF9,$019,$FFF7,$016,$FFF5,$013,$FFF2,$010,$FFF0,$00D
        dc.w $FFEE,$009,$FFEC,$006,$FFEA,$002,$FFE8,$FFFF,$FFE6,$FFFB,$FFE4,$FFF8,$FFE2,$FFF5,$FFE0,$FFF1
        dc.w $FFDF,$FFEE,$FFDD,$FFEB,$FFDC,$FFE8,$FFDA,$FFE5,$FFD9,$FFE2,$FFD8,$FFE0,$FFD7,$FFDD,$FFD6,$FFDB
        dc.w $FFD5,$FFD9,$FFD4,$FFD7,$FFD3,$FFD6,$FFD2,$FFD4,$FFD2,$FFD3,$FFD2,$FFD2,$FFD1,$FFD2,$FFD1,$FFD1
        dc.w $FFD1,$FFD1,$FFD1,$FFD1,$FFD1,$FFD2,$FFD2,$FFD2,$FFD2,$FFD3,$FFD2,$FFD4,$FFD3,$FFD6,$FFD4,$FFD7
        dc.w $FFD5,$FFD9,$FFD6,$FFDB,$FFD7,$FFDD,$FFD8,$FFE0,$FFD9,$FFE2,$FFDA,$FFE5,$FFDC,$FFE8,$FFDD,$FFEB
        dc.w $FFDF,$FFEE,$FFE0,$FFF1,$FFE2,$FFF5,$FFE4,$FFF8,$FFE6,$FFFB,$FFE8,$FFFF,$FFEA,$002,$FFEC,$006
        dc.w $FFEE,$009,$FFF0,$00D,$FFF2,$010,$FFF5,$013,$FFF7,$016,$FFF9,$019,$FFFB,$01C,$FFFE,$01F
        dc.w $000,$021,$002,$024,$005,$026,$007,$028,$009,$029,$00B,$02B,$00E,$02C,$010,$02D
        dc.w $012,$02E,$014,$02F,$016,$02F,$018,$02F,$01A,$02F,$01C,$02E,$01E,$02E,$020,$02D
        dc.w $021,$02B,$023,$02A,$024,$028,$026,$026,$027,$024,$028,$022,$029,$020,$02A,$01D
        dc.w $02B,$01A,$02C,$017,$02D,$014,$02E,$011,$02E,$00E,$02E,$00A,$02F,$007,$02F,$003
        dc.w $02F,$000,$02F,$FFFD,$02F,$FFF9,$02E,$FFF6,$02E,$FFF2,$02E,$FFEF,$02D,$FFEC,$02C,$FFE9
        dc.w $02B,$FFE6,$02A,$FFE3,$029,$FFE0,$028,$FFDE,$027,$FFDC,$026,$FFDA,$024,$FFD8,$023,$FFD6
        dc.w $021,$FFD5,$020,$FFD3,$01E,$FFD2,$01C,$FFD2,$01A,$FFD1,$018,$FFD1,$016,$FFD1,$014,$FFD1
        dc.w $012,$FFD2,$010,$FFD3,$00E,$FFD4,$00B,$FFD5,$009,$FFD7,$007,$FFD8,$005,$FFDA,$002,$FFDC
        dc.w $000,$FFDF,$FFFE,$FFE1,$FFFB,$FFE4,$FFF9,$FFE7,$FFF7,$FFEA,$FFF5,$FFED,$FFF2,$FFF0,$FFF0,$FFF3
        dc.w $FFEE,$FFF7,$FFEC,$FFFA,$FFEA,$FFFE,$FFE8,$001,$FFE6,$005,$FFE4,$008,$FFE2,$00B,$FFE0,$00F
        dc.w $FFDF,$012,$FFDD,$015,$FFDC,$018,$FFDA,$01B,$FFD9,$01E,$FFD8,$020,$FFD7,$023,$FFD6,$025
        dc.w $FFD5,$027,$FFD4,$029,$FFD3,$02A,$FFD2,$02C,$FFD2,$02D,$FFD2,$02E,$FFD1,$02E,$FFD1,$02F
        dc.w $FFD1,$02F,$FFD1,$02F,$FFD1,$02E,$FFD2,$02E,$FFD2,$02D,$FFD2,$02C,$FFD3,$02A,$FFD4,$029
        dc.w $FFD5,$027,$FFD6,$025,$FFD7,$023,$FFD8,$020,$FFD9,$01E,$FFDA,$01B,$FFDC,$018,$FFDD,$015
        dc.w $FFDF,$012,$FFE0,$00F,$FFE2,$00B,$FFE4,$008,$FFE6,$005,$FFE8,$001,$FFEA,$FFFE,$FFEC,$FFFA
        dc.w $FFEE,$FFF7,$FFF0,$FFF3,$FFF2,$FFF0,$FFF5,$FFED,$FFF7,$FFEA,$FFF9,$FFE7,$FFFB,$FFE4,$FFFE,$FFE1
        dc.w $000,$FFDF,$002,$FFDC,$005,$FFDA,$007,$FFD8,$009,$FFD7,$00B,$FFD5,$00E,$FFD4,$010,$FFD3
        dc.w $012,$FFD2,$014,$FFD1,$016,$FFD1,$018,$FFD1,$01A,$FFD1,$01C,$FFD2,$01E,$FFD2,$020,$FFD3
        dc.w $021,$FFD5,$023,$FFD6,$024,$FFD8,$026,$FFDA,$027,$FFDC,$028,$FFDE,$029,$FFE0,$02A,$FFE3
        dc.w $02B,$FFE6,$02C,$FFE9,$02D,$FFEC,$02E,$FFEF,$02E,$FFF2,$02E,$FFF6,$02F,$FFF9,$02F,$FFFD
        dc.w $045,$000,$045,$000,$045,$FFFF,$044,$FFFF,$044,$FFFF,$043,$FFFE,$042,$FFFE,$042,$FFFE
        dc.w $041,$FFFE,$03F,$FFFE,$03E,$FFFE,$03D,$FFFE,$03B,$FFFE,$03A,$FFFE,$038,$FFFF,$036,$FFFF
        dc.w $035,$FFFF,$033,$000,$031,$001,$02F,$001,$02D,$002,$02B,$003,$028,$004,$026,$005
        dc.w $024,$007,$022,$008,$020,$009,$01E,$00B,$01C,$00C,$019,$00E,$017,$010,$015,$012
        dc.w $014,$014,$012,$015,$010,$017,$00E,$019,$00C,$01C,$00B,$01E,$009,$020,$008,$022
        dc.w $007,$024,$005,$026,$004,$028,$003,$02B,$002,$02D,$001,$02F,$001,$031,$000,$033
        dc.w $FFFF,$035,$FFFF,$036,$FFFF,$038,$FFFE,$03A,$FFFE,$03B,$FFFE,$03D,$FFFE,$03E,$FFFE,$03F
        dc.w $FFFE,$041,$FFFE,$042,$FFFE,$042,$FFFE,$043,$FFFF,$044,$FFFF,$044,$FFFF,$045,$000,$045
        dc.w $000,$045,$000,$045,$001,$045,$001,$044,$001,$044,$002,$043,$002,$042,$002,$042
        dc.w $002,$041,$002,$03F,$002,$03E,$002,$03D,$002,$03B,$002,$03A,$001,$038,$001,$036
        dc.w $001,$035,$000,$033,$FFFF,$031,$FFFF,$02F,$FFFE,$02D,$FFFD,$02B,$FFFC,$028,$FFFB,$026
        dc.w $FFF9,$024,$FFF8,$022,$FFF7,$020,$FFF5,$01E,$FFF4,$01C,$FFF2,$019,$FFF0,$017,$FFEE,$015
        dc.w $FFEC,$014,$FFEB,$012,$FFE9,$010,$FFE7,$00E,$FFE4,$00C,$FFE2,$00B,$FFE0,$009,$FFDE,$008
        dc.w $FFDC,$007,$FFDA,$005,$FFD8,$004,$FFD5,$003,$FFD3,$002,$FFD1,$001,$FFCF,$001,$FFCD,$000
        dc.w $FFCB,$FFFF,$FFCA,$FFFF,$FFC8,$FFFF,$FFC6,$FFFE,$FFC5,$FFFE,$FFC3,$FFFE,$FFC2,$FFFE,$FFC1,$FFFE
        dc.w $FFBF,$FFFE,$FFBE,$FFFE,$FFBE,$FFFE,$FFBD,$FFFE,$FFBC,$FFFF,$FFBC,$FFFF,$FFBB,$FFFF,$FFBB,$000
        dc.w $FFBB,$000,$FFBB,$000,$FFBB,$001,$FFBC,$001,$FFBC,$001,$FFBD,$002,$FFBE,$002,$FFBE,$002
        dc.w $FFBF,$002,$FFC1,$002,$FFC2,$002,$FFC3,$002,$FFC5,$002,$FFC6,$002,$FFC8,$001,$FFCA,$001
        dc.w $FFCB,$001,$FFCD,$000,$FFCF,$FFFF,$FFD1,$FFFF,$FFD3,$FFFE,$FFD5,$FFFD,$FFD8,$FFFC,$FFDA,$FFFB
        dc.w $FFDC,$FFF9,$FFDE,$FFF8,$FFE0,$FFF7,$FFE2,$FFF5,$FFE4,$FFF4,$FFE7,$FFF2,$FFE9,$FFF0,$FFEB,$FFEE
        dc.w $FFEC,$FFEC,$FFEE,$FFEB,$FFF0,$FFE9,$FFF2,$FFE7,$FFF4,$FFE4,$FFF5,$FFE2,$FFF7,$FFE0,$FFF8,$FFDE
        dc.w $FFF9,$FFDC,$FFFB,$FFDA,$FFFC,$FFD8,$FFFD,$FFD5,$FFFE,$FFD3,$FFFF,$FFD1,$FFFF,$FFCF,$000,$FFCD
        dc.w $001,$FFCB,$001,$FFCA,$001,$FFC8,$002,$FFC6,$002,$FFC5,$002,$FFC3,$002,$FFC2,$002,$FFC1
        dc.w $002,$FFBF,$002,$FFBE,$002,$FFBE,$002,$FFBD,$001,$FFBC,$001,$FFBC,$001,$FFBB,$000,$FFBB
        dc.w $000,$FFBB,$000,$FFBB,$FFFF,$FFBB,$FFFF,$FFBC,$FFFF,$FFBC,$FFFE,$FFBD,$FFFE,$FFBE,$FFFE,$FFBE
        dc.w $FFFE,$FFBF,$FFFE,$FFC1,$FFFE,$FFC2,$FFFE,$FFC3,$FFFE,$FFC5,$FFFE,$FFC6,$FFFF,$FFC8,$FFFF,$FFCA
        dc.w $FFFF,$FFCB,$000,$FFCD,$001,$FFCF,$001,$FFD1,$002,$FFD3,$003,$FFD5,$004,$FFD8,$005,$FFDA
        dc.w $007,$FFDC,$008,$FFDE,$009,$FFE0,$00B,$FFE2,$00C,$FFE4,$00E,$FFE7,$010,$FFE9,$012,$FFEB
        dc.w $014,$FFEC,$015,$FFEE,$017,$FFF0,$019,$FFF2,$01C,$FFF4,$01E,$FFF5,$020,$FFF7,$022,$FFF8
        dc.w $024,$FFF9,$026,$FFFB,$028,$FFFC,$02B,$FFFD,$02D,$FFFE,$02F,$FFFF,$031,$FFFF,$033,$000
        dc.w $035,$001,$036,$001,$038,$001,$03A,$002,$03B,$002,$03D,$002,$03E,$002,$03F,$002
        dc.w $041,$002,$042,$002,$042,$002,$043,$002,$044,$001,$044,$001,$045,$001,$045,$000
        dc.w $037,$000,$039,$001,$03A,$003,$03C,$004,$03D,$006,$03F,$008,$040,$009,$041,$00B
        dc.w $041,$00D,$042,$00F,$042,$011,$042,$012,$042,$014,$042,$016,$041,$017,$040,$019
        dc.w $03F,$01A,$03D,$01B,$03C,$01C,$03A,$01D,$038,$01E,$036,$01F,$034,$01F,$032,$020
        dc.w $030,$020,$02E,$020,$02C,$020,$02A,$021,$028,$020,$026,$020,$024,$020,$022,$020
        dc.w $020,$020,$01F,$020,$01D,$020,$01C,$020,$01B,$020,$01A,$021,$019,$021,$018,$022
        dc.w $017,$023,$017,$024,$016,$025,$015,$026,$015,$027,$015,$029,$014,$02A,$014,$02C
        dc.w $013,$02E,$013,$030,$012,$032,$011,$034,$010,$036,$010,$038,$00F,$03A,$00D,$03C
        dc.w $00C,$03E,$00B,$03F,$00A,$041,$008,$042,$007,$043,$005,$044,$003,$045,$002,$045
        dc.w $000,$045,$FFFE,$045,$FFFD,$045,$FFFB,$044,$FFF9,$043,$FFF8,$042,$FFF6,$041,$FFF5,$03F
        dc.w $FFF4,$03E,$FFF3,$03C,$FFF1,$03A,$FFF0,$038,$FFF0,$036,$FFEF,$034,$FFEE,$032,$FFED,$030
        dc.w $FFED,$02E,$FFEC,$02C,$FFEC,$02A,$FFEB,$029,$FFEB,$027,$FFEB,$026,$FFEA,$025,$FFE9,$024
        dc.w $FFE9,$023,$FFE8,$022,$FFE7,$021,$FFE6,$021,$FFE5,$020,$FFE4,$020,$FFE3,$020,$FFE1,$020
        dc.w $FFE0,$020,$FFDE,$020,$FFDC,$020,$FFDA,$020,$FFD8,$020,$FFD6,$021,$FFD4,$020,$FFD2,$020
        dc.w $FFD0,$020,$FFCE,$020,$FFCC,$01F,$FFCA,$01F,$FFC8,$01E,$FFC6,$01D,$FFC4,$01C,$FFC3,$01B
        dc.w $FFC1,$01A,$FFC0,$019,$FFBF,$017,$FFBE,$016,$FFBE,$014,$FFBE,$012,$FFBE,$011,$FFBE,$00F
        dc.w $FFBF,$00D,$FFBF,$00B,$FFC0,$009,$FFC1,$008,$FFC3,$006,$FFC4,$004,$FFC6,$003,$FFC7,$001
        dc.w $FFC9,$000,$FFCB,$FFFF,$FFCC,$FFFD,$FFCE,$FFFC,$FFD0,$FFFB,$FFD1,$FFFA,$FFD3,$FFF9,$FFD4,$FFF8
        dc.w $FFD5,$FFF7,$FFD6,$FFF7,$FFD7,$FFF6,$FFD8,$FFF5,$FFD8,$FFF4,$FFD9,$FFF3,$FFD9,$FFF2,$FFD9,$FFF1
        dc.w $FFD9,$FFF0,$FFD9,$FFEE,$FFD8,$FFED,$FFD8,$FFEC,$FFD7,$FFEA,$FFD6,$FFE8,$FFD6,$FFE7,$FFD5,$FFE5
        dc.w $FFD4,$FFE3,$FFD4,$FFE1,$FFD3,$FFDF,$FFD3,$FFDD,$FFD2,$FFDA,$FFD2,$FFD8,$FFD2,$FFD6,$FFD2,$FFD4
        dc.w $FFD2,$FFD2,$FFD2,$FFD0,$FFD3,$FFCE,$FFD4,$FFCD,$FFD5,$FFCB,$FFD6,$FFCA,$FFD7,$FFC9,$FFD8,$FFC8
        dc.w $FFDA,$FFC7,$FFDB,$FFC6,$FFDD,$FFC6,$FFDF,$FFC6,$FFE1,$FFC6,$FFE3,$FFC6,$FFE5,$FFC7,$FFE7,$FFC7
        dc.w $FFE9,$FFC8,$FFEB,$FFC9,$FFED,$FFCA,$FFEF,$FFCB,$FFF0,$FFCC,$FFF2,$FFCE,$FFF4,$FFCF,$FFF5,$FFD0
        dc.w $FFF7,$FFD1,$FFF8,$FFD2,$FFF9,$FFD4,$FFFB,$FFD4,$FFFC,$FFD5,$FFFD,$FFD6,$FFFE,$FFD6,$FFFF,$FFD7
        dc.w $000,$FFD7,$001,$FFD7,$002,$FFD6,$003,$FFD6,$004,$FFD5,$005,$FFD4,$007,$FFD4,$008,$FFD2
        dc.w $009,$FFD1,$00B,$FFD0,$00C,$FFCF,$00E,$FFCE,$010,$FFCC,$011,$FFCB,$013,$FFCA,$015,$FFC9
        dc.w $017,$FFC8,$019,$FFC7,$01B,$FFC7,$01D,$FFC6,$01F,$FFC6,$021,$FFC6,$023,$FFC6,$025,$FFC6
        dc.w $026,$FFC7,$028,$FFC8,$029,$FFC9,$02A,$FFCA,$02B,$FFCB,$02C,$FFCD,$02D,$FFCE,$02E,$FFD0
        dc.w $02E,$FFD2,$02E,$FFD4,$02E,$FFD6,$02E,$FFD8,$02E,$FFDA,$02D,$FFDD,$02D,$FFDF,$02C,$FFE1
        dc.w $02C,$FFE3,$02B,$FFE5,$02A,$FFE7,$02A,$FFE8,$029,$FFEA,$028,$FFEC,$028,$FFED,$027,$FFEE
        dc.w $027,$FFF0,$027,$FFF1,$027,$FFF2,$027,$FFF3,$028,$FFF4,$028,$FFF5,$029,$FFF6,$02A,$FFF7
        dc.w $02B,$FFF7,$02C,$FFF8,$02D,$FFF9,$02F,$FFFA,$030,$FFFB,$032,$FFFC,$034,$FFFD,$035,$FFFF

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

; Eight scene-specific logo ripples (tools/gen_tables.py wave_banks).
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
        dc.w $088,$088,$088,$088,$088,$099,$099,$099,$099,$099,$099,$099,$099,$099,$0AA,$0AA
        dc.w $0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA
        dc.w $0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA
        dc.w $099,$099,$099,$099,$099,$099,$099,$099,$099,$099,$099,$099,$099,$099,$099,$099
        dc.w $099,$099,$099,$099,$099,$099,$099,$099,$099,$099,$099,$099,$099,$099,$099,$099
        dc.w $099,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA
        dc.w $0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA
        dc.w $0AA,$0AA,$0AA,$099,$099,$099,$099,$099,$099,$099,$099,$099,$088,$088,$088,$088
        dc.w $088,$088,$088,$088,$088,$077,$077,$077,$077,$077,$077,$077,$077,$077,$066,$066
        dc.w $066,$066,$066,$066,$066,$066,$066,$066,$066,$066,$066,$066,$066,$066,$066,$066
        dc.w $066,$066,$066,$066,$066,$066,$066,$066,$066,$066,$066,$066,$066,$066,$066,$066
        dc.w $077,$077,$077,$077,$077,$077,$077,$077,$077,$077,$077,$077,$077,$077,$077,$077
        dc.w $077,$077,$077,$077,$077,$077,$077,$077,$077,$077,$077,$077,$077,$077,$077,$077
        dc.w $077,$066,$066,$066,$066,$066,$066,$066,$066,$066,$066,$066,$066,$066,$066,$066
        dc.w $066,$066,$066,$066,$066,$066,$066,$066,$066,$066,$066,$066,$066,$066,$066,$066
        dc.w $066,$066,$066,$077,$077,$077,$077,$077,$077,$077,$077,$077,$088,$088,$088,$088
        dc.w $088,$088,$099,$099,$099,$099,$0AA,$0AA,$0AA,$0BB,$0BB,$0BB,$0BB,$0BB,$0CC,$0CC
        dc.w $0CC,$0CC,$0CC,$0CC,$0CC,$0CC,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0CC,$0CC,$0CC
        dc.w $0CC,$0CC,$0CC,$0CC,$0CC,$0CC,$0BB,$0BB,$0BB,$0BB,$0BB,$0BB,$0AA,$0AA,$0AA,$0AA
        dc.w $0AA,$099,$099,$099,$099,$099,$099,$099,$088,$088,$088,$088,$088,$088,$088,$088
        dc.w $088,$088,$088,$088,$088,$088,$088,$088,$088,$099,$099,$099,$099,$099,$099,$099
        dc.w $0AA,$0AA,$0AA,$0AA,$0AA,$0BB,$0BB,$0BB,$0BB,$0BB,$0BB,$0CC,$0CC,$0CC,$0CC,$0CC
        dc.w $0CC,$0CC,$0CC,$0CC,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0CC,$0CC,$0CC,$0CC,$0CC
        dc.w $0CC,$0CC,$0CC,$0BB,$0BB,$0BB,$0BB,$0BB,$0AA,$0AA,$0AA,$099,$099,$099,$099,$088
        dc.w $088,$088,$077,$077,$077,$077,$066,$066,$066,$055,$055,$055,$055,$055,$044,$044
        dc.w $044,$044,$044,$044,$044,$044,$033,$033,$033,$033,$033,$033,$033,$044,$044,$044
        dc.w $044,$044,$044,$044,$044,$044,$055,$055,$055,$055,$055,$055,$066,$066,$066,$066
        dc.w $066,$077,$077,$077,$077,$077,$077,$077,$088,$088,$088,$088,$088,$088,$088,$088
        dc.w $088,$088,$088,$088,$088,$088,$088,$088,$088,$077,$077,$077,$077,$077,$077,$077
        dc.w $066,$066,$066,$066,$066,$055,$055,$055,$055,$055,$055,$044,$044,$044,$044,$044
        dc.w $044,$044,$044,$044,$033,$033,$033,$033,$033,$033,$033,$044,$044,$044,$044,$044
        dc.w $044,$044,$044,$055,$055,$055,$055,$055,$066,$066,$066,$077,$077,$077,$077,$088
        dc.w $088,$088,$088,$099,$099,$099,$099,$099,$099,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA
        dc.w $0BB,$0BB,$0BB,$0BB,$0BB,$0BB,$0BB,$0CC,$0CC,$0CC,$0CC,$0CC,$0CC,$0CC,$0CC,$0CC
        dc.w $0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD
        dc.w $0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD
        dc.w $0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0CC,$0CC,$0CC,$0CC,$0CC,$0CC,$0CC
        dc.w $0CC,$0CC,$0CC,$0CC,$0CC,$0BB,$0BB,$0BB,$0BB,$0BB,$0BB,$0BB,$0BB,$0BB,$0BB,$0BB
        dc.w $0BB,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$099,$099,$099
        dc.w $099,$099,$099,$099,$099,$099,$099,$099,$099,$099,$088,$088,$088,$088,$088,$088
        dc.w $088,$088,$088,$088,$088,$088,$088,$077,$077,$077,$077,$077,$077,$077,$077,$077
        dc.w $077,$077,$077,$077,$066,$066,$066,$066,$066,$066,$066,$066,$066,$066,$066,$066
        dc.w $055,$055,$055,$055,$055,$055,$055,$055,$055,$055,$055,$055,$044,$044,$044,$044
        dc.w $044,$044,$044,$044,$044,$044,$044,$044,$033,$033,$033,$033,$033,$033,$033,$033
        dc.w $033,$033,$033,$033,$033,$033,$033,$033,$033,$033,$033,$033,$033,$033,$033,$033
        dc.w $033,$033,$033,$033,$033,$033,$033,$033,$033,$033,$033,$033,$033,$033,$033,$033
        dc.w $033,$044,$044,$044,$044,$044,$044,$044,$044,$044,$055,$055,$055,$055,$055,$055
        dc.w $055,$066,$066,$066,$066,$066,$066,$066,$077,$077,$077,$077,$077,$077,$088,$088
        dc.w $088,$088,$099,$099,$099,$099,$0AA,$0AA,$0AA,$0AA,$0AA,$0BB,$0BB,$0BB,$0BB,$0BB
        dc.w $0BB,$0BB,$0BB,$0BB,$0BB,$0BB,$0BB,$0BB,$0BB,$0BB,$0BB,$0BB,$0BB,$0BB,$0AA,$0AA
        dc.w $0AA,$0AA,$0AA,$0AA,$0AA,$099,$099,$099,$099,$099,$099,$099,$099,$099,$099,$099
        dc.w $099,$099,$099,$099,$099,$099,$099,$099,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0BB,$0BB
        dc.w $0BB,$0BB,$0BB,$0CC,$0CC,$0CC,$0CC,$0CC,$0CC,$0CC,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD
        dc.w $0DD,$0DD,$0DD,$0DD,$0CC,$0CC,$0CC,$0CC,$0CC,$0CC,$0CC,$0BB,$0BB,$0BB,$0BB,$0AA
        dc.w $0AA,$0AA,$0AA,$099,$099,$099,$099,$088,$088,$088,$088,$088,$088,$077,$077,$077
        dc.w $077,$077,$077,$077,$077,$077,$077,$077,$077,$077,$077,$077,$088,$088,$088,$088
        dc.w $088,$088,$088,$088,$088,$099,$099,$099,$099,$099,$099,$099,$099,$099,$099,$099
        dc.w $099,$099,$099,$099,$088,$088,$088,$088,$088,$088,$077,$077,$077,$077,$066,$066
        dc.w $066,$066,$055,$055,$055,$055,$044,$044,$044,$044,$044,$044,$044,$033,$033,$033
        dc.w $033,$033,$033,$033,$033,$033,$033,$044,$044,$044,$044,$044,$044,$044,$055,$055
        dc.w $055,$055,$055,$066,$066,$066,$066,$066,$066,$077,$077,$077,$077,$077,$077,$077
        dc.w $077,$077,$077,$077,$077,$077,$077,$077,$077,$077,$077,$077,$066,$066,$066,$066
        dc.w $066,$066,$066,$055,$055,$055,$055,$055,$055,$055,$055,$055,$055,$055,$055,$055
        dc.w $055,$055,$055,$055,$055,$055,$066,$066,$066,$066,$066,$077,$077,$077,$077,$088
        dc.w $088,$088,$088,$088,$088,$088,$077,$077,$077,$077,$077,$077,$077,$077,$077,$077
        dc.w $077,$077,$077,$066,$066,$066,$066,$066,$066,$066,$066,$066,$066,$066,$066,$066
        dc.w $066,$066,$066,$077,$077,$077,$077,$077,$077,$077,$077,$077,$077,$077,$077,$088
        dc.w $088,$088,$088,$088,$088,$088,$099,$099,$099,$099,$099,$099,$099,$0AA,$0AA,$0AA
        dc.w $0AA,$0AA,$0AA,$0AA,$0BB,$0BB,$0BB,$0BB,$0BB,$0BB,$0BB,$0BB,$0CC,$0CC,$0CC,$0CC
        dc.w $0CC,$0CC,$0CC,$0CC,$0CC,$0CC,$0CC,$0CC,$0CC,$0CC,$0CC,$0CC,$0CC,$0CC,$0CC,$0CC
        dc.w $0CC,$0CC,$0CC,$0CC,$0CC,$0CC,$0CC,$0CC,$0CC,$0CC,$0CC,$0CC,$0BB,$0BB,$0BB,$0BB
        dc.w $0BB,$0BB,$0BB,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$099,$099,$099,$099,$099,$088,$088
        dc.w $088,$088,$088,$077,$077,$077,$077,$077,$066,$066,$066,$066,$066,$066,$055,$055
        dc.w $055,$055,$055,$055,$055,$044,$044,$044,$044,$044,$044,$044,$044,$044,$044,$044
        dc.w $044,$044,$044,$044,$044,$044,$044,$044,$044,$044,$044,$044,$044,$044,$044,$044
        dc.w $044,$044,$044,$044,$044,$055,$055,$055,$055,$055,$055,$055,$055,$066,$066,$066
        dc.w $066,$066,$066,$066,$077,$077,$077,$077,$077,$077,$077,$088,$088,$088,$088,$088
        dc.w $088,$088,$099,$099,$099,$099,$099,$099,$099,$099,$099,$099,$099,$099,$0AA,$0AA
        dc.w $0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$099,$099
        dc.w $099,$099,$099,$099,$099,$099,$099,$099,$099,$099,$099,$088,$088,$088,$088,$088
        dc.w $088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088
        dc.w $088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$099,$099,$099,$099,$099
        dc.w $099,$0AA,$0AA,$0AA,$0AA,$0AA,$0BB,$0BB,$0BB,$0BB,$0BB,$0CC,$0CC,$0CC,$0CC,$0CC
        dc.w $0CC,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0EE,$0EE,$0EE,$0EE,$0EE,$0EE,$0EE,$0EE
        dc.w $0EE,$0EE,$0EE,$0EE,$0EE,$0EE,$0EE,$0EE,$0EE,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD
        dc.w $0CC,$0CC,$0CC,$0CC,$0CC,$0CC,$0BB,$0BB,$0BB,$0BB,$0BB,$0AA,$0AA,$0AA,$0AA,$0AA
        dc.w $099,$099,$099,$099,$099,$099,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088
        dc.w $088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088
        dc.w $088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088
        dc.w $088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$077,$077,$077,$077,$077
        dc.w $077,$066,$066,$066,$066,$066,$055,$055,$055,$055,$055,$044,$044,$044,$044,$044
        dc.w $044,$033,$033,$033,$033,$033,$033,$033,$022,$022,$022,$022,$022,$022,$022,$022
        dc.w $022,$022,$022,$022,$022,$022,$022,$022,$022,$033,$033,$033,$033,$033,$033,$033
        dc.w $044,$044,$044,$044,$044,$044,$055,$055,$055,$055,$055,$066,$066,$066,$066,$066
        dc.w $077,$077,$077,$077,$077,$077,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088
        dc.w $088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088
        dc.w $088,$088,$088,$088,$088,$088,$088,$099,$099,$099,$099,$099,$099,$099,$099,$099
        dc.w $099,$099,$099,$099,$099,$099,$099,$099,$099,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA
        dc.w $0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0AA
        dc.w $0AA,$0AA,$0AA,$0AA,$0AA,$099,$099,$099,$099,$099,$099,$099,$099,$099,$099,$099
        dc.w $099,$099,$099,$099,$099,$099,$099,$099,$099,$099,$088,$088,$088,$088,$088,$088
        dc.w $088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088
        dc.w $088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088
        dc.w $088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088
        dc.w $088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088
        dc.w $088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088
        dc.w $088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088,$088
        dc.w $088,$088,$088,$088,$088,$088,$088,$077,$077,$077,$077,$077,$077,$077,$077,$077
        dc.w $077,$077,$077,$077,$077,$077,$077,$077,$077,$077,$077,$077,$066,$066,$066,$066
        dc.w $066,$066,$066,$066,$066,$066,$066,$066,$066,$066,$066,$066,$066,$066,$066,$066
        dc.w $066,$066,$066,$066,$066,$066,$066,$066,$077,$077,$077,$077,$077,$077,$077,$077
        dc.w $077,$077,$077,$077,$077,$077,$077,$077,$077,$077,$088,$088,$088,$088,$088,$088

; Copper floor: static ramp and 8 scenes x 4 pulse levels x 32 colours.
; Generated by tools/gen_tables.py bar_palettes; lives outside DMA-visible chip RAM.
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
        dc.w $523,$934,$B55,$F88,$F88,$B55,$934,$523
        dc.w $543,$954,$B85,$FB8,$FB8,$B85,$954,$543
        dc.w $544,$974,$BB5,$FE9,$FE9,$BB5,$974,$544
        dc.w $534,$947,$B5A,$F9C,$F9C,$B5A,$947,$534
        dc.w $744,$A45,$C77,$F99,$F99,$C77,$A45,$744
        dc.w $754,$A75,$C97,$FC9,$FC9,$C97,$A75,$754
        dc.w $765,$A85,$CC7,$FEA,$FEA,$CC7,$A85,$765
        dc.w $746,$A58,$C7A,$FAD,$FAD,$C7A,$A58,$746
        dc.w $856,$B67,$C88,$FAA,$FAA,$C88,$B67,$856
        dc.w $876,$B87,$CA8,$FCA,$FCA,$CA8,$B87,$876
        dc.w $877,$B97,$CC8,$FEB,$FEB,$CC8,$B97,$877
        dc.w $867,$B79,$C8B,$FBD,$FBD,$C8B,$B79,$867
        dc.w $302,$612,$944,$D78,$D78,$944,$612,$302
        dc.w $412,$824,$B46,$F8A,$F8A,$B46,$824,$412
        dc.w $422,$842,$B84,$FB8,$FB8,$B84,$842,$422
        dc.w $433,$864,$BB7,$FEB,$FEB,$BB7,$864,$433
        dc.w $424,$734,$A55,$D89,$D89,$A55,$734,$424
        dc.w $534,$945,$B57,$F9B,$F9B,$B57,$945,$534
        dc.w $544,$954,$B95,$FB9,$FB9,$B95,$954,$544
        dc.w $544,$975,$BB8,$FEB,$FEB,$BB8,$975,$544
        dc.w $645,$845,$A77,$D9A,$D9A,$A77,$845,$645
        dc.w $745,$A57,$C78,$FAB,$FAB,$C78,$A57,$745
        dc.w $755,$A75,$CA7,$FCA,$FCA,$CA7,$A75,$755
        dc.w $766,$A87,$CC9,$FEC,$FEC,$CC9,$A87,$766
        dc.w $757,$967,$B88,$EAB,$EAB,$B88,$967,$757
        dc.w $867,$B78,$C89,$FBC,$FBC,$C89,$B78,$867
        dc.w $877,$B87,$CB8,$FCB,$FCB,$CB8,$B87,$877
        dc.w $877,$B98,$CCA,$FEC,$FEC,$CCA,$B98,$877
        dc.w $013,$124,$447,$78B,$78B,$447,$124,$013
        dc.w $124,$246,$47A,$8BD,$8BD,$47A,$246,$124
        dc.w $234,$368,$5BC,$AEF,$AEF,$5BC,$368,$234
        dc.w $324,$648,$97C,$DBF,$DBF,$97C,$648,$324
        dc.w $234,$345,$558,$89B,$89B,$558,$345,$234
        dc.w $345,$457,$58B,$9BD,$9BD,$58B,$457,$345
        dc.w $445,$479,$6BC,$BEF,$BEF,$6BC,$479,$445
        dc.w $445,$759,$A8C,$DBF,$DBF,$A8C,$759,$445
        dc.w $446,$457,$779,$9AC,$9AC,$779,$457,$446
        dc.w $457,$578,$79B,$ACD,$ACD,$79B,$578,$457
        dc.w $567,$68A,$7CD,$BEF,$BEF,$7CD,$68A,$567
        dc.w $657,$87A,$A9D,$DCF,$DCF,$A9D,$87A,$657
        dc.w $567,$678,$88A,$ABC,$ABC,$88A,$678,$567
        dc.w $678,$789,$8AC,$BCE,$BCE,$8AC,$789,$678
        dc.w $778,$79B,$9CD,$CEF,$CEF,$9CD,$79B,$778
        dc.w $778,$98B,$BAD,$ECF,$ECF,$BAD,$98B,$778
        dc.w $311,$622,$A44,$D87,$D87,$A44,$622,$311
        dc.w $421,$842,$B74,$FB7,$FB7,$B74,$842,$421
        dc.w $432,$863,$B95,$FD9,$FD9,$B95,$863,$432
        dc.w $444,$877,$BBB,$FEE,$FEE,$BBB,$877,$444
        dc.w $433,$744,$B55,$D98,$D98,$B55,$744,$433
        dc.w $543,$954,$B85,$FB8,$FB8,$B85,$954,$543
        dc.w $544,$974,$BA6,$FDA,$FDA,$BA6,$974,$544
        dc.w $555,$988,$BBB,$FEE,$FEE,$BBB,$988,$555
        dc.w $644,$855,$B77,$DA9,$DA9,$B77,$855,$644
        dc.w $754,$A75,$C97,$FC9,$FC9,$C97,$A75,$754
        dc.w $765,$A86,$CA7,$FDA,$FDA,$CA7,$A86,$765
        dc.w $777,$A99,$CCC,$FEE,$FEE,$CCC,$A99,$777
        dc.w $766,$977,$C88,$EBA,$EBA,$C88,$977,$766
        dc.w $876,$B87,$CA8,$FCA,$FCA,$CA8,$B87,$876
        dc.w $877,$B97,$CB9,$FEB,$FEB,$CB9,$B97,$877
        dc.w $888,$BAA,$CCC,$FEE,$FEE,$CCC,$BAA,$888
        dc.w $202,$412,$844,$B78,$B78,$844,$412,$202
        dc.w $312,$622,$B44,$E88,$E88,$B44,$622,$312
        dc.w $422,$844,$B86,$FBA,$FBA,$B86,$844,$422
        dc.w $434,$866,$BA9,$FDD,$FDD,$BA9,$866,$434
        dc.w $424,$534,$955,$B89,$B89,$955,$534,$424
        dc.w $434,$744,$B55,$E99,$E99,$B55,$744,$434
        dc.w $544,$955,$B97,$FBB,$FBB,$B97,$955,$544
        dc.w $545,$977,$BBA,$FDD,$FDD,$BBA,$977,$545
        dc.w $545,$745,$A77,$C9A,$C9A,$A77,$745,$545
        dc.w $645,$855,$C77,$EAA,$EAA,$C77,$855,$645
        dc.w $755,$A77,$CA8,$FCB,$FCB,$CA8,$A77,$755
        dc.w $767,$A88,$CBA,$FDD,$FDD,$CBA,$A88,$767
        dc.w $757,$867,$B88,$CAB,$CAB,$B88,$867,$757
        dc.w $767,$977,$C88,$EBB,$EBB,$C88,$977,$767
        dc.w $877,$B88,$CB9,$FCC,$FCC,$CB9,$B88,$877
        dc.w $878,$B99,$CCB,$FEE,$FEE,$CCB,$B99,$878
        dc.w $113,$226,$459,$89C,$89C,$459,$226,$113
        dc.w $224,$346,$57A,$ABD,$ABD,$57A,$346,$224
        dc.w $312,$624,$A46,$D8A,$D8A,$A46,$624,$312
        dc.w $424,$846,$B89,$FBD,$FBD,$B89,$846,$424
        dc.w $334,$447,$56A,$9AC,$9AC,$56A,$447,$334
        dc.w $445,$457,$68B,$BBD,$BBD,$68B,$457,$445
        dc.w $434,$745,$B57,$D9B,$D9B,$B57,$745,$434
        dc.w $545,$957,$B9A,$FBD,$FBD,$B9A,$957,$545
        dc.w $446,$558,$77A,$AAD,$AAD,$77A,$558,$446
        dc.w $557,$678,$79B,$BCD,$BCD,$79B,$678,$557
        dc.w $645,$857,$B78,$DAB,$DAB,$B78,$857,$645
        dc.w $757,$A78,$CAA,$FCD,$FCD,$CAA,$A78,$757
        dc.w $667,$779,$89B,$BBD,$BBD,$89B,$779,$667
        dc.w $778,$789,$9AC,$CCE,$CCE,$9AC,$789,$778
        dc.w $767,$978,$C89,$EBC,$EBC,$C89,$978,$767
        dc.w $878,$B89,$CBB,$FCE,$FCE,$CBB,$B89,$878
        dc.w $201,$400,$822,$B66,$B66,$822,$400,$201
        dc.w $301,$611,$B43,$E77,$E77,$B43,$611,$301
        dc.w $422,$832,$B54,$FA8,$FA8,$B54,$832,$422
        dc.w $433,$866,$B99,$FDC,$FDC,$B99,$866,$433
        dc.w $423,$522,$944,$B77,$B77,$944,$522,$423
        dc.w $423,$733,$B54,$E88,$E88,$B54,$733,$423
        dc.w $544,$944,$B65,$FB9,$FB9,$B65,$944,$544
        dc.w $544,$977,$BAA,$FDC,$FDC,$BAA,$977,$544
        dc.w $544,$744,$A55,$C88,$C88,$A55,$744,$544
        dc.w $644,$844,$C76,$E99,$E99,$C76,$844,$644
        dc.w $755,$A65,$C77,$FBA,$FBA,$C77,$A65,$755
        dc.w $766,$A88,$CAA,$FDD,$FDD,$CAA,$A88,$766
        dc.w $756,$855,$B77,$C99,$C99,$B77,$855,$756
        dc.w $756,$966,$C87,$EAA,$EAA,$C87,$966,$756
        dc.w $877,$B77,$C98,$FCB,$FCB,$C98,$B77,$877
        dc.w $877,$B99,$CBB,$FED,$FED,$CBB,$B99,$877
        dc.w $412,$822,$B44,$F88,$F88,$B44,$822,$412
        dc.w $422,$854,$B96,$FCA,$FCA,$B96,$854,$422
        dc.w $423,$836,$B59,$FAC,$FAC,$B59,$836,$423
        dc.w $434,$867,$BBB,$FEE,$FEE,$BBB,$867,$434
        dc.w $534,$944,$B55,$F99,$F99,$B55,$944,$534
        dc.w $544,$965,$BA7,$FCB,$FCB,$BA7,$965,$544
        dc.w $544,$947,$B6A,$FBC,$FBC,$B6A,$947,$544
        dc.w $545,$978,$BBB,$FEE,$FEE,$BBB,$978,$545
        dc.w $745,$A55,$C77,$FAA,$FAA,$C77,$A55,$745
        dc.w $755,$A77,$CA8,$FDB,$FDB,$CA8,$A77,$755
        dc.w $756,$A68,$C7A,$FBD,$FBD,$C7A,$A68,$756
        dc.w $767,$A89,$CCC,$FEE,$FEE,$CCC,$A89,$767
        dc.w $867,$B77,$C88,$FBB,$FBB,$C88,$B77,$867
        dc.w $877,$B98,$CB9,$FDC,$FDC,$CB9,$B98,$877
        dc.w $877,$B79,$C9B,$FCD,$FCD,$C9B,$B79,$877
        dc.w $878,$B9A,$CCC,$FEE,$FEE,$CCC,$B9A,$878

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
cop_aurora:
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
