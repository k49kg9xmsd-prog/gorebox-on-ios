// GoreBoxRunner 0.4.2
// Android/Bionic arm64 jmp_buf bridge for an iOS/Darwin host.
//
// Bionic AArch64 jmp_buf is 32 x 64-bit words (256 bytes). Relevant layout:
//   word 0   sigflag/cookie
//   word 1   sigmask
//   word 2   core_base (x18-x30, sp)
//   word 16  float_base (d8-d15)
//   word 24  checksum (Bionic-private; not consumed by this local bridge)
//
// The old 0.4.1 bridge began core registers at byte 8, which is one word early.
// That makes a later longjmp restore the wrong LR/SP. This version stores and
// restores the register payload at the real Bionic offsets. We intentionally
// don't call Darwin setjmp/sigsetjmp at all.

.text
.align 2

.globl _gbr_bionic_setjmp
_gbr_bionic_setjmp:
    // x0 = guest Bionic jmp_buf.
    // Mark "signal mask not saved". The bridge owns both setjmp/longjmp, so the
    // exact Bionic cookie/checksum encoding isn't required for our local pair.
    str     xzr, [x0, #0]          // words 0..1: no signal-mask restore

    // word 2 / byte 16: x18-x30 + sp. Pairing follows Bionic's core slot area.
    mov     x10, sp
    stp     x18, x19, [x0, #16]
    stp     x20, x21, [x0, #32]
    stp     x22, x23, [x0, #48]
    stp     x24, x25, [x0, #64]
    stp     x26, x27, [x0, #80]
    stp     x28, x29, [x0, #96]
    stp     x30, x10, [x0, #112]

    // word 16 / byte 128: d8-d15.
    stp     d8,  d9,  [x0, #128]
    stp     d10, d11, [x0, #144]
    stp     d12, d13, [x0, #160]
    stp     d14, d15, [x0, #176]

    // Keep the guest continuation intact while recording the checkpoint.
    stp     x0, x30, [sp, #-16]!
    bl      _gbr_bionic_setjmp_checkpoint
    ldp     x0, x30, [sp], #16

    mov     w0, wzr
    ret

.globl _gbr_bionic_longjmp
_gbr_bionic_longjmp:
    // x0 = guest jmp_buf, w1 = requested return value.
    stp     x0, x1, [sp, #-16]!
    bl      _gbr_bionic_longjmp_checkpoint
    ldp     x0, x1, [sp], #16

    // Restore float and callee-saved core state from the actual Bionic slots.
    ldp     d8,  d9,  [x0, #128]
    ldp     d10, d11, [x0, #144]
    ldp     d12, d13, [x0, #160]
    ldp     d14, d15, [x0, #176]

    ldp     x18, x19, [x0, #16]
    ldp     x20, x21, [x0, #32]
    ldp     x22, x23, [x0, #48]
    ldp     x24, x25, [x0, #64]
    ldp     x26, x27, [x0, #80]
    ldp     x28, x29, [x0, #96]
    ldp     x30, x10, [x0, #112]

    // longjmp(env, 0) must make setjmp return 1.
    cmp     w1, #0
    cset    w9, eq
    add     w0, w1, w9

    mov     sp, x10
    ret
