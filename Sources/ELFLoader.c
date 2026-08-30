#include "ELFLoader.h"
#include <sys/mman.h>
#include <sys/types.h>
#include <sys/time.h>
#include <sys/select.h>
#include <sys/errno.h>
#include <sys/stat.h>
#include <unistd.h>
#include <dlfcn.h>
#include <pthread.h>
#include <semaphore.h>
#include <sched.h>
#include <fcntl.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <time.h>
#include <wchar.h>
#include <zlib.h>
#ifdef __APPLE__
#include <mach/mach.h>
#else
#include <sys/syscall.h>
#endif

#define GBR_PT_LOAD 1u
#define GBR_SHT_RELA 4u
#define GBR_SHT_DYNSYM 11u
#define GBR_SHN_UNDEF 0u
#define GBR_R_AARCH64_ABS64 257u
#define GBR_R_AARCH64_GLOB_DAT 1025u
#define GBR_R_AARCH64_JUMP_SLOT 1026u
#define GBR_R_AARCH64_RELATIVE 1027u

#pragma pack(push, 1)
typedef struct {
    unsigned char e_ident[16];
    uint16_t e_type;
    uint16_t e_machine;
    uint32_t e_version;
    uint64_t e_entry;
    uint64_t e_phoff;
    uint64_t e_shoff;
    uint32_t e_flags;
    uint16_t e_ehsize;
    uint16_t e_phentsize;
    uint16_t e_phnum;
    uint16_t e_shentsize;
    uint16_t e_shnum;
    uint16_t e_shstrndx;
} GBREhdr;

typedef struct {
    uint32_t p_type;
    uint32_t p_flags;
    uint64_t p_offset;
    uint64_t p_vaddr;
    uint64_t p_paddr;
    uint64_t p_filesz;
    uint64_t p_memsz;
    uint64_t p_align;
} GBRPhdr;

typedef struct {
    uint32_t sh_name;
    uint32_t sh_type;
    uint64_t sh_flags;
    uint64_t sh_addr;
    uint64_t sh_offset;
    uint64_t sh_size;
    uint32_t sh_link;
    uint32_t sh_info;
    uint64_t sh_addralign;
    uint64_t sh_entsize;
} GBRShdr;

typedef struct {
    uint32_t st_name;
    unsigned char st_info;
    unsigned char st_other;
    uint16_t st_shndx;
    uint64_t st_value;
    uint64_t st_size;
} GBRSym;

typedef struct {
    uint64_t r_offset;
    uint64_t r_info;
    int64_t r_addend;
} GBRRela;
#pragma pack(pop)

static size_t gbr_page_size(void) {
    long p = sysconf(_SC_PAGESIZE);
    return p > 0 ? (size_t)p : 4096u;
}
static uint64_t gbr_align_down(uint64_t v, uint64_t a) { return v & ~(a - 1); }
static uint64_t gbr_align_up(uint64_t v, uint64_t a) { return (v + a - 1) & ~(a - 1); }

// ---------------- compatibility shims ----------------
static unsigned char gbr_bionic_sF_storage[2048];
static int gbr_pthread_atfork(void (*prepare)(void), void (*parent)(void), void (*child)(void)) {
    (void)prepare; (void)parent; (void)child; return 0;
}

static int *gbr_android_errno(void) {
#ifdef __APPLE__
    return __error();
#else
    return &errno;
#endif
}
static void *gbr_memalign(size_t alignment, size_t size) {
    void *p = NULL;
    if (alignment < sizeof(void *)) alignment = sizeof(void *);
    if (posix_memalign(&p, alignment, size) != 0) return NULL;
    return p;
}
static void gbr_android_set_abort_message(const char *message) { (void)message; }
static size_t gbr_strlen_chk(const char *s, size_t maxlen) {
    size_t n = strlen(s);
    if (n >= maxlen) return n;
    return n;
}
static void *gbr_memmove_chk(void *dst, const void *src, size_t len, size_t dstlen) {
    if (len > dstlen) return NULL;
    return memmove(dst, src, len);
}
static void gbr_FD_SET_chk(int fd, fd_set *set, size_t set_size) {
    (void)set_size;
    if (fd >= 0 && fd < FD_SETSIZE) FD_SET(fd, set);
}
static int gbr_FD_ISSET_chk(int fd, const fd_set *set, size_t set_size) {
    (void)set_size;
    if (fd < 0 || fd >= FD_SETSIZE) return 0;
    return FD_ISSET(fd, set);
}
static int gbr_vsnprintf_chk(char *dst, size_t maxlen, int flags, size_t dstlen, const char *fmt, va_list ap) {
    (void)flags;
    size_t n = maxlen < dstlen ? maxlen : dstlen;
    return vsnprintf(dst, n, fmt, ap);
}
static size_t gbr_ctype_mb_cur_max(void) { return (size_t)MB_CUR_MAX; }
static void gbr_sincos(double x, double *s, double *c) { if (s) *s = sin(x); if (c) *c = cos(x); }
static void gbr_sincosf(float x, float *s, float *c) { if (s) *s = sinf(x); if (c) *c = cosf(x); }
static int gbr_pthread_getattr_np(pthread_t thread, pthread_attr_t *attr) {
    if (!attr) return EINVAL;
#ifdef __APPLE__
    int r = pthread_attr_init(attr);
    if (r != 0) return r;
    void *top = pthread_get_stackaddr_np(thread);
    size_t size = pthread_get_stacksize_np(thread);
    if (!top || !size) return 0;
    void *base = (void *)((uintptr_t)top - size);
    (void)pthread_attr_setstack(attr, base, size);
    return 0;
#else
    return pthread_getattr_np(thread, attr);
#endif
}
static int gbr_sem_timedwait(sem_t *sem, const struct timespec *abs_timeout) {
    if (!abs_timeout) return sem_wait(sem);
    for (;;) {
        if (sem_trywait(sem) == 0) return 0;
        if (errno != EAGAIN) return -1;
        struct timespec now;
        clock_gettime(CLOCK_REALTIME, &now);
        if (now.tv_sec > abs_timeout->tv_sec || (now.tv_sec == abs_timeout->tv_sec && now.tv_nsec >= abs_timeout->tv_nsec)) {
            errno = ETIMEDOUT;
            return -1;
        }
        struct timespec nap = {0, 1000000};
        nanosleep(&nap, NULL);
    }
}
typedef int (*gbr_dl_iter_cb)(void *, size_t, void *);
static int gbr_dl_iterate_phdr(gbr_dl_iter_cb cb, void *data) { (void)cb; (void)data; return 0; }
static int gbr_pthread_condattr_setclock(pthread_condattr_t *attr, clockid_t clock_id) { (void)attr; (void)clock_id; return 0; }
static int gbr_prctl(int option, ...) { (void)option; return 0; }
static int gbr_sched_getaffinity(pid_t pid, size_t cpusetsize, void *mask) {
    (void)pid;
    if (mask && cpusetsize) memset(mask, 0xff, cpusetsize);
    return 0;
}
static int gbr_sched_setaffinity(pid_t pid, size_t cpusetsize, const void *mask) { (void)pid; (void)cpusetsize; (void)mask; return 0; }
static pid_t gbr_gettid(void) {
#ifdef __APPLE__
    return (pid_t)pthread_mach_thread_np(pthread_self());
#else
    return (pid_t)syscall(SYS_gettid);
#endif
}
static off_t gbr_lseek64(int fd, off_t offset, int whence) { return lseek(fd, offset, whence); }
static int gbr_system_property_get(const char *name, char *value) { (void)name; if (value) value[0] = '\0'; return 0; }
static const void *gbr_system_property_find(const char *name) { (void)name; return NULL; }
static int gbr_system_property_read(const void *pi, char *name, char *value) { (void)pi; if (name) name[0] = '\0'; if (value) value[0] = '\0'; return 0; }

static int gbr_android_log_vprint(int prio, const char *tag, const char *fmt, va_list ap) {
    (void)prio;
    if (tag) fprintf(stderr, "[%s] ", tag);
    int r = vfprintf(stderr, fmt ? fmt : "", ap);
    fputc('\n', stderr);
    return r;
}
static int gbr_android_log_print(int prio, const char *tag, const char *fmt, ...) {
    va_list ap; va_start(ap, fmt); int r = gbr_android_log_vprint(prio, tag, fmt, ap); va_end(ap); return r;
}
static int gbr_android_log_write(int prio, const char *tag, const char *text) {
    (void)prio; fprintf(stderr, "[%s] %s\n", tag ? tag : "android", text ? text : ""); return 0;
}

// Android native window / looper / sensor placeholders. These are relocation-safe stubs,
// not a real graphics/input implementation yet.
static uintptr_t gbr_stub_zero(void) { return 0; }
static uintptr_t gbr_stub_one(void) { return 1; }
static uintptr_t gbr_stub_ptr(void) { static uintptr_t token = 0x47425231; return (uintptr_t)&token; }
static int gbr_stub_minus3(void) { return -3; }
static int gbr_window_width(void *w) { (void)w; return 1280; }
static int gbr_window_height(void *w) { (void)w; return 720; }
static float gbr_sensor_float(void *s) { (void)s; return 0.0f; }
static const char *gbr_sensor_text(void *s) { (void)s; return "iOS shim"; }

// EGL placeholder surface. It only lets relocations resolve. Real EGL->Metal comes next.
static void *gbr_egl_get_display(void *native) { (void)native; return (void *)0x1; }
static unsigned int gbr_egl_initialize(void *d, int *major, int *minor) { if (!d) return 0; if (major) *major = 1; if (minor) *minor = 5; return 1; }
static int gbr_egl_get_error(void) { return 0x3000; }
static const char *gbr_egl_query_string(void *d, int name) { (void)d; (void)name; return "GoreBoxRunner EGL stub"; }
static void *gbr_egl_get_proc(const char *name) { return gbr_compat_resolve_symbol(name); }

void *gbr_compat_resolve_symbol(const char *name) {
    if (!name || !*name) return NULL;
#define EQ(x) (strcmp(name, (x)) == 0)
    if (EQ("__sF")) return (void *)gbr_bionic_sF_storage;
    if (EQ("pthread_atfork")) return (void *)&gbr_pthread_atfork;
    if (EQ("inflateInit2_")) return (void *)&inflateInit2_;
    if (EQ("inflate")) return (void *)&inflate;
    if (EQ("inflateEnd")) return (void *)&inflateEnd;
    if (EQ("__errno")) return (void *)&gbr_android_errno;
    if (EQ("memalign")) return (void *)&gbr_memalign;
    if (EQ("android_set_abort_message")) return (void *)&gbr_android_set_abort_message;
    if (EQ("__strlen_chk")) return (void *)&gbr_strlen_chk;
    if (EQ("__memmove_chk")) return (void *)&gbr_memmove_chk;
    if (EQ("__FD_SET_chk")) return (void *)&gbr_FD_SET_chk;
    if (EQ("__FD_ISSET_chk")) return (void *)&gbr_FD_ISSET_chk;
    if (EQ("__vsnprintf_chk")) return (void *)&gbr_vsnprintf_chk;
    if (EQ("__ctype_get_mb_cur_max")) return (void *)&gbr_ctype_mb_cur_max;
    if (EQ("sincos")) return (void *)&gbr_sincos;
    if (EQ("sincosf")) return (void *)&gbr_sincosf;
    if (EQ("pthread_getattr_np")) return (void *)&gbr_pthread_getattr_np;
    if (EQ("sem_timedwait")) return (void *)&gbr_sem_timedwait;
    if (EQ("dl_iterate_phdr")) return (void *)&gbr_dl_iterate_phdr;
    if (EQ("pthread_condattr_setclock")) return (void *)&gbr_pthread_condattr_setclock;
    if (EQ("prctl")) return (void *)&gbr_prctl;
    if (EQ("sched_getaffinity")) return (void *)&gbr_sched_getaffinity;
    if (EQ("sched_setaffinity")) return (void *)&gbr_sched_setaffinity;
    if (EQ("gettid")) return (void *)&gbr_gettid;
    if (EQ("lseek64")) return (void *)&gbr_lseek64;
    if (EQ("__system_property_get")) return (void *)&gbr_system_property_get;
    if (EQ("__system_property_find")) return (void *)&gbr_system_property_find;
    if (EQ("__system_property_read")) return (void *)&gbr_system_property_read;
    if (EQ("__android_log_print")) return (void *)&gbr_android_log_print;
    if (EQ("__android_log_vprint")) return (void *)&gbr_android_log_vprint;
    if (EQ("__android_log_write")) return (void *)&gbr_android_log_write;

    if (strncmp(name, "ANativeWindow_", 14) == 0) {
        if (EQ("ANativeWindow_getWidth")) return (void *)&gbr_window_width;
        if (EQ("ANativeWindow_getHeight")) return (void *)&gbr_window_height;
        return (void *)&gbr_stub_zero;
    }
    if (strncmp(name, "ALooper_", 8) == 0) {
        if (EQ("ALooper_pollAll")) return (void *)&gbr_stub_minus3;
        if (EQ("ALooper_prepare") || EQ("ALooper_forThread")) return (void *)&gbr_stub_ptr;
        return (void *)&gbr_stub_zero;
    }
    if (strncmp(name, "ASensor", 7) == 0) {
        if (EQ("ASensor_getResolution")) return (void *)&gbr_sensor_float;
        if (EQ("ASensor_getName") || EQ("ASensor_getVendor")) return (void *)&gbr_sensor_text;
        if (strstr(name, "getInstance") || strstr(name, "getDefaultSensor") || strstr(name, "createEventQueue")) return (void *)&gbr_stub_ptr;
        return (void *)&gbr_stub_zero;
    }
    if (strncmp(name, "egl", 3) == 0) {
        if (EQ("eglGetDisplay")) return (void *)&gbr_egl_get_display;
        if (EQ("eglInitialize")) return (void *)&gbr_egl_initialize;
        if (EQ("eglGetError")) return (void *)&gbr_egl_get_error;
        if (EQ("eglQueryString")) return (void *)&gbr_egl_query_string;
        if (EQ("eglGetProcAddress")) return (void *)&gbr_egl_get_proc;
        if (EQ("eglGetCurrentContext") || EQ("eglGetCurrentSurface") || EQ("eglCreateContext") || EQ("eglCreateWindowSurface") || EQ("eglCreatePbufferSurface")) return (void *)&gbr_stub_ptr;
        // Boolean-returning EGL calls get success. This is intentionally a bootstrap stub.
        return (void *)&gbr_stub_one;
    }
#undef EQ
    return NULL;
}

static void gbr_record_unresolved(GBRELFImage *img, const char *name) {
    img->unresolved_count++;
    uint32_t slot = img->unresolved_count - 1;
    if (slot < 16) {
        snprintf(img->unresolved[slot], sizeof(img->unresolved[slot]), "%s", name ? name : "<unnamed>");
    }
}

static int gbr_validate(const uint8_t *data, size_t length, const GBREhdr **eh_out) {
    if (!data || length < sizeof(GBREhdr)) return -1;
    const GBREhdr *eh = (const GBREhdr *)data;
    if (eh->e_ident[0] != 0x7f || eh->e_ident[1] != 'E' || eh->e_ident[2] != 'L' || eh->e_ident[3] != 'F') return -2;
    if (eh->e_ident[4] != 2 || eh->e_ident[5] != 1 || eh->e_machine != 183) return -3;
    if (eh->e_phentsize < sizeof(GBRPhdr) || eh->e_phoff + (uint64_t)eh->e_phnum * eh->e_phentsize > length) return -4;
    *eh_out = eh;
    return 0;
}

int gbr_elf_load_image(const uint8_t *data, size_t length, GBRELFImage *out_image) {
    if (!out_image) return -100;
    memset(out_image, 0, sizeof(*out_image));
    const GBREhdr *eh = NULL;
    int vr = gbr_validate(data, length, &eh);
    if (vr != 0) return vr;

    uint64_t minv = UINT64_MAX, maxv = 0;
    size_t page = gbr_page_size();
    for (uint16_t i = 0; i < eh->e_phnum; ++i) {
        const GBRPhdr *ph = (const GBRPhdr *)(data + eh->e_phoff + (uint64_t)i * eh->e_phentsize);
        if (ph->p_type != GBR_PT_LOAD) continue;
        out_image->load_segment_count++;
        if (ph->p_offset + ph->p_filesz > length || ph->p_filesz > ph->p_memsz) return -5;
        uint64_t lo = gbr_align_down(ph->p_vaddr, page);
        uint64_t hi = gbr_align_up(ph->p_vaddr + ph->p_memsz, page);
        if (lo < minv) minv = lo;
        if (hi > maxv) maxv = hi;
    }
    if (minv == UINT64_MAX || maxv <= minv) return -6;
    size_t span = (size_t)(maxv - minv);
    errno = 0;
    void *map = mmap(NULL, span, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (map == MAP_FAILED || !map) { out_image->last_errno = errno; return -7; }
    out_image->mapping = map;
    out_image->mapping_size = span;
    out_image->min_vaddr = minv;
    out_image->load_bias = (uint64_t)(uintptr_t)map - minv;
    out_image->entry_address = out_image->load_bias + eh->e_entry;

    for (uint16_t i = 0; i < eh->e_phnum; ++i) {
        const GBRPhdr *ph = (const GBRPhdr *)(data + eh->e_phoff + (uint64_t)i * eh->e_phentsize);
        if (ph->p_type != GBR_PT_LOAD) continue;
        void *dst = (void *)(uintptr_t)(out_image->load_bias + ph->p_vaddr);
        memcpy(dst, data + ph->p_offset, (size_t)ph->p_filesz);
        if (ph->p_memsz > ph->p_filesz) memset((uint8_t *)dst + ph->p_filesz, 0, (size_t)(ph->p_memsz - ph->p_filesz));
    }

    // Section-header based dynsym + RELA resolver (exact GoreBox 13.7.9 libraries have these tables).
    const GBRShdr *sh = NULL;
    if (eh->e_shoff && eh->e_shnum && eh->e_shentsize >= sizeof(GBRShdr) && eh->e_shoff + (uint64_t)eh->e_shnum * eh->e_shentsize <= length) {
        sh = (const GBRShdr *)(data + eh->e_shoff);
    }
    const GBRShdr *dynsym_sh = NULL;
    const GBRSym *dynsyms = NULL;
    const char *dynstr = NULL;
    size_t dynsym_count = 0;
    if (sh) {
        for (uint16_t i = 0; i < eh->e_shnum; ++i) {
            const GBRShdr *s = (const GBRShdr *)((const uint8_t *)sh + (uint64_t)i * eh->e_shentsize);
            if (s->sh_type == GBR_SHT_DYNSYM && s->sh_offset + s->sh_size <= length && s->sh_entsize >= sizeof(GBRSym) && s->sh_link < eh->e_shnum) {
                const GBRShdr *strs = (const GBRShdr *)((const uint8_t *)sh + (uint64_t)s->sh_link * eh->e_shentsize);
                if (strs->sh_offset + strs->sh_size <= length) {
                    dynsym_sh = s;
                    dynsyms = (const GBRSym *)(data + s->sh_offset);
                    dynstr = (const char *)(data + strs->sh_offset);
                    dynsym_count = (size_t)(s->sh_size / s->sh_entsize);
                    break;
                }
            }
        }
    }

    if (sh && dynsym_sh && dynsyms && dynstr) {
        void *self_handle = dlopen(NULL, RTLD_NOW);
        for (uint16_t i = 0; i < eh->e_shnum; ++i) {
            const GBRShdr *s = (const GBRShdr *)((const uint8_t *)sh + (uint64_t)i * eh->e_shentsize);
            if (s->sh_type != GBR_SHT_RELA || s->sh_entsize < sizeof(GBRRela) || s->sh_offset + s->sh_size > length) continue;
            size_t count = (size_t)(s->sh_size / s->sh_entsize);
            for (size_t j = 0; j < count; ++j) {
                const GBRRela *r = (const GBRRela *)(data + s->sh_offset + j * s->sh_entsize);
                uint32_t type = (uint32_t)(r->r_info & 0xffffffffu);
                uint32_t sym_index = (uint32_t)(r->r_info >> 32);
                out_image->relocation_total++;
                if (r->r_offset < minv || r->r_offset + sizeof(uint64_t) > maxv) continue;
                uint64_t *where = (uint64_t *)(uintptr_t)(out_image->load_bias + r->r_offset);
                if (type == GBR_R_AARCH64_RELATIVE) {
                    *where = out_image->load_bias + (uint64_t)r->r_addend;
                    out_image->relocation_applied++;
                    continue;
                }
                if (type != GBR_R_AARCH64_GLOB_DAT && type != GBR_R_AARCH64_JUMP_SLOT && type != GBR_R_AARCH64_ABS64) continue;
                if (sym_index >= dynsym_count) continue;
                const GBRSym *sym = (const GBRSym *)((const uint8_t *)dynsyms + (uint64_t)sym_index * dynsym_sh->sh_entsize);
                const char *name = sym->st_name ? dynstr + sym->st_name : "";
                void *resolved = NULL;
                if (sym->st_shndx != GBR_SHN_UNDEF && sym->st_value) {
                    resolved = (void *)(uintptr_t)(out_image->load_bias + sym->st_value);
                } else {
                    // Prefer compatibility adapters for Android/Bionic names; host Darwin is fallback.
                    resolved = gbr_compat_resolve_symbol(name);
                    if (!resolved && self_handle) resolved = dlsym(self_handle, name);
                }
                if (!resolved) {
                    gbr_record_unresolved(out_image, name);
                    continue;
                }
                *where = (uint64_t)(uintptr_t)resolved + (uint64_t)r->r_addend;
                out_image->relocation_applied++;
            }
        }
        if (self_handle) dlclose(self_handle);
    }

    // Apply final protection HOST-PAGE by HOST-PAGE.
    //
    // This matters on iOS devices with 16 KiB pages. GoreBox's Android ELF files
    // are linked for 4 KiB pages, so an RX PT_LOAD and a later RW PT_LOAD can
    // occupy different Android pages but collapse into the SAME iOS host page.
    // Applying mprotect segment-by-segment would let the later RW segment remove
    // execute permission from the earlier code in that host page.
    //
    // Merge the permissions first. If iOS refuses a W+X collision page, retain
    // RX for the current controlled bootstrap calls. Relocations are already
    // complete at this point, and the current JNI/RayFire probes only need reads
    // from their data/GOT. A production runtime will need a stronger solution
    // for pages that must remain writable while code in the same 16 KiB page runs.
    out_image->host_page_size = (uint32_t)page;
    size_t host_pages = (span + page - 1) / page;
    uint8_t *page_prot = (uint8_t *)calloc(host_pages, sizeof(uint8_t));
    if (!page_prot) return -9;

    for (uint16_t i = 0; i < eh->e_phnum; ++i) {
        const GBRPhdr *ph = (const GBRPhdr *)(data + eh->e_phoff + (uint64_t)i * eh->e_phentsize);
        if (ph->p_type != GBR_PT_LOAD) continue;
        uint64_t lo = gbr_align_down(ph->p_vaddr, page);
        uint64_t hi = gbr_align_up(ph->p_vaddr + ph->p_memsz, page);
        int prot = 0;
        if (ph->p_flags & 4u) prot |= PROT_READ;
        if (ph->p_flags & 2u) prot |= PROT_WRITE;
        if (ph->p_flags & 1u) prot |= PROT_EXEC;
        for (uint64_t va = lo; va < hi; va += page) {
            size_t pi = (size_t)((va - minv) / page);
            if (pi < host_pages) page_prot[pi] |= (uint8_t)prot;
        }
    }

    for (size_t pi = 0; pi < host_pages; ++pi) {
        int prot = page_prot[pi];
        if (prot == 0) continue;
        void *addr = (uint8_t *)map + pi * page;
        const int has_wx = ((prot & PROT_WRITE) && (prot & PROT_EXEC));
        if (has_wx) out_image->wx_collision_pages++;
        errno = 0;
        if (mprotect(addr, page, prot) == 0) {
            if (has_wx) out_image->rwx_pages++;
            continue;
        }
        int first_errno = errno;
        if (has_wx) {
            // W^X fallback for controlled bootstrap. Prefer executable/readable
            // code over writable data because the probes do not mutate guest data.
            errno = 0;
            if (mprotect(addr, page, PROT_READ | PROT_EXEC) == 0) {
                out_image->rx_fallback_pages++;
                continue;
            }
        }
        out_image->last_errno = first_errno ? first_errno : errno;
        free(page_prot);
        return -8;
    }
    free(page_prot);
    return 0;
}

void gbr_elf_unload_image(GBRELFImage *image) {
    if (!image) return;
    if (image->mapping && image->mapping_size) munmap(image->mapping, image->mapping_size);
    memset(image, 0, sizeof(*image));
}

void *gbr_elf_find_symbol(const uint8_t *data, size_t length, const GBRELFImage *image, const char *wanted) {
    if (!data || !image || !image->mapping || !wanted) return NULL;
    const GBREhdr *eh = NULL;
    if (gbr_validate(data, length, &eh) != 0) return NULL;
    if (!eh->e_shoff || !eh->e_shnum || eh->e_shentsize < sizeof(GBRShdr) || eh->e_shoff + (uint64_t)eh->e_shnum * eh->e_shentsize > length) return NULL;
    const uint8_t *shbase = data + eh->e_shoff;
    for (uint16_t i = 0; i < eh->e_shnum; ++i) {
        const GBRShdr *s = (const GBRShdr *)(shbase + (uint64_t)i * eh->e_shentsize);
        if (s->sh_type != GBR_SHT_DYNSYM || s->sh_entsize < sizeof(GBRSym) || s->sh_offset + s->sh_size > length || s->sh_link >= eh->e_shnum) continue;
        const GBRShdr *strs = (const GBRShdr *)(shbase + (uint64_t)s->sh_link * eh->e_shentsize);
        if (strs->sh_offset + strs->sh_size > length) continue;
        const char *strtab = (const char *)(data + strs->sh_offset);
        size_t count = (size_t)(s->sh_size / s->sh_entsize);
        for (size_t j = 0; j < count; ++j) {
            const GBRSym *sym = (const GBRSym *)(data + s->sh_offset + j * s->sh_entsize);
            if (!sym->st_name || sym->st_shndx == GBR_SHN_UNDEF || !sym->st_value) continue;
            const char *name = strtab + sym->st_name;
            if (strcmp(name, wanted) == 0) return (void *)(uintptr_t)(image->load_bias + sym->st_value);
        }
    }
    return NULL;
}

const char *gbr_elf_unresolved_at(const GBRELFImage *image, uint32_t index) {
    if (!image || index >= image->unresolved_count || index >= 16) return NULL;
    return image->unresolved[index];
}

// ---------------- tiny fake JNI environment ----------------
typedef uintptr_t (*GBRAnyJNI)(void);
static uintptr_t gbr_jni_zero(void) { return 0; }
static uintptr_t gbr_jni_nonnull(void) { static uintptr_t token = 0x4a4e4931; return (uintptr_t)&token; }
static int32_t gbr_jni_attach(void *vm, void **env, void *args);
static void *gbr_jni_find_class(void *env, const char *name) { (void)env; (void)name; return (void *)gbr_jni_nonnull(); }
static int32_t gbr_jni_register_natives(void *env, void *clazz, const void *methods, int32_t count) { (void)env; (void)clazz; (void)methods; (void)count; return 0; }
static void gbr_jni_exception_clear(void *env) { (void)env; }

typedef struct { void **functions; } GBRJNIEnvObj;
typedef struct { void **functions; } GBRJavaVMObj;
static void *gbr_env_table[232];
static void *gbr_vm_table[8];
static GBRJNIEnvObj gbr_env_obj;
static GBRJavaVMObj gbr_vm_obj;
static int gbr_jni_ready = 0;

static void gbr_prepare_jni(void) {
    if (gbr_jni_ready) return;
    for (size_t i = 0; i < 232; ++i) gbr_env_table[i] = (void *)&gbr_jni_zero;
    for (size_t i = 0; i < 8; ++i) gbr_vm_table[i] = (void *)&gbr_jni_zero;
    // JNIEnv function table indices from jni.h.
    gbr_env_table[6] = (void *)&gbr_jni_find_class;       // FindClass @ 0x30
    gbr_env_table[18] = (void *)&gbr_jni_exception_clear; // ExceptionClear @ 0x90
    // Return non-null IDs/refs for common lookup functions used by registration/bootstrap code.
    gbr_env_table[33] = (void *)&gbr_jni_nonnull; // GetMethodID
    gbr_env_table[94] = (void *)&gbr_jni_nonnull; // GetFieldID
    gbr_env_table[113] = (void *)&gbr_jni_nonnull; // GetStaticMethodID
    gbr_env_table[144] = (void *)&gbr_jni_nonnull; // GetStaticFieldID
    gbr_env_table[215] = (void *)&gbr_jni_register_natives; // RegisterNatives @ 0x6b8
    gbr_vm_table[4] = (void *)&gbr_jni_attach; // AttachCurrentThread @ 0x20
    gbr_env_obj.functions = gbr_env_table;
    gbr_vm_obj.functions = gbr_vm_table;
    gbr_jni_ready = 1;
}
static int32_t gbr_jni_attach(void *vm, void **env, void *args) { (void)vm; (void)args; gbr_prepare_jni(); if (env) *env = &gbr_env_obj; return 0; }

int32_t gbr_call_fake_jni_onload(void *function_address) {
    if (!function_address) return -1;
    gbr_prepare_jni();
    typedef int32_t (*OnLoadFn)(void *, void *);
    OnLoadFn fn = (OnLoadFn)function_address;
    return fn(&gbr_vm_obj, NULL);
}

void gbr_call_void_function(void *function_address) {
    if (!function_address) return;
    typedef void (*Fn)(void);
    ((Fn)function_address)();
}
