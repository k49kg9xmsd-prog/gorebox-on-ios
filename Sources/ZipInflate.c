#include "ZipInflate.h"
#include <zlib.h>
#include <sys/mman.h>
#include <libkern/OSCacheControl.h>

int gbr_inflate_raw(const uint8_t *src, size_t src_len, uint8_t *dst, size_t dst_len) {
    if (!src || !dst) return Z_STREAM_ERROR;
    z_stream stream;
    stream.zalloc = Z_NULL;
    stream.zfree = Z_NULL;
    stream.opaque = Z_NULL;
    stream.next_in = (Bytef *)src;
    stream.avail_in = (uInt)src_len;
    stream.next_out = (Bytef *)dst;
    stream.avail_out = (uInt)dst_len;

    int rc = inflateInit2(&stream, -MAX_WBITS);
    if (rc != Z_OK) return rc;
    rc = inflate(&stream, Z_FINISH);
    inflateEnd(&stream);
    if (rc != Z_STREAM_END) return rc;
    return stream.total_out == dst_len ? Z_OK : Z_BUF_ERROR;
}

int gbr_make_rx(void *address, size_t length) {
    if (!address || length == 0) return -1;
    sys_icache_invalidate(address, length);
    return mprotect(address, length, PROT_READ | PROT_EXEC);
}
