// GoreBoxRunner 0.4.1
// Android/Bionic arm64 jmp_buf bridge.
//
// Bionic AArch64 jmp_buf is 32 x 64-bit longs (256 bytes). The core register
// layout below follows Android bionic's arm64 setjmp ABI. We deliberately use
// the "signal mask not saved" magic so we never mix Android sigset layout with
// Darwin's signal ABI.

.text
.align 2

.globl _gbr_bionic_setjmp
_gbr_bionic_setjmp:
    // x0 = guest Bionic jmp_buf
    // magic = 0x53657200 (no signal mask)
    movz    w9, #0x7200
    movk    w9, #0x5365, lsl #16
    str     w9, [x0, #0]

    // Core base byte offset = 8.
    mov     x10, sp
    stp     x30, x10, [x0, #8]
    stp     x28, x29, [x0, #24]
    stp     x26, x27, [x0, #40]
    stp     x24, x25, [x0, #56]
    stp     x22, x23, [x0, #72]
    stp     x20, x21, [x0, #88]
    str     x19,      [x0, #104]

    // Float base byte offset = 112.
    stp     d14, d15, [x0, #112]
    stp     d12, d13, [x0, #128]
    stp     d10, d11, [x0, #144]
    stp     d8,  d9,  [x0, #160]

    // Save env + original LR around the host checkpoint helper. The saved
    // jmp_buf already contains the guest caller's SP/LR, so the helper cannot
    // change the guest continuation.
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

    // Restore core registers and guest SP/LR.
    ldp     x30, x10, [x0, #8]
    ldp     x28, x29, [x0, #24]
    ldp     x26, x27, [x0, #40]
    ldp     x24, x25, [x0, #56]
    ldp     x22, x23, [x0, #72]
    ldp     x20, x21, [x0, #88]
    ldr     x19,      [x0, #104]

    ldp     d14, d15, [x0, #112]
    ldp     d12, d13, [x0, #128]
    ldp     d10, d11, [x0, #144]
    ldp     d8,  d9,  [x0, #160]

    mov     sp, x10

    // longjmp(env, 0) must make setjmp return 1.
    cmp     w1, #0
    cset    w9, eq
    add     w0, w1, w9
    ret
