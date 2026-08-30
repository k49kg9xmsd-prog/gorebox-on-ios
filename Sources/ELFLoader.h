#ifndef GBR_ELF_LOADER_H
#define GBR_ELF_LOADER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    void *mapping;
    size_t mapping_size;
    uint64_t min_vaddr;
    uint64_t load_bias;
    uint64_t entry_address;
    uint32_t relocation_total;
    uint32_t relocation_applied;
    uint32_t unresolved_count;
    uint32_t load_segment_count;
    int32_t last_errno;
    uint32_t host_page_size;
    uint32_t wx_collision_pages;
    uint32_t rwx_pages;
    uint32_t rx_fallback_pages;
    char unresolved[16][96];
} GBRELFImage;

int gbr_elf_load_image(const uint8_t *data, size_t length, GBRELFImage *out_image);
void gbr_elf_unload_image(GBRELFImage *image);
void *gbr_elf_find_symbol(const uint8_t *data, size_t length, const GBRELFImage *image, const char *name);
const char *gbr_elf_unresolved_at(const GBRELFImage *image, uint32_t index);
void *gbr_elf_address_for_vaddr(const GBRELFImage *image, uint64_t vaddr);

// Durable crash checkpoint support. The path is supplied by Swift before a
// dangerous guest call. Writes are fsync'd so the last step survives process death.
void gbr_set_checkpoint_path(const char *path);
void gbr_checkpoint_now(const char *message);
void gbr_clear_checkpoint(void);

// Controlled JNI probes. These build tiny fake JavaVM/JNIEnv tables whose purpose is
// only to let JNI_OnLoad registration code execute far enough to report a result.
int32_t gbr_call_fake_jni_onload(void *function_address);
void gbr_call_void_function(void *function_address);

// Exposed for diagnostics.
void *gbr_compat_resolve_symbol(const char *name);

#ifdef __cplusplus
}
#endif

#endif
