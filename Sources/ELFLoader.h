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
    size_t allocation_size;
    void *guest_tls_page;
    uint32_t tpidr_patch_count;
    uint64_t init_vaddr;
    uint64_t init_array_vaddr;
    uint32_t init_array_count;
    uint32_t initializers_total;
    uint32_t initializers_ran;
    uint32_t last_initializer_index;
    uint64_t last_initializer_address;
    char unresolved[16][96];
} GBRELFImage;

int gbr_elf_load_image(const uint8_t *data, size_t length, GBRELFImage *out_image);
int gbr_elf_run_initializers(GBRELFImage *image);
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

// Unity JNI registration capture. RegisterNatives entries are copied while the
// guest ELF mapping is alive so Swift can inspect actual UnityPlayer entrypoints.
void gbr_jni_reset_registered_natives(void);
uint32_t gbr_jni_registered_native_count(void);
const char *gbr_jni_registered_class_at(uint32_t index);
const char *gbr_jni_registered_name_at(uint32_t index);
const char *gbr_jni_registered_signature_at(uint32_t index);
uintptr_t gbr_jni_registered_function_at(uint32_t index);


// Persistent guest-library export registry used by Launch 0.4. Unity's Android
// runtime dlopen/dlsym path can resolve already-mapped libil2cpp / plugins here.
void gbr_guest_exports_reset(void);
uint32_t gbr_guest_exports_register(const char *soname, const uint8_t *data, size_t length, const GBRELFImage *image);
void *gbr_guest_export_find(const char *name);

// Runtime filesystem root for Android-style asset/data path translation.
void gbr_set_runtime_root(const char *path);

// Captured UnityPlayer native lifecycle helpers. These call the real functions
// registered by libunity JNI_OnLoad with the Runner's fake JNIEnv/jobject tokens.
uintptr_t gbr_jni_registered_function_named(const char *name);
int32_t gbr_jni_call_native_recreate_gfx_state(void *function_address, int32_t display_index);
int32_t gbr_jni_call_native_render(void *function_address);
void gbr_jni_call_native_resume(void *function_address);
void gbr_jni_call_native_focus_changed(void *function_address, int32_t focused);
void gbr_jni_call_native_surface_changed(void *function_address);
int32_t gbr_jni_call_native_pause(void *function_address);
int32_t gbr_jni_call_native_done(void *function_address);

// iOS OpenGL ES drawable bridge implemented in Swift with @_cdecl exports.
void gbr_ios_gles_attach_layer(void *layer, int32_t width, int32_t height);
int32_t gbr_ios_gles_create_context(void);
int32_t gbr_ios_gles_create_window_surface(void);
int32_t gbr_ios_gles_make_current(void);
int32_t gbr_ios_gles_swap_buffers(void);
int32_t gbr_ios_gles_width(void);
int32_t gbr_ios_gles_height(void);
int32_t gbr_ios_gles_self_test(void);
void gbr_ios_gles_destroy(void);
void gbr_ios_gles_bind_default_framebuffer(void);

#ifdef __cplusplus
}
#endif

#endif
