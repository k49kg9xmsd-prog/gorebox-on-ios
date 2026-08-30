#ifndef GBR_ZIP_INFLATE_H
#define GBR_ZIP_INFLATE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int gbr_inflate_raw(const uint8_t *src, size_t src_len, uint8_t *dst, size_t dst_len);
int gbr_make_rx(void *address, size_t length);

#ifdef __cplusplus
}
#endif

#endif
