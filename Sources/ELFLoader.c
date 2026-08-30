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
#include <limits.h>
#include <wchar.h>
#include <zlib.h>
#ifdef __APPLE__
#include <mach/mach.h>
#include <libkern/OSCacheControl.h>
#else
#include <sys/syscall.h>
#endif

#define GBR_PT_LOAD 1u
#define GBR_PT_DYNAMIC 2u
#define GBR_DT_NULL 0ll
#define GBR_DT_INIT 12ll
#define GBR_DT_INIT_ARRAY 25ll
#define GBR_DT_INIT_ARRAYSZ 27ll
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

typedef struct {
    int64_t d_tag;
    uint64_t d_val;
} GBRDyn;
#pragma pack(pop)

static size_t gbr_page_size(void) {
    long p = sysconf(_SC_PAGESIZE);
    return p > 0 ? (size_t)p : 4096u;
}
static uint64_t gbr_align_down(uint64_t v, uint64_t a) { return v & ~(a - 1); }
static uint64_t gbr_align_up(uint64_t v, uint64_t a) { return (v + a - 1) & ~(a - 1); }


// ---------------- durable checkpoints ----------------
static char gbr_checkpoint_path[PATH_MAX];

void gbr_set_checkpoint_path(const char *path) {
    if (!path) {
        gbr_checkpoint_path[0] = '\0';
        return;
    }
    snprintf(gbr_checkpoint_path, sizeof(gbr_checkpoint_path), "%s", path);
}

void gbr_checkpoint_now(const char *message) {
    if (!gbr_checkpoint_path[0] || !message) return;
    int fd = open(gbr_checkpoint_path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) return;
    const char *p = message;
    size_t left = strlen(message);
    while (left) {
        ssize_t n = write(fd, p, left);
        if (n <= 0) break;
        p += (size_t)n;
        left -= (size_t)n;
    }
    (void)fsync(fd);
#ifdef __APPLE__
#ifdef F_FULLFSYNC
    (void)fcntl(fd, F_FULLFSYNC);
#endif
#endif
    close(fd);
}

void gbr_clear_checkpoint(void) {
    if (gbr_checkpoint_path[0]) (void)unlink(gbr_checkpoint_path);
}

static void gbr_flush_instruction_cache(void *address, size_t length) {
    if (!address || !length) return;
#ifdef __APPLE__
    sys_icache_invalidate(address, length);
#else
    __builtin___clear_cache((char *)address, (char *)address + length);
#endif
}

// ---------------- compatibility shims ----------------
static unsigned char gbr_bionic_sF_storage[2048];

// ---------------- Bionic stdio / varargs-safe bootstrap bridge ----------------
// Bionic's FILE layout is not Darwin's FILE layout.  In addition, Android arm64
// and Darwin arm64 do not promise an identical va_list/variadic ABI.  Never pass
// a pointer into our fake __sF storage to libSystem stdio, and do not consume
// guest variadic arguments in bootstrap logging shims.  Formatting fidelity is
// intentionally secondary to keeping Unity constructors alive.
static int gbr_logged_first_stdio = 0;
static FILE *gbr_host_FILE_from_guest(const void *guest_stream) {
    if (!guest_stream) return NULL;
    uintptr_t p=(uintptr_t)guest_stream;
    uintptr_t b=(uintptr_t)gbr_bionic_sF_storage;
    uintptr_t e=b+sizeof(gbr_bionic_sF_storage);
    if (p < b || p >= e) return (FILE *)guest_stream; // fopen/fdopen host FILE*.
    size_t off=(size_t)(p-b);
    if (off==0) return stdin;
    // Common 64-bit Bionic __sFILE strides seen across Android releases.  Exact
    // stdout/stderr offsets vary by libc revision, so accept a family of layouts.
    static const size_t strides[]={104,112,120,128,136,144,152,160,168,176,184,192,200,208,216,224,232,240,248,256};
    for (size_t i=0;i<sizeof(strides)/sizeof(strides[0]);++i) {
        if (off==strides[i]) return stdout;
        if (off==2u*strides[i]) return stderr;
    }
    // Unknown pointer inside Bionic __sF: stderr is the safest bootstrap sink.
    return stderr;
}
static void gbr_stdio_checkpoint_once(void) {
    if (!gbr_logged_first_stdio) { gbr_logged_first_stdio=1; gbr_checkpoint_now("Bionic stdio bridge: first FILE/printf-family call"); }
}
static int gbr_guest_fclose(void *stream) {
    gbr_stdio_checkpoint_once(); FILE *h=gbr_host_FILE_from_guest(stream); if(!h)return 0;
    uintptr_t p=(uintptr_t)stream,b=(uintptr_t)gbr_bionic_sF_storage,e=b+sizeof(gbr_bionic_sF_storage);
    if(p>=b&&p<e){(void)fflush(h);return 0;} return fclose(h);
}
static int gbr_guest_fflush(void *stream) { gbr_stdio_checkpoint_once(); if(!stream)return fflush(NULL); FILE*h=gbr_host_FILE_from_guest(stream); return h?fflush(h):0; }
static size_t gbr_guest_fread(void *ptr,size_t size,size_t nmemb,void *stream){gbr_stdio_checkpoint_once();FILE*h=gbr_host_FILE_from_guest(stream);return h?fread(ptr,size,nmemb,h):0;}
static size_t gbr_guest_fwrite(const void *ptr,size_t size,size_t nmemb,void *stream){gbr_stdio_checkpoint_once();FILE*h=gbr_host_FILE_from_guest(stream);return h?fwrite(ptr,size,nmemb,h):0;}
static int gbr_guest_fputc(int ch,void *stream){gbr_stdio_checkpoint_once();FILE*h=gbr_host_FILE_from_guest(stream);return h?fputc(ch,h):ch;}
static int gbr_guest_putc(int ch,void *stream){return gbr_guest_fputc(ch,stream);}
static int gbr_guest_fputs(const char *text,void *stream){gbr_stdio_checkpoint_once();FILE*h=gbr_host_FILE_from_guest(stream);return (h&&text)?fputs(text,h):0;}
static int gbr_guest_fprintf(void *stream,const char *fmt,...) {
    gbr_stdio_checkpoint_once(); FILE*h=gbr_host_FILE_from_guest(stream); if(!h)h=stderr;
    // Do NOT va_start here: Android and Darwin variadic ABIs/va_list layouts may differ.
    // Emit the format literally during bootstrap; Unity only needs the call to survive.
    if(!fmt)return 0; size_t n=strlen(fmt); if(n)fwrite(fmt,1,n,h); return (int)n;
}
static int gbr_guest_vfprintf(void *stream,const char *fmt,void *guest_ap) {
    (void)guest_ap; gbr_stdio_checkpoint_once(); FILE*h=gbr_host_FILE_from_guest(stream); if(!h)h=stderr;
    if(!fmt)return 0; size_t n=strlen(fmt); if(n)fwrite(fmt,1,n,h); return (int)n;
}

// ---------------- Android clock-id bridge ----------------
static int gbr_logged_first_clock = 0;
static clockid_t gbr_android_clock_to_host(int guest_id) {
    switch(guest_id) {
        case 0: return CLOCK_REALTIME;
        case 1: return CLOCK_MONOTONIC;
#ifdef CLOCK_PROCESS_CPUTIME_ID
        case 2: return CLOCK_PROCESS_CPUTIME_ID;
#else
        case 2: return CLOCK_MONOTONIC;
#endif
#ifdef CLOCK_THREAD_CPUTIME_ID
        case 3: return CLOCK_THREAD_CPUTIME_ID;
#else
        case 3: return CLOCK_MONOTONIC;
#endif
#ifdef CLOCK_MONOTONIC_RAW
        case 4: return CLOCK_MONOTONIC_RAW;
#else
        case 4: return CLOCK_MONOTONIC;
#endif
        // Linux REALTIME_COARSE / MONOTONIC_COARSE / BOOTTIME.
        case 5: return CLOCK_REALTIME;
        case 6: return CLOCK_MONOTONIC;
        case 7: return CLOCK_MONOTONIC;
        default: return CLOCK_MONOTONIC;
    }
}
static int gbr_guest_clock_gettime(int guest_id, struct timespec *ts) {
    if(!gbr_logged_first_clock){gbr_logged_first_clock=1;gbr_checkpoint_now("Android clock bridge: clock_gettime entered");}
    return clock_gettime(gbr_android_clock_to_host(guest_id),ts);
}
static int gbr_guest_clock_getres(int guest_id, struct timespec *ts) { return clock_getres(gbr_android_clock_to_host(guest_id),ts); }

// ---------------- Linux open(2) flags -> Darwin open(2) ----------------
static int gbr_logged_first_open = 0;
static int gbr_linux_open_flags_to_host(int f) {
    int h=0;
    switch(f & 3){case 1:h|=O_WRONLY;break;case 2:h|=O_RDWR;break;default:h|=O_RDONLY;break;}
    if(f & 0x40) h|=O_CREAT;       // Linux O_CREAT
    if(f & 0x80) h|=O_EXCL;        // Linux O_EXCL
    if(f & 0x200) h|=O_TRUNC;      // Linux O_TRUNC
    if(f & 0x400) h|=O_APPEND;     // Linux O_APPEND
    if(f & 0x800) h|=O_NONBLOCK;   // Linux O_NONBLOCK
#ifdef O_SYNC
    if(f & 0x101000) h|=O_SYNC;    // Linux O_SYNC/O_DSYNC family
#endif
#ifdef O_DIRECTORY
    if(f & 0x10000) h|=O_DIRECTORY;
#endif
#ifdef O_NOFOLLOW
    if(f & 0x20000) h|=O_NOFOLLOW;
#endif
#ifdef O_CLOEXEC
    if(f & 0x80000) h|=O_CLOEXEC;
#endif
    return h;
}
static int gbr_guest_open(const char *path,int guest_flags,...) {
    if(!gbr_logged_first_open){gbr_logged_first_open=1;gbr_checkpoint_now("Linux open bridge: open entered");}
    if(!path){errno=EFAULT;return -1;}
    int host_flags=gbr_linux_open_flags_to_host(guest_flags);
    // Do not consume the guest variadic mode argument: use a conservative mode
    // when O_CREAT is present, avoiding Android-vs-Darwin variadic ABI mismatch.
    if(host_flags & O_CREAT) return open(path,host_flags,0600);
    return open(path,host_flags);
}

// ---------------- Guest C++ destructor registry ----------------
// Darwin's __cxa_atexit must never retain raw guest function pointers after an
// ELF image is unmapped.  Constructors only require successful registration, so
// keep a small process-lifetime registry and intentionally defer invocation.
#define GBR_CXA_SLOTS 2048
static struct { void (*fn)(void*); void *arg; void *dso; } gbr_cxa_slots[GBR_CXA_SLOTS];
static unsigned gbr_cxa_count=0;
static int gbr_logged_first_cxa=0;
static int gbr_guest_cxa_atexit(void (*fn)(void*),void *arg,void *dso) {
    if(!gbr_logged_first_cxa){gbr_logged_first_cxa=1;gbr_checkpoint_now("Guest C++ ABI bridge: __cxa_atexit entered");}
    if(gbr_cxa_count<GBR_CXA_SLOTS){gbr_cxa_slots[gbr_cxa_count].fn=fn;gbr_cxa_slots[gbr_cxa_count].arg=arg;gbr_cxa_slots[gbr_cxa_count].dso=dso;gbr_cxa_count++;}
    return 0;
}
static void gbr_guest_cxa_finalize(void *dso) { (void)dso; /* bootstrap: deferred */ }
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
// Guest pthread_attr_t is a Bionic object, not a Darwin pthread_attr_t.  We keep
// the guest token opaque and answer stack queries from the live host thread.
static int gbr_guest_pthread_getattr_np(pthread_t thread, void *guest_attr) {
    (void)thread; (void)guest_attr; return 0;
}
static int gbr_guest_pthread_attr_getstack(const void *guest_attr, void **stackaddr, size_t *stacksize) {
    (void)guest_attr;
#ifdef __APPLE__
    pthread_t t = pthread_self();
    void *top = pthread_get_stackaddr_np(t);
    size_t size = pthread_get_stacksize_np(t);
    if (stacksize) *stacksize = size;
    if (stackaddr) *stackaddr = (top && size) ? (void *)((uintptr_t)top - size) : NULL;
#else
    if (stackaddr) *stackaddr = NULL;
    if (stacksize) *stacksize = 0;
#endif
    return 0;
}
typedef int (*gbr_dl_iter_cb)(void *, size_t, void *);
static int gbr_dl_iterate_phdr(gbr_dl_iter_cb cb, void *data) { (void)cb; (void)data; return 0; }
static int gbr_pthread_condattr_setclock(pthread_condattr_t *attr, clockid_t clock_id) { (void)attr; (void)clock_id; return 0; }

// Android/Bionic pthread objects are ABI-incompatible with Darwin pthread objects.
// Never pass guest pthread_mutex_t / pthread_cond_t storage directly to libSystem.
// We key a small host-side table by the guest object's address and lazily allocate
// native Darwin synchronization objects behind it.
#define GBR_SYNC_SLOTS 512

typedef struct {
    const void *guest;
    int used;
    pthread_mutex_t host;
} GBRMutexSlot;

typedef struct {
    const void *guest;
    int used;
    pthread_cond_t host;
} GBRCondSlot;

typedef struct {
    const void *guest;
    int used;
    int state; // 0=new, 1=running, 2=done
    pthread_cond_t cond;
} GBROnceSlot;

static pthread_mutex_t gbr_sync_table_lock = PTHREAD_MUTEX_INITIALIZER;
static GBRMutexSlot gbr_mutex_slots[GBR_SYNC_SLOTS];
static GBRCondSlot gbr_cond_slots[GBR_SYNC_SLOTS];
static GBROnceSlot gbr_once_slots[GBR_SYNC_SLOTS];
static int gbr_logged_first_guest_mutex = 0;
static int gbr_logged_first_android_syscall = 0;

static GBRMutexSlot *gbr_mutex_slot(const void *guest, int create) {
    if (!guest) return NULL;
    pthread_mutex_lock(&gbr_sync_table_lock);
    GBRMutexSlot *free_slot = NULL;
    for (int i=0; i<GBR_SYNC_SLOTS; ++i) {
        if (gbr_mutex_slots[i].used && gbr_mutex_slots[i].guest == guest) {
            pthread_mutex_unlock(&gbr_sync_table_lock);
            return &gbr_mutex_slots[i];
        }
        if (!gbr_mutex_slots[i].used && !free_slot) free_slot = &gbr_mutex_slots[i];
    }
    if (create && free_slot) {
        memset(free_slot, 0, sizeof(*free_slot));
        free_slot->guest = guest;
        if (pthread_mutex_init(&free_slot->host, NULL) == 0) free_slot->used = 1;
    }
    pthread_mutex_unlock(&gbr_sync_table_lock);
    return (create && free_slot && free_slot->used) ? free_slot : NULL;
}

static GBRCondSlot *gbr_cond_slot(const void *guest, int create) {
    if (!guest) return NULL;
    pthread_mutex_lock(&gbr_sync_table_lock);
    GBRCondSlot *free_slot = NULL;
    for (int i=0; i<GBR_SYNC_SLOTS; ++i) {
        if (gbr_cond_slots[i].used && gbr_cond_slots[i].guest == guest) {
            pthread_mutex_unlock(&gbr_sync_table_lock);
            return &gbr_cond_slots[i];
        }
        if (!gbr_cond_slots[i].used && !free_slot) free_slot = &gbr_cond_slots[i];
    }
    if (create && free_slot) {
        memset(free_slot, 0, sizeof(*free_slot));
        free_slot->guest = guest;
        if (pthread_cond_init(&free_slot->host, NULL) == 0) free_slot->used = 1;
    }
    pthread_mutex_unlock(&gbr_sync_table_lock);
    return (create && free_slot && free_slot->used) ? free_slot : NULL;
}

static int gbr_guest_pthread_mutex_init(void *guest, const void *attr) { (void)attr; return gbr_mutex_slot(guest, 1) ? 0 : ENOMEM; }
static int gbr_guest_pthread_mutex_destroy(void *guest) {
    GBRMutexSlot *s = gbr_mutex_slot(guest, 0); if (!s) return 0;
    int r = pthread_mutex_destroy(&s->host);
    if (r == 0) { pthread_mutex_lock(&gbr_sync_table_lock); s->used=0; s->guest=NULL; pthread_mutex_unlock(&gbr_sync_table_lock); }
    return r;
}
static int gbr_guest_pthread_mutex_lock(void *guest) {
    if (!gbr_logged_first_guest_mutex) { gbr_logged_first_guest_mutex=1; gbr_checkpoint_now("Bionic pthread bridge: first guest pthread_mutex_lock entered"); }
    GBRMutexSlot *s = gbr_mutex_slot(guest, 1); return s ? pthread_mutex_lock(&s->host) : ENOMEM;
}
static int gbr_guest_pthread_mutex_trylock(void *guest) { GBRMutexSlot *s=gbr_mutex_slot(guest,1); return s ? pthread_mutex_trylock(&s->host) : ENOMEM; }
static int gbr_guest_pthread_mutex_unlock(void *guest) { GBRMutexSlot *s=gbr_mutex_slot(guest,1); return s ? pthread_mutex_unlock(&s->host) : EINVAL; }

static int gbr_guest_pthread_cond_init(void *guest, const void *attr) { (void)attr; return gbr_cond_slot(guest,1) ? 0 : ENOMEM; }
static int gbr_guest_pthread_cond_destroy(void *guest) {
    GBRCondSlot *s=gbr_cond_slot(guest,0); if(!s) return 0;
    int r=pthread_cond_destroy(&s->host);
    if(r==0){ pthread_mutex_lock(&gbr_sync_table_lock); s->used=0; s->guest=NULL; pthread_mutex_unlock(&gbr_sync_table_lock); }
    return r;
}
static int gbr_guest_pthread_cond_wait(void *guest_cond, void *guest_mutex) {
    GBRCondSlot *c=gbr_cond_slot(guest_cond,1); GBRMutexSlot *m=gbr_mutex_slot(guest_mutex,1);
    return (c&&m) ? pthread_cond_wait(&c->host,&m->host) : EINVAL;
}
static int gbr_guest_pthread_cond_timedwait(void *guest_cond, void *guest_mutex, const struct timespec *ts) {
    GBRCondSlot *c=gbr_cond_slot(guest_cond,1); GBRMutexSlot *m=gbr_mutex_slot(guest_mutex,1);
    return (c&&m) ? pthread_cond_timedwait(&c->host,&m->host,ts) : EINVAL;
}
static int gbr_guest_pthread_cond_signal(void *guest_cond) { GBRCondSlot *c=gbr_cond_slot(guest_cond,1); return c ? pthread_cond_signal(&c->host) : EINVAL; }
static int gbr_guest_pthread_cond_broadcast(void *guest_cond) { GBRCondSlot *c=gbr_cond_slot(guest_cond,1); return c ? pthread_cond_broadcast(&c->host) : EINVAL; }

// Attribute storage is also ABI-different. Unity mostly uses these as setup tokens;
// the guest-facing bridge can safely keep the state host-side / ignore unsupported hints.
static int gbr_guest_pthread_mutexattr_init(void *a) { (void)a; return 0; }
static int gbr_guest_pthread_mutexattr_destroy(void *a) { (void)a; return 0; }
static int gbr_guest_pthread_mutexattr_settype(void *a, int type) { (void)a; (void)type; return 0; }
static int gbr_guest_pthread_condattr_init(void *a) { (void)a; return 0; }
static int gbr_guest_pthread_condattr_destroy(void *a) { (void)a; return 0; }
static int gbr_guest_pthread_condattr_setclock(void *a, clockid_t clock_id) { (void)a; (void)clock_id; return 0; }
static int gbr_guest_pthread_attr_init(void *a) { (void)a; return 0; }
static int gbr_guest_pthread_attr_destroy(void *a) { (void)a; return 0; }
static int gbr_guest_pthread_attr_setdetachstate(void *a, int state) { (void)a; (void)state; return 0; }
static int gbr_guest_pthread_attr_setstacksize(void *a, size_t size) { (void)a; (void)size; return 0; }
static int gbr_guest_pthread_create(pthread_t *thread, const void *guest_attr, void *(*start)(void *), void *arg) {
    (void)guest_attr; return pthread_create(thread, NULL, start, arg);
}

static GBROnceSlot *gbr_once_slot(const void *guest) {
    pthread_mutex_lock(&gbr_sync_table_lock);
    GBROnceSlot *free_slot=NULL;
    for(int i=0;i<GBR_SYNC_SLOTS;++i){
        if(gbr_once_slots[i].used && gbr_once_slots[i].guest==guest){ pthread_mutex_unlock(&gbr_sync_table_lock); return &gbr_once_slots[i]; }
        if(!gbr_once_slots[i].used && !free_slot) free_slot=&gbr_once_slots[i];
    }
    if(free_slot){ memset(free_slot,0,sizeof(*free_slot)); free_slot->guest=guest; pthread_cond_init(&free_slot->cond,NULL); free_slot->used=1; }
    pthread_mutex_unlock(&gbr_sync_table_lock);
    return free_slot;
}
static int gbr_guest_pthread_once(void *guest_once, void (*init_routine)(void)) {
    if(!guest_once || !init_routine) return EINVAL;
    GBROnceSlot *s=gbr_once_slot(guest_once); if(!s) return ENOMEM;
    pthread_mutex_lock(&gbr_sync_table_lock);
    while(s->state==1) pthread_cond_wait(&s->cond,&gbr_sync_table_lock);
    if(s->state==2){ pthread_mutex_unlock(&gbr_sync_table_lock); return 0; }
    s->state=1; pthread_mutex_unlock(&gbr_sync_table_lock);
    init_routine();
    pthread_mutex_lock(&gbr_sync_table_lock); s->state=2; pthread_cond_broadcast(&s->cond); pthread_mutex_unlock(&gbr_sync_table_lock);
    return 0;
}

// ---------------- Bionic TLS / semaphore / process ABI bridge ----------------
// Android arm64 pthread_key_t is a 32-bit integer (Unity actually stores the
// result with a 32-bit STR/LDRSW). Darwin pthread_key_t must therefore never be
// written directly into guest storage.
#define GBR_TLS_KEY_SLOTS 256
#define GBR_SEM_SLOTS 128

typedef struct {
    uint32_t guest_key;
    int used;
    pthread_key_t host_key;
} GBRTLSKeySlot;

typedef struct {
    const void *guest;
    int used;
    pthread_mutex_t lock;
    pthread_cond_t cond;
    unsigned value;
} GBRSemSlot;

static GBRTLSKeySlot gbr_tls_keys[GBR_TLS_KEY_SLOTS];
static uint32_t gbr_next_guest_key = 1;
static GBRSemSlot gbr_sem_slots[GBR_SEM_SLOTS];
static int gbr_logged_first_tls_key = 0;
static int gbr_logged_first_sem = 0;

static GBRTLSKeySlot *gbr_tls_slot_for_guest(uint32_t key) {
    GBRTLSKeySlot *found = NULL;
    pthread_mutex_lock(&gbr_sync_table_lock);
    for (int i=0; i<GBR_TLS_KEY_SLOTS; ++i) {
        if (gbr_tls_keys[i].used && gbr_tls_keys[i].guest_key == key) { found=&gbr_tls_keys[i]; break; }
    }
    pthread_mutex_unlock(&gbr_sync_table_lock);
    return found;
}

static int gbr_guest_pthread_key_create(uint32_t *guest_key, void (*destructor)(void *)) {
    if (!guest_key) return EINVAL;
    if (!gbr_logged_first_tls_key) {
        gbr_logged_first_tls_key=1;
        gbr_checkpoint_now("Bionic TLS bridge: pthread_key_create entered");
    }
    pthread_mutex_lock(&gbr_sync_table_lock);
    GBRTLSKeySlot *slot=NULL;
    for (int i=0; i<GBR_TLS_KEY_SLOTS; ++i) if (!gbr_tls_keys[i].used) { slot=&gbr_tls_keys[i]; break; }
    if (!slot) { pthread_mutex_unlock(&gbr_sync_table_lock); return EAGAIN; }
    pthread_key_t hk;
    int r=pthread_key_create(&hk, destructor);
    if (r != 0) { pthread_mutex_unlock(&gbr_sync_table_lock); return r; }
    uint32_t id=gbr_next_guest_key++;
    if (id==0) id=gbr_next_guest_key++;
    slot->used=1; slot->guest_key=id; slot->host_key=hk;
    *guest_key=id; // exactly 32 bits into Bionic storage
    pthread_mutex_unlock(&gbr_sync_table_lock);
    return 0;
}

static int gbr_guest_pthread_key_delete(uint32_t guest_key) {
    pthread_mutex_lock(&gbr_sync_table_lock);
    GBRTLSKeySlot *slot=NULL;
    for (int i=0;i<GBR_TLS_KEY_SLOTS;++i) if(gbr_tls_keys[i].used && gbr_tls_keys[i].guest_key==guest_key){slot=&gbr_tls_keys[i];break;}
    if(!slot){pthread_mutex_unlock(&gbr_sync_table_lock);return EINVAL;}
    pthread_key_t hk=slot->host_key;
    slot->used=0; slot->guest_key=0;
    pthread_mutex_unlock(&gbr_sync_table_lock);
    return pthread_key_delete(hk);
}

static int gbr_guest_pthread_setspecific(uint32_t guest_key, const void *value) {
    GBRTLSKeySlot *slot=gbr_tls_slot_for_guest(guest_key);
    return slot ? pthread_setspecific(slot->host_key, value) : EINVAL;
}

static void *gbr_guest_pthread_getspecific(uint32_t guest_key) {
    GBRTLSKeySlot *slot=gbr_tls_slot_for_guest(guest_key);
    return slot ? pthread_getspecific(slot->host_key) : NULL;
}

// Android pthread_setname_np(thread,name) and Darwin pthread_setname_np(name)
// have different ABIs.  Only the current-thread case matters for Unity bootstrap.
static int gbr_guest_pthread_setname_np(pthread_t thread, const char *name) {
    (void)thread;
#ifdef __APPLE__
    return name ? pthread_setname_np(name) : EINVAL;
#else
    (void)name; return 0;
#endif
}

static GBRSemSlot *gbr_sem_slot(const void *guest, int create) {
    if(!guest) return NULL;
    pthread_mutex_lock(&gbr_sync_table_lock);
    GBRSemSlot *free_slot=NULL, *found=NULL;
    for(int i=0;i<GBR_SEM_SLOTS;++i){
        if(gbr_sem_slots[i].used && gbr_sem_slots[i].guest==guest){found=&gbr_sem_slots[i];break;}
        if(!gbr_sem_slots[i].used && !free_slot) free_slot=&gbr_sem_slots[i];
    }
    if(!found && create && free_slot){
        memset(free_slot,0,sizeof(*free_slot)); free_slot->guest=guest;
        if(pthread_mutex_init(&free_slot->lock,NULL)==0 && pthread_cond_init(&free_slot->cond,NULL)==0){free_slot->used=1;found=free_slot;}
    }
    pthread_mutex_unlock(&gbr_sync_table_lock);
    return found;
}
static int gbr_guest_sem_init(void *guest, int pshared, unsigned value) {
    (void)pshared;
    if(!guest) {errno=EINVAL;return -1;}
    if(!gbr_logged_first_sem){gbr_logged_first_sem=1;gbr_checkpoint_now("Bionic semaphore bridge: sem_init entered");}
    GBRSemSlot *slot=gbr_sem_slot(guest,1); if(!slot){errno=ENOSPC;return -1;}
    pthread_mutex_lock(&slot->lock); slot->value=value; pthread_mutex_unlock(&slot->lock); return 0;
}
static int gbr_guest_sem_destroy(void *guest){
    GBRSemSlot*s=gbr_sem_slot(guest,0);if(!s)return 0;
    // Keep the host slot alive for process lifetime; Android code may re-init the
    // same guest address and destroying/reinitializing a cond with racing waiters
    // is much more dangerous than retaining this tiny bootstrap object.
    pthread_mutex_lock(&s->lock);s->value=0;pthread_mutex_unlock(&s->lock);return 0;
}
static int gbr_guest_sem_wait(void *guest){
    GBRSemSlot*s=gbr_sem_slot(guest,1);if(!s){errno=EINVAL;return -1;}
    pthread_mutex_lock(&s->lock);while(s->value==0)pthread_cond_wait(&s->cond,&s->lock);s->value--;pthread_mutex_unlock(&s->lock);return 0;
}
static int gbr_guest_sem_trywait(void *guest){
    GBRSemSlot*s=gbr_sem_slot(guest,1);if(!s){errno=EINVAL;return -1;}
    pthread_mutex_lock(&s->lock);if(s->value==0){pthread_mutex_unlock(&s->lock);errno=EAGAIN;return -1;}s->value--;pthread_mutex_unlock(&s->lock);return 0;
}
static int gbr_guest_sem_post(void *guest){
    GBRSemSlot*s=gbr_sem_slot(guest,1);if(!s){errno=EINVAL;return -1;}
    pthread_mutex_lock(&s->lock);s->value++;pthread_cond_signal(&s->cond);pthread_mutex_unlock(&s->lock);return 0;
}
static int gbr_guest_sem_getvalue(void *guest,int *value){
    GBRSemSlot*s=gbr_sem_slot(guest,1);if(!s||!value){errno=EINVAL;return -1;}
    pthread_mutex_lock(&s->lock);*value=(int)s->value;pthread_mutex_unlock(&s->lock);return 0;
}
static int gbr_guest_sem_timedwait(void *guest, const struct timespec *abs_timeout) {
    GBRSemSlot*s=gbr_sem_slot(guest,1);if(!s){errno=EINVAL;return -1;}
    if(!abs_timeout)return gbr_guest_sem_wait(guest);
    pthread_mutex_lock(&s->lock);
    while(s->value==0){int r=pthread_cond_timedwait(&s->cond,&s->lock,abs_timeout);if(r==ETIMEDOUT){pthread_mutex_unlock(&s->lock);errno=ETIMEDOUT;return -1;}if(r!=0){pthread_mutex_unlock(&s->lock);errno=r;return -1;}}
    s->value--;pthread_mutex_unlock(&s->lock);return 0;
}

// Android/Linux memory flags are not Darwin flags. In particular MAP_ANONYMOUS
// is 0x20 on Linux arm64 but 0x1000 on Darwin.
static void *gbr_android_mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off) {
    int host_flags=0;
    if(flags & 0x01) host_flags |= MAP_SHARED;
    if(flags & 0x02) host_flags |= MAP_PRIVATE;
    if(flags & 0x10) host_flags |= MAP_FIXED;
    if(flags & 0x20) host_flags |= MAP_ANON;
    if(!(host_flags & (MAP_SHARED|MAP_PRIVATE))) host_flags |= MAP_PRIVATE;
    if(host_flags & MAP_ANON) fd=-1;
    return mmap(addr,len,prot,host_flags,fd,off);
}
static int gbr_android_mprotect(void *addr,size_t len,int prot){
    if(!addr||!len){errno=EINVAL;return -1;}size_t p=gbr_page_size();uintptr_t a=(uintptr_t)addr;uintptr_t lo=(uintptr_t)gbr_align_down(a,p);uintptr_t hi=(uintptr_t)gbr_align_up(a+len,p);return mprotect((void*)lo,hi-lo,prot);
}
static int gbr_android_munmap(void *addr,size_t len){
    if(!addr||!len){errno=EINVAL;return -1;}size_t p=gbr_page_size();uintptr_t a=(uintptr_t)addr;uintptr_t lo=(uintptr_t)gbr_align_down(a,p);uintptr_t hi=(uintptr_t)gbr_align_up(a+len,p);return munmap((void*)lo,hi-lo);
}
static int gbr_android_madvise(void *addr,size_t len,int advice){(void)addr;(void)len;(void)advice;return 0;}
static int gbr_android_getpagesize(void){return 4096;}
static long gbr_android_sysconf(int name){
    // Linux/Bionic numeric constants are not Darwin constants. Never forward an
    // unknown guest integer to Darwin sysconf().
    switch(name){
        case 0: return 131072; // _SC_ARG_MAX, conservative Android-like value
        case 2: return 100;    // _SC_CLK_TCK
        case 4: return 16;     // _SC_NGROUPS_MAX
        case 5: return 1024;   // _SC_OPEN_MAX
        case 30: return 4096;  // _SC_PAGESIZE
        case 83: { long n=sysconf(_SC_NPROCESSORS_CONF); return n>0?n:1; }
        case 84: { long n=sysconf(_SC_NPROCESSORS_ONLN); return n>0?n:1; }
        default: errno=EINVAL; return -1;
    }
}

// Keep Android crash/signal setup inside the guest compatibility domain. Bionic
// sigaction/sigset layouts differ from Darwin and must not be handed to libSystem.
#define GBR_GUEST_SIGSET_BYTES 128
static int gbr_guest_sigemptyset(void *set){if(set)memset(set,0,GBR_GUEST_SIGSET_BYTES);return 0;}
static int gbr_guest_sigfillset(void *set){if(set)memset(set,0xff,GBR_GUEST_SIGSET_BYTES);return 0;}
static int gbr_guest_sigaddset(void *set,int sig){if(!set||sig<=0||sig>1024)return EINVAL;unsigned b=(unsigned)(sig-1);((unsigned char*)set)[b>>3]|=(unsigned char)(1u<<(b&7));return 0;}
static int gbr_guest_sigdelset(void *set,int sig){if(!set||sig<=0||sig>1024)return EINVAL;unsigned b=(unsigned)(sig-1);((unsigned char*)set)[b>>3]&=(unsigned char)~(1u<<(b&7));return 0;}
static int gbr_guest_sigaction(int sig,const void *act,void *oldact){(void)sig;(void)act;(void)oldact;return 0;}
static int gbr_guest_sigaltstack(const void *ss,void *old_ss){(void)ss;(void)old_ss;return 0;}
static int gbr_guest_pthread_sigmask(int how,const void *set,void *oldset){(void)how;(void)set;if(oldset)memset(oldset,0,GBR_GUEST_SIGSET_BYTES);return 0;}
static int gbr_guest_sigsuspend(const void *set){(void)set;errno=EINTR;return -1;}
static void (*gbr_guest_signal(int sig, void (*handler)(int)))(int){(void)sig;return handler;}
static int gbr_guest_raise(int sig){(void)sig;return 0;}

// Guest dynamic-loader calls can ask for Android sonames that do not exist as
// Mach-O dylibs. Return stable fake handles and resolve through our shim table.
static uintptr_t gbr_fake_so_handle=0x474252534f48444cULL;
static char gbr_guest_dlerror_text[128];
static void *gbr_guest_dlopen(const char *path,int mode){(void)mode;if(path&&strstr(path,".so"))return &gbr_fake_so_handle;void*h=dlopen(path,mode);if(!h)snprintf(gbr_guest_dlerror_text,sizeof(gbr_guest_dlerror_text),"dlopen failed: %s",path?path:"<null>");return h;}
static void *gbr_guest_dlsym(void *handle,const char *name){(void)handle;void*p=gbr_compat_resolve_symbol(name);if(p)return p;return name?dlsym(RTLD_DEFAULT,name):NULL;}
static int gbr_guest_dlclose(void *handle){if(handle==&gbr_fake_so_handle)return 0;return handle?dlclose(handle):0;}
static char *gbr_guest_dlerror(void){return gbr_guest_dlerror_text[0]?gbr_guest_dlerror_text:NULL;}

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


// Linux/Android syscall numbers are NOT Darwin syscall numbers. Forwarding them to
// libSystem's syscall() can call the wrong kernel service. Translate the small set
// observed in GoreBox/Unity and report ENOSYS for unknown calls so guest fallback
// paths can run safely.
static long gbr_android_syscall(long nr, ...) {
    if (!gbr_logged_first_android_syscall) {
        char cp[128]; snprintf(cp,sizeof(cp),"Android syscall bridge entered: nr=%ld",nr); gbr_checkpoint_now(cp);
        gbr_logged_first_android_syscall=1;
    }
    va_list ap; va_start(ap,nr);
    long result=-1;
    switch(nr) {
        case 178: // __NR_gettid on Linux arm64
            result=(long)gbr_gettid();
            break;
        case 122: { // __NR_sched_setaffinity
            pid_t pid=(pid_t)va_arg(ap,int); size_t sz=(size_t)va_arg(ap,unsigned long); const void *mask=va_arg(ap,const void *);
            result=(long)gbr_sched_setaffinity(pid,sz,mask);
            break;
        }
        case 123: { // __NR_sched_getaffinity (raw syscall returns bytes copied)
            pid_t pid=(pid_t)va_arg(ap,int); size_t sz=(size_t)va_arg(ap,unsigned long); void *mask=va_arg(ap,void *);
            if (gbr_sched_getaffinity(pid,sz,mask)==0) result=(long)sz; else result=-1;
            break;
        }
        case 98: // __NR_futex: pthread/cond bridge handles normal synchronization; advertise unsupported raw futex.
        case 270: // __NR_process_vm_readv: Unity has an ENOSYS fallback path.
            errno=ENOSYS; result=-1; break;
        default:
            errno=ENOSYS; result=-1; break;
    }
    va_end(ap); return result;
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

// Android native window / looper / sensor compatibility. ANativeWindow dimensions now
// come from the real CAEAGLLayer drawable installed by GraphicsBridge.swift.
static uintptr_t gbr_stub_zero(void) { return 0; }
static uintptr_t gbr_stub_one(void) { return 1; }
static uintptr_t gbr_stub_ptr(void) { static uintptr_t token = 0x47425231; return (uintptr_t)&token; }
static int gbr_stub_minus3(void) { return -3; }
static int gbr_window_width(void *w) { (void)w; int32_t v = gbr_ios_gles_width(); return v > 0 ? v : 1280; }
static int gbr_window_height(void *w) { (void)w; int32_t v = gbr_ios_gles_height(); return v > 0 ? v : 720; }
static void gbr_window_acquire(void *w) { (void)w; }
static void gbr_window_release(void *w) { (void)w; }
static int gbr_window_set_buffers_geometry(void *w, int width, int height, int format) { (void)w; (void)width; (void)height; (void)format; return 0; }
static float gbr_sensor_float(void *s) { (void)s; return 0.0f; }
static const char *gbr_sensor_text(void *s) { (void)s; return "iOS shim"; }

// Minimal EGL -> EAGL/CAEAGLLayer bridge. Handles are stable tokens because Unity only
// needs opaque EGLDisplay/EGLConfig/EGLContext/EGLSurface identities at this layer.
static uintptr_t gbr_egl_display_token = 0x45474431;
static uintptr_t gbr_egl_config_token = 0x45474331;
static uintptr_t gbr_egl_context_token = 0x45474332;
static uintptr_t gbr_egl_surface_token = 0x45475331;
static int gbr_egl_last_error = 0x3000; // EGL_SUCCESS
static void *gbr_egl_get_display(void *native) { (void)native; return &gbr_egl_display_token; }
static unsigned int gbr_egl_initialize(void *d, int *major, int *minor) { if (!d) { gbr_egl_last_error=0x3008; return 0; } if (major) *major=1; if (minor) *minor=5; gbr_egl_last_error=0x3000; return 1; }
static unsigned int gbr_egl_choose_config(void *d, const int *attrs, void **configs, int config_size, int *num) { (void)attrs; if (!d) return 0; if (num) *num=1; if (configs && config_size>0) configs[0]=&gbr_egl_config_token; return 1; }
static unsigned int gbr_egl_get_config_attrib(void *d, void *cfg, int attr, int *value) { (void)d; (void)cfg; if (!value) return 0; switch(attr){ case 0x3024: case 0x3023: case 0x3022: case 0x3021: *value=8; break; case 0x3025: *value=24; break; case 0x3026: *value=8; break; case 0x3033: *value=0x0005; break; case 0x3040: *value=0x0044; break; default: *value=0; break;} return 1; }
static void *gbr_egl_create_context(void *d, void *cfg, void *share, const int *attrs) { (void)d; (void)cfg; (void)share; (void)attrs; if (!gbr_ios_gles_create_context()) { gbr_egl_last_error=0x3003; return NULL; } return &gbr_egl_context_token; }
static void *gbr_egl_create_window_surface(void *d, void *cfg, void *win, const int *attrs) { (void)d; (void)cfg; (void)win; (void)attrs; if (!gbr_ios_gles_create_window_surface()) { gbr_egl_last_error=0x3003; return NULL; } return &gbr_egl_surface_token; }
static void *gbr_egl_create_pbuffer_surface(void *d, void *cfg, const int *attrs) { (void)d; (void)cfg; (void)attrs; if (!gbr_ios_gles_create_context()) return NULL; return &gbr_egl_surface_token; }
static unsigned int gbr_egl_make_current(void *d, void *draw, void *read, void *ctx) { (void)d; (void)draw; (void)read; (void)ctx; return gbr_ios_gles_make_current() ? 1u : 0u; }
static unsigned int gbr_egl_swap_buffers(void *d, void *s) { (void)d; (void)s; return gbr_ios_gles_swap_buffers() ? 1u : 0u; }
static unsigned int gbr_egl_query_surface(void *d, void *s, int attr, int *value) { (void)d; (void)s; if (!value) return 0; if (attr==0x3057) *value=gbr_window_width(NULL); else if (attr==0x3056) *value=gbr_window_height(NULL); else *value=0; return 1; }
static unsigned int gbr_egl_destroy_surface(void *d, void *s) { (void)d; (void)s; return 1; }
static unsigned int gbr_egl_destroy_context(void *d, void *c) { (void)d; (void)c; return 1; }
static unsigned int gbr_egl_terminate(void *d) { (void)d; return 1; }
static unsigned int gbr_egl_swap_interval(void *d, int i) { (void)d; (void)i; return 1; }
static unsigned int gbr_egl_surface_attrib(void *d, void *s, int a, int v) { (void)d; (void)s; (void)a; (void)v; return 1; }
static unsigned int gbr_egl_bind_api(unsigned int api) { (void)api; return 1; }
static void *gbr_egl_get_current_context(void) { return &gbr_egl_context_token; }
static void *gbr_egl_get_current_surface(int which) { (void)which; return &gbr_egl_surface_token; }
static void *gbr_egl_get_current_display(void) { return &gbr_egl_display_token; }
static int gbr_egl_get_error(void) { int e=gbr_egl_last_error; gbr_egl_last_error=0x3000; return e; }
static const char *gbr_egl_query_string(void *d, int name) { (void)d; switch(name){ case 0x3053: return "OpenAI GoreBoxRunner"; case 0x3054: return "1.5 GoreBoxRunner-EAGL"; case 0x308D: return "OpenGL_ES"; default: return ""; } }
static void *gbr_gl_bind_framebuffer_wrapper_address(void);
static void gbr_gl_bind_framebuffer_wrapper(unsigned int target, unsigned int framebuffer) { if (framebuffer==0) { gbr_ios_gles_bind_default_framebuffer(); return; } typedef void (*Fn)(unsigned int,unsigned int); static Fn real=NULL; if(!real) real=(Fn)dlsym(RTLD_DEFAULT,"glBindFramebuffer"); if(real) real(target,framebuffer); }
static void *gbr_gl_bind_framebuffer_wrapper_address(void) { return (void *)&gbr_gl_bind_framebuffer_wrapper; }
static void *gbr_egl_get_proc(const char *name) { if (!name) return NULL; if (strcmp(name,"glBindFramebuffer")==0 || strcmp(name,"glBindFramebufferOES")==0) return gbr_gl_bind_framebuffer_wrapper_address(); void *p=dlsym(RTLD_DEFAULT,name); if(p) return p; return gbr_compat_resolve_symbol(name); }

void *gbr_compat_resolve_symbol(const char *name) {
    if (!name || !*name) return NULL;
#define EQ(x) (strcmp(name, (x)) == 0)
    // Never hand Bionic FILE*/clock/open/C++ runtime objects directly to Darwin.
    if (EQ("fclose")) return (void *)&gbr_guest_fclose;
    if (EQ("fflush")) return (void *)&gbr_guest_fflush;
    if (EQ("fread")) return (void *)&gbr_guest_fread;
    if (EQ("fwrite")) return (void *)&gbr_guest_fwrite;
    if (EQ("fputc")) return (void *)&gbr_guest_fputc;
    if (EQ("putc")) return (void *)&gbr_guest_putc;
    if (EQ("fputs")) return (void *)&gbr_guest_fputs;
    if (EQ("fprintf")) return (void *)&gbr_guest_fprintf;
    if (EQ("vfprintf")) return (void *)&gbr_guest_vfprintf;
    if (EQ("clock_gettime")) return (void *)&gbr_guest_clock_gettime;
    if (EQ("clock_getres")) return (void *)&gbr_guest_clock_getres;
    if (EQ("open")) return (void *)&gbr_guest_open;
    if (EQ("__cxa_atexit")) return (void *)&gbr_guest_cxa_atexit;
    if (EQ("__cxa_finalize")) return (void *)&gbr_guest_cxa_finalize;
    if (EQ("__sF")) return (void *)gbr_bionic_sF_storage;
    if (EQ("syscall")) return (void *)&gbr_android_syscall;
    if (EQ("pthread_key_create")) return (void *)&gbr_guest_pthread_key_create;
    if (EQ("pthread_key_delete")) return (void *)&gbr_guest_pthread_key_delete;
    if (EQ("pthread_setspecific")) return (void *)&gbr_guest_pthread_setspecific;
    if (EQ("pthread_getspecific")) return (void *)&gbr_guest_pthread_getspecific;
    if (EQ("pthread_setname_np")) return (void *)&gbr_guest_pthread_setname_np;
    if (EQ("pthread_mutex_init")) return (void *)&gbr_guest_pthread_mutex_init;
    if (EQ("pthread_mutex_destroy")) return (void *)&gbr_guest_pthread_mutex_destroy;
    if (EQ("pthread_mutex_lock")) return (void *)&gbr_guest_pthread_mutex_lock;
    if (EQ("pthread_mutex_trylock")) return (void *)&gbr_guest_pthread_mutex_trylock;
    if (EQ("pthread_mutex_unlock")) return (void *)&gbr_guest_pthread_mutex_unlock;
    if (EQ("pthread_cond_init")) return (void *)&gbr_guest_pthread_cond_init;
    if (EQ("pthread_cond_destroy")) return (void *)&gbr_guest_pthread_cond_destroy;
    if (EQ("pthread_cond_wait")) return (void *)&gbr_guest_pthread_cond_wait;
    if (EQ("pthread_cond_timedwait")) return (void *)&gbr_guest_pthread_cond_timedwait;
    if (EQ("pthread_cond_signal")) return (void *)&gbr_guest_pthread_cond_signal;
    if (EQ("pthread_cond_broadcast")) return (void *)&gbr_guest_pthread_cond_broadcast;
    if (EQ("pthread_mutexattr_init")) return (void *)&gbr_guest_pthread_mutexattr_init;
    if (EQ("pthread_mutexattr_destroy")) return (void *)&gbr_guest_pthread_mutexattr_destroy;
    if (EQ("pthread_mutexattr_settype")) return (void *)&gbr_guest_pthread_mutexattr_settype;
    if (EQ("pthread_condattr_init")) return (void *)&gbr_guest_pthread_condattr_init;
    if (EQ("pthread_condattr_destroy")) return (void *)&gbr_guest_pthread_condattr_destroy;
    if (EQ("pthread_condattr_setclock")) return (void *)&gbr_guest_pthread_condattr_setclock;
    if (EQ("pthread_attr_init")) return (void *)&gbr_guest_pthread_attr_init;
    if (EQ("pthread_attr_destroy")) return (void *)&gbr_guest_pthread_attr_destroy;
    if (EQ("pthread_attr_setdetachstate")) return (void *)&gbr_guest_pthread_attr_setdetachstate;
    if (EQ("pthread_attr_setstacksize")) return (void *)&gbr_guest_pthread_attr_setstacksize;
    if (EQ("pthread_attr_getstack")) return (void *)&gbr_guest_pthread_attr_getstack;
    if (EQ("pthread_getattr_np")) return (void *)&gbr_guest_pthread_getattr_np;
    if (EQ("pthread_create")) return (void *)&gbr_guest_pthread_create;
    if (EQ("pthread_once")) return (void *)&gbr_guest_pthread_once;
    if (EQ("pthread_atfork")) return (void *)&gbr_pthread_atfork;
    if (EQ("sem_init")) return (void *)&gbr_guest_sem_init;
    if (EQ("sem_destroy")) return (void *)&gbr_guest_sem_destroy;
    if (EQ("sem_wait")) return (void *)&gbr_guest_sem_wait;
    if (EQ("sem_trywait")) return (void *)&gbr_guest_sem_trywait;
    if (EQ("sem_post")) return (void *)&gbr_guest_sem_post;
    if (EQ("sem_getvalue")) return (void *)&gbr_guest_sem_getvalue;
    if (EQ("sem_timedwait")) return (void *)&gbr_guest_sem_timedwait;
    if (EQ("mmap")) return (void *)&gbr_android_mmap;
    if (EQ("mprotect")) return (void *)&gbr_android_mprotect;
    if (EQ("munmap")) return (void *)&gbr_android_munmap;
    if (EQ("madvise")) return (void *)&gbr_android_madvise;
    if (EQ("getpagesize")) return (void *)&gbr_android_getpagesize;
    if (EQ("sysconf")) return (void *)&gbr_android_sysconf;
    if (EQ("sigemptyset")) return (void *)&gbr_guest_sigemptyset;
    if (EQ("sigfillset")) return (void *)&gbr_guest_sigfillset;
    if (EQ("sigaddset")) return (void *)&gbr_guest_sigaddset;
    if (EQ("sigdelset")) return (void *)&gbr_guest_sigdelset;
    if (EQ("sigaction")) return (void *)&gbr_guest_sigaction;
    if (EQ("sigaltstack")) return (void *)&gbr_guest_sigaltstack;
    if (EQ("pthread_sigmask")) return (void *)&gbr_guest_pthread_sigmask;
    if (EQ("sigsuspend")) return (void *)&gbr_guest_sigsuspend;
    if (EQ("signal")) return (void *)&gbr_guest_signal;
    if (EQ("raise")) return (void *)&gbr_guest_raise;
    if (EQ("dlopen")) return (void *)&gbr_guest_dlopen;
    if (EQ("dlsym")) return (void *)&gbr_guest_dlsym;
    if (EQ("dlclose")) return (void *)&gbr_guest_dlclose;
    if (EQ("dlerror")) return (void *)&gbr_guest_dlerror;
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
        if (EQ("ANativeWindow_acquire")) return (void *)&gbr_window_acquire;
        if (EQ("ANativeWindow_release")) return (void *)&gbr_window_release;
        if (EQ("ANativeWindow_setBuffersGeometry")) return (void *)&gbr_window_set_buffers_geometry;
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
        if (EQ("eglChooseConfig")) return (void *)&gbr_egl_choose_config;
        if (EQ("eglGetConfigAttrib")) return (void *)&gbr_egl_get_config_attrib;
        if (EQ("eglCreateContext")) return (void *)&gbr_egl_create_context;
        if (EQ("eglCreateWindowSurface")) return (void *)&gbr_egl_create_window_surface;
        if (EQ("eglCreatePbufferSurface")) return (void *)&gbr_egl_create_pbuffer_surface;
        if (EQ("eglMakeCurrent")) return (void *)&gbr_egl_make_current;
        if (EQ("eglSwapBuffers")) return (void *)&gbr_egl_swap_buffers;
        if (EQ("eglQuerySurface")) return (void *)&gbr_egl_query_surface;
        if (EQ("eglDestroySurface")) return (void *)&gbr_egl_destroy_surface;
        if (EQ("eglDestroyContext")) return (void *)&gbr_egl_destroy_context;
        if (EQ("eglTerminate")) return (void *)&gbr_egl_terminate;
        if (EQ("eglSwapInterval")) return (void *)&gbr_egl_swap_interval;
        if (EQ("eglSurfaceAttrib")) return (void *)&gbr_egl_surface_attrib;
        if (EQ("eglBindAPI")) return (void *)&gbr_egl_bind_api;
        if (EQ("eglGetCurrentContext")) return (void *)&gbr_egl_get_current_context;
        if (EQ("eglGetCurrentSurface")) return (void *)&gbr_egl_get_current_surface;
        if (EQ("eglGetCurrentDisplay")) return (void *)&gbr_egl_get_current_display;
        if (EQ("eglGetError")) return (void *)&gbr_egl_get_error;
        if (EQ("eglQueryString")) return (void *)&gbr_egl_query_string;
        if (EQ("eglGetProcAddress")) return (void *)&gbr_egl_get_proc;
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

    // Parse PT_DYNAMIC lifecycle tags. Android's linker runs DT_INIT / DT_INIT_ARRAY
    // before JNI_OnLoad. Graphics 0.3 intentionally omitted this and libunity died
    // before its first JNI callback. Keep the metadata here and execute it only when
    // the caller explicitly requests gbr_elf_run_initializers().
    for (uint16_t i = 0; i < eh->e_phnum; ++i) {
        const GBRPhdr *ph = (const GBRPhdr *)(data + eh->e_phoff + (uint64_t)i * eh->e_phentsize);
        if (ph->p_type != GBR_PT_DYNAMIC) continue;
        if (ph->p_offset + ph->p_filesz > length || ph->p_filesz < sizeof(GBRDyn)) continue;
        size_t dyn_count = (size_t)(ph->p_filesz / sizeof(GBRDyn));
        for (size_t j = 0; j < dyn_count; ++j) {
            const GBRDyn *d = (const GBRDyn *)(data + ph->p_offset + j * sizeof(GBRDyn));
            if (d->d_tag == GBR_DT_NULL) break;
            if (d->d_tag == GBR_DT_INIT) out_image->init_vaddr = d->d_val;
            else if (d->d_tag == GBR_DT_INIT_ARRAY) out_image->init_array_vaddr = d->d_val;
            else if (d->d_tag == GBR_DT_INIT_ARRAYSZ) out_image->init_array_count = (uint32_t)(d->d_val / sizeof(uintptr_t));
        }
        break;
    }
    out_image->initializers_total = (out_image->init_vaddr ? 1u : 0u) + out_image->init_array_count;

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
    // Merge permissions first, then enforce W^X. A W+X collision page is NEVER
    // requested as RWX in 0.2.2: relocations are already complete, so controlled
    // bootstrap probes freeze that host page as RX. A production runtime will
    // need split/shadow handling for pages that truly need later guest writes.
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

        // iOS W^X rule: NEVER leave an anonymous page writable + executable.
        // Android 4 KiB RX/RW segments may collapse into one 16 KiB iOS page.
        // Relocations are complete now, so controlled bootstrap calls can freeze
        // that collision page as RX. This avoids a LiveContainer/iOS termination
        // that can occur even when an RWX mprotect request appears to succeed.
        int final_prot = has_wx ? (PROT_READ | PROT_EXEC) : prot;
        if (final_prot & PROT_EXEC) {
            gbr_flush_instruction_cache(addr, page);
        }
        errno = 0;
        if (mprotect(addr, page, final_prot) == 0) {
            if (has_wx) out_image->rx_fallback_pages++;
            continue;
        }
        out_image->last_errno = errno;
        free(page_prot);
        return -8;
    }
    free(page_prot);
    return 0;
}

int gbr_elf_run_initializers(GBRELFImage *image) {
    if (!image || !image->mapping || !image->mapping_size) return -1;

    image->initializers_ran = 0;
    image->last_initializer_index = 0;
    image->last_initializer_address = 0;
    uint32_t ordinal = 0;
    const uint32_t total = image->initializers_total;
    char checkpoint[192];

    if (image->init_vaddr) {
        ordinal++;
        uintptr_t address = (uintptr_t)(image->load_bias + image->init_vaddr);
        uintptr_t map_lo = (uintptr_t)image->mapping;
        uintptr_t map_hi = map_lo + image->mapping_size;
        if (address < map_lo || address >= map_hi) return -2;
        image->last_initializer_index = ordinal;
        image->last_initializer_address = (uint64_t)address;
        snprintf(checkpoint, sizeof(checkpoint), "ELF initializer %u/%u: about to CALL DT_INIT @0x%llx", ordinal, total, (unsigned long long)image->init_vaddr);
        gbr_checkpoint_now(checkpoint);
        gbr_flush_instruction_cache((void *)address, 64);
        ((void (*)(void))address)();
        image->initializers_ran++;
    }

    if (image->init_array_vaddr && image->init_array_count) {
        uintptr_t array_address = (uintptr_t)(image->load_bias + image->init_array_vaddr);
        uintptr_t map_lo = (uintptr_t)image->mapping;
        uintptr_t map_hi = map_lo + image->mapping_size;
        size_t bytes = (size_t)image->init_array_count * sizeof(uintptr_t);
        if (array_address < map_lo || array_address > map_hi || bytes > (size_t)(map_hi - array_address)) return -3;
        const uintptr_t *array = (const uintptr_t *)array_address;
        for (uint32_t i = 0; i < image->init_array_count; ++i) {
            ordinal++;
            uintptr_t address = array[i];
            // ELF toolchains may use 0 / -1 sentinels. Count them in the lifecycle
            // ordinal, but don't attempt to execute them.
            if (address == 0 || address == UINTPTR_MAX) {
                image->initializers_ran++;
                continue;
            }
            if (address < map_lo || address >= map_hi) {
                image->last_initializer_index = ordinal;
                image->last_initializer_address = (uint64_t)address;
                snprintf(checkpoint, sizeof(checkpoint), "ELF initializer %u/%u: invalid target 0x%llx", ordinal, total, (unsigned long long)address);
                gbr_checkpoint_now(checkpoint);
                return -4;
            }
            image->last_initializer_index = ordinal;
            image->last_initializer_address = (uint64_t)address;
            uint64_t guest_vaddr = (uint64_t)(address - (uintptr_t)image->load_bias);
            snprintf(checkpoint, sizeof(checkpoint), "ELF initializer %u/%u: about to CALL .init_array[%u] guest=0x%llx", ordinal, total, i, (unsigned long long)guest_vaddr);
            gbr_checkpoint_now(checkpoint);
            gbr_flush_instruction_cache((void *)address, 64);
            ((void (*)(void))address)();
            image->initializers_ran++;
        }
    }

    snprintf(checkpoint, sizeof(checkpoint), "ELF initializers completed: %u/%u", image->initializers_ran, total);
    gbr_checkpoint_now(checkpoint);
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

void *gbr_elf_address_for_vaddr(const GBRELFImage *image, uint64_t vaddr) {
    if (!image || !image->mapping) return NULL;
    if (vaddr < image->min_vaddr) return NULL;
    uint64_t delta = vaddr - image->min_vaddr;
    if (delta >= image->mapping_size) return NULL;
    return (void *)(uintptr_t)(image->load_bias + vaddr);
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

typedef struct { const char *name; const char *signature; void *fnPtr; } GBRJNINativeMethod;
typedef struct { char class_name[128]; char name[96]; char signature[160]; uintptr_t fn; } GBRCapturedNative;
static GBRCapturedNative gbr_captured_natives[192];
static uint32_t gbr_captured_native_count = 0;
static char gbr_last_jni_class[128] = "<unknown>";

void gbr_jni_reset_registered_natives(void) { gbr_captured_native_count=0; memset(gbr_captured_natives,0,sizeof(gbr_captured_natives)); snprintf(gbr_last_jni_class,sizeof(gbr_last_jni_class),"<unknown>"); }
uint32_t gbr_jni_registered_native_count(void) { return gbr_captured_native_count; }
const char *gbr_jni_registered_class_at(uint32_t i) { return i<gbr_captured_native_count ? gbr_captured_natives[i].class_name : NULL; }
const char *gbr_jni_registered_name_at(uint32_t i) { return i<gbr_captured_native_count ? gbr_captured_natives[i].name : NULL; }
const char *gbr_jni_registered_signature_at(uint32_t i) { return i<gbr_captured_native_count ? gbr_captured_natives[i].signature : NULL; }
uintptr_t gbr_jni_registered_function_at(uint32_t i) { return i<gbr_captured_native_count ? gbr_captured_natives[i].fn : 0; }

static void *gbr_jni_find_class(void *env, const char *name) {
    (void)env;
    snprintf(gbr_last_jni_class,sizeof(gbr_last_jni_class),"%s",name?name:"<null>");
    gbr_checkpoint_now("JNI callback: FindClass entered");
    return (void *)gbr_jni_nonnull();
}
static int32_t gbr_jni_register_natives(void *env, void *clazz, const void *methods, int32_t count) {
    (void)env; (void)clazz;
    gbr_checkpoint_now("JNI callback: RegisterNatives entered");
    if (!methods || count <= 0) return 0;
    const GBRJNINativeMethod *m=(const GBRJNINativeMethod *)methods;
    for (int32_t i=0;i<count && gbr_captured_native_count<192;i++) {
        GBRCapturedNative *dst=&gbr_captured_natives[gbr_captured_native_count++];
        snprintf(dst->class_name,sizeof(dst->class_name),"%s",gbr_last_jni_class);
        snprintf(dst->name,sizeof(dst->name),"%s",m[i].name?m[i].name:"<null>");
        snprintf(dst->signature,sizeof(dst->signature),"%s",m[i].signature?m[i].signature:"");
        dst->fn=(uintptr_t)m[i].fnPtr;
    }
    return 0;
}
static void gbr_jni_exception_clear(void *env) { (void)env; gbr_checkpoint_now("JNI callback: ExceptionClear entered"); }

typedef struct { void **functions; } GBRJNIEnvObj;
typedef struct { void **functions; } GBRJavaVMObj;
static void *gbr_env_table[235];
static void *gbr_vm_table[8];
static GBRJNIEnvObj gbr_env_obj;
static GBRJavaVMObj gbr_vm_obj;
static int gbr_jni_ready = 0;

static void gbr_prepare_jni(void) {
    if (gbr_jni_ready) return;
    for (size_t i = 0; i < 235; ++i) gbr_env_table[i] = (void *)&gbr_jni_zero;
    for (size_t i = 0; i < 8; ++i) gbr_vm_table[i] = (void *)&gbr_jni_zero;
    // JNIEnv function table indices from jni.h.
    gbr_env_table[6] = (void *)&gbr_jni_find_class;       // FindClass @ 0x30
    gbr_env_table[17] = (void *)&gbr_jni_exception_clear; // ExceptionClear @ 0x88
    // Return non-null IDs/refs for common lookup functions used by registration/bootstrap code.
    gbr_env_table[33] = (void *)&gbr_jni_nonnull; // GetMethodID
    gbr_env_table[94] = (void *)&gbr_jni_nonnull; // GetFieldID
    gbr_env_table[113] = (void *)&gbr_jni_nonnull; // GetStaticMethodID
    gbr_env_table[144] = (void *)&gbr_jni_nonnull; // GetStaticFieldID
    gbr_env_table[215] = (void *)&gbr_jni_register_natives; // RegisterNatives @ 0x6b8
    gbr_vm_table[4] = (void *)&gbr_jni_attach; // AttachCurrentThread @ 0x20
    gbr_vm_table[6] = (void *)&gbr_jni_attach; // GetEnv has compatible (vm, env**, version) ABI for our stub
    gbr_env_obj.functions = gbr_env_table;
    gbr_vm_obj.functions = gbr_vm_table;
    gbr_jni_ready = 1;
}
static int32_t gbr_jni_attach(void *vm, void **env, void *args) {
    (void)vm; (void)args;
    gbr_checkpoint_now("JNI callback: AttachCurrentThread entered");
    gbr_prepare_jni();
    if (env) *env = &gbr_env_obj;
    gbr_checkpoint_now("JNI callback: AttachCurrentThread returned env");
    return 0;
}

int32_t gbr_call_fake_jni_onload(void *function_address) {
    if (!function_address) return -1;
    gbr_prepare_jni();
    typedef int32_t (*OnLoadFn)(void *, void *);
    OnLoadFn fn = (OnLoadFn)function_address;
    gbr_checkpoint_now("C bridge: entering guest JNI_OnLoad now");
    int32_t result = fn(&gbr_vm_obj, NULL);
    gbr_checkpoint_now("C bridge: guest JNI_OnLoad returned");
    return result;
}

void gbr_call_void_function(void *function_address) {
    if (!function_address) return;
    typedef void (*Fn)(void);
    ((Fn)function_address)();
}
