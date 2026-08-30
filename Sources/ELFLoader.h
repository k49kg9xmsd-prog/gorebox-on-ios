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
    char unresolved[16][96];
} GBRELFImage;

int gbr_elf_load_image(const uint8_t *data, size_t length, GBRELFImage *out_image);
void gbr_elf_unload_image(GBRELFImage *image);
void *gbr_elf_find_symbol(const uint8_t *data, size_t length, const GBRELFImage *image, const char *name);
const char *gbr_elf_unresolved_at(const GBRELFImage *image, uint32_t index);

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
