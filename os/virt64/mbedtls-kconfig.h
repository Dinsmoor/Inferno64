/*
 * mbedTLS configuration for the freestanding kernel build: the vendored
 * default (everything on, as the hosted emu uses) minus every feature
 * that wants an OS underneath — files, sockets, wall-clock syscalls,
 * /dev/urandom.  What devtls needs survives: TLS 1.2/1.3 client, x509,
 * PSA (TLS 1.3 requires it), all the ciphers.
 *
 * The replacements live in tlsshim.c: calloc/snprintf/time/gmtime_r
 * over kernel facilities, and mbedtls_hardware_poll over virtio-rng
 * (MBEDTLS_ENTROPY_HARDWARE_ALT below).
 */
#include "mbedtls/mbedtls_config.h"

/* no sockets, no stdio FILE, no clock_gettime */
#undef MBEDTLS_NET_C
#undef MBEDTLS_TIMING_C
#undef MBEDTLS_FS_IO
#undef MBEDTLS_PSA_ITS_FILE_C
#undef MBEDTLS_PSA_CRYPTO_STORAGE_C

/* no debug printf plumbing in a kernel */
#undef MBEDTLS_DEBUG_C
#undef MBEDTLS_SELF_TEST

/* x86 backends are noise here */
#undef MBEDTLS_AESNI_C
#undef MBEDTLS_PADLOCK_C

/* entropy: no /dev/urandom; mbedtls_hardware_poll() in tlsshim.c */
#define MBEDTLS_NO_PLATFORM_ENTROPY
#define MBEDTLS_ENTROPY_HARDWARE_ALT
