; ---------------------------------------------------------------------------
; NEON VECTORS row/tick ProTracker replay core.
;
; 4-channel M.K., PAL VBlank tick = 50 Hz = ProTracker BPM 125 tick rate.
; Supported commands: Cxx volume, F01..F1F speed. The generated module uses F06.
; Only CPU side work happens here, so it is safe to run with interrupts off.
;
; Paula channel registers are addressed through a1 = CUSTOM+AUD0LCH+channel*16:
; 0(a1) location, 4(a1) length in words, 6(a1) period, 8(a1) volume. The custom
; register offsets are too large for the 8 bit displacement of an indexed
; addressing mode, so the channel base is formed with LEA instead.
; ---------------------------------------------------------------------------

MOD_Init:
        move.l  ptr_mod,a0
        moveq   #0,d0
        move.b  950(a0),d0                ; song length
        beq     .bad
        cmp.b   #128,d0
        bhi     .bad
        move.b  d0,mod_songlen

; Build the absolute sample starts from the pattern count and the sample
; lengths, so a row only has to index a table.
        lea     952(a0),a1
        moveq   #0,d1
        moveq   #0,d7
        move.b  mod_songlen,d7
        subq.w  #1,d7
.maxpat:
        moveq   #0,d2
        move.b  (a1)+,d2
        cmp.w   d2,d1
        bhs     .maxnext
        move.w  d2,d1
.maxnext:
        dbra    d7,.maxpat
        addq.w  #1,d1
        lsl.l   #8,d1                     ; *256
        lsl.l   #2,d1                     ; *1024
        lea     1084(a0),a1
        adda.l  d1,a1
        lea     mod_sample_ptrs,a2
        lea     20(a0),a3
        move.l  a1,a4
        moveq   #30,d7
.sptr:
        move.l  a4,(a2)+
        moveq   #0,d0
        move.w  22(a3),d0                 ; sample length, words
        add.l   d0,d0                     ; words to bytes
        adda.l  d0,a4
        lea     30(a3),a3
        dbra    d7,.sptr

        clr.b   mod_order
        clr.b   mod_row
        move.b  #5,mod_tick               ; force row 0 on the first frame
        move.b  #6,mod_speed
        moveq   #1,d0
        rts
.bad:
        clr.b   mod_songlen
        moveq   #0,d0
        rts

; One 50 Hz tracker tick. speed ticks per row.
MOD_Tick:
        tst.b   mod_songlen
        beq     .done
        addq.b  #1,mod_tick
        move.b  mod_tick,d0
        cmp.b   mod_speed,d0
        blo     .done
        clr.b   mod_tick
        bsr     MOD_Row
.done:
        rts

MOD_Row:
        move.l  ptr_mod,a0
        moveq   #0,d0
        move.b  mod_order,d0
        lea     952(a0),a1
        moveq   #0,d1
        move.b  0(a1,d0.w),d1
        lsl.l   #8,d1
        lsl.l   #2,d1                     ; pattern * 1024
        lea     1084(a0),a2
        adda.l  d1,a2
        moveq   #0,d2
        move.b  mod_row,d2
        lsl.w   #4,d2                     ; row * 16
        adda.l  d2,a2

        lea     CUSTOM,a6
        clr.w   mod_trigger_mask
        moveq   #0,d6
.ch:
        lea     CUSTOM+AUD0LCH,a1
        move.w  d6,d7
        lsl.w   #4,d7
        lea     0(a1,d7.w),a1             ; a1 = this channel's Paula registers

        move.l  (a2)+,d0
        move.l  d0,d1
        swap    d1
        andi.w  #$0FFF,d1                 ; period
        move.l  d0,d2
        rol.l   #8,d2                     ; top byte to the bottom (shift counts > 8 need a register)
        andi.w  #$00F0,d2                 ; sample number, high nibble
        move.w  d0,d3
        lsr.w   #8,d3
        lsr.w   #4,d3                     ; sample number, low nibble
        or.w    d3,d2                     ; d2 = sample number
        move.l  d0,d3
        lsr.w   #8,d3
        andi.w  #$000F,d3                 ; d3 = effect
        move.w  d0,d4
        andi.w  #$00FF,d4                 ; d4 = parameter

        tst.w   d2
        beq     .effects
        cmp.w   #31,d2
        bhi     .effects
        subq.w  #1,d2                     ; zero based sample
        move.w  d2,d5
        lsl.w   #2,d5
        lea     mod_sample_ptrs,a3
        move.l  0(a3,d5.w),a4
        mulu    #30,d2
        lea     20(a0,d2.w),a5

; Sample default volume also applies to sample-only rows.
        moveq   #0,d5
        move.b  25(a5),d5
        cmp.w   #64,d5
        bls     .volok
        moveq   #64,d5
.volok:
        move.w  d5,8(a1)

        tst.w   d1
        beq     .effects

; Clear this channel's DMA bit first: writing location/length/period while the
; channel is fetching would restart the sample at a half updated address.
        moveq   #1,d5
        lsl.w   d6,d5
        move.w  d5,DMACON(a6)
        or.w    d5,mod_trigger_mask
        move.l  a4,(a1)
        move.w  22(a5),d5                 ; sample length, words; AUDxLEN counts words
        cmp.w   #1,d5
        bhs     .lenok
        moveq   #1,d5                     ; 0 would mean 65536 words
.lenok:
        move.w  d5,4(a1)
        move.w  d1,6(a1)

; Cache the loop location/length and install it after DMA has latched the
; initial location and length.
        moveq   #0,d1
        move.w  26(a5),d1                 ; loop start, words
        add.l   d1,d1
        adda.l  d1,a4
        move.w  28(a5),d1
        cmp.w   #1,d1
        bhi     .loopok
; ProTracker loop length 0 or 1 means one-shot. Point Paula at a real silent
; chip RAM word instead of at the end of the sample data.
        move.l  ptr_silence,a4
        moveq   #1,d1
.loopok:
        move.w  d6,d5
        lsl.w   #2,d5
        lea     mod_loop_ptrs,a3
        move.l  a4,0(a3,d5.w)
        move.w  d6,d5
        add.w   d5,d5
        lea     mod_loop_lens,a3
        move.w  d1,0(a3,d5.w)

.effects:
        cmp.w   #$0C,d3
        bne     .fxf
        cmp.w   #64,d4
        bls     .cok
        moveq   #64,d4
.cok:
        move.w  d4,8(a1)
.fxf:
        cmp.w   #$0F,d3
        bne     .next
        tst.w   d4
        beq     .next
        cmp.w   #31,d4
        bhi     .next                     ; BPM mode is deliberately unsupported
        move.b  d4,mod_speed
.next:
        addq.w  #1,d6
        cmp.w   #4,d6
        blo     .ch

; Re-enable the triggered channels together. Two raster lines are far more
; than the documented audio DMA settling interval.
        tst.w   mod_trigger_mask
        beq     .advance
        moveq   #2,d3
        bsr     WaitLines
        move.w  mod_trigger_mask,d0
        ori.w   #DMAF_SETCLR,d0
        move.w  d0,DMACON(a6)
        moveq   #2,d3
        bsr     WaitLines

; Paula has now fetched the initial location and length, so the loop or the
; silent terminal word can replace them.
        moveq   #0,d6
.loopregs:
        moveq   #1,d0
        lsl.w   d6,d0
        and.w   mod_trigger_mask,d0
        beq     .lnext
        lea     CUSTOM+AUD0LCH,a1
        move.w  d6,d7
        lsl.w   #4,d7
        lea     0(a1,d7.w),a1
        move.w  d6,d5
        lsl.w   #2,d5
        lea     mod_loop_ptrs,a3
        move.l  0(a3,d5.w),(a1)
        move.w  d6,d5
        add.w   d5,d5
        lea     mod_loop_lens,a3
        move.w  0(a3,d5.w),4(a1)          ; words, not words minus one
.lnext:
        addq.w  #1,d6
        cmp.w   #4,d6
        blo     .loopregs

.advance:
        addq.b  #1,mod_row
        cmp.b   #64,mod_row
        blo     .ret
        clr.b   mod_row
        addq.b  #1,mod_order
        move.b  mod_order,d0
        cmp.b   mod_songlen,d0
        blo     .ret
        clr.b   mod_order
.ret:
        rts

; Stop Paula and let any in flight DMA word finish before the chipset is
; handed back, so a channel cannot keep fetching chip RAM after return.
MOD_Stop:
        lea     CUSTOM,a6
        move.w  #DMAF_AUDIO,DMACON(a6)
        moveq   #2,d3
        bsr     WaitLines
        rts

        section data,data
mod_sample_ptrs:  ds.l 31
mod_loop_ptrs:    ds.l 4
mod_loop_lens:    ds.w 4
mod_trigger_mask: dc.w 0
mod_songlen:      dc.b 0
mod_order:        dc.b 0
mod_row:          dc.b 0
mod_tick:         dc.b 0
mod_speed:        dc.b 6
        even
