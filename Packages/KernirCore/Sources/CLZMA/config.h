/*
 * Hand-written config.h for the vendored liblzma (xz 5.8.4) in the CLZMA target,
 * valid for macOS 14+ and iOS 17+ (arm64, x86_64). Derived from the tarball's
 * ./configure on macOS arm64 with
 *   --disable-lzip-decoder --disable-microlzma --disable-clmul-crc
 *   --disable-arm64-crc32 --disable-assembler --disable-shared --disable-nls
 * keeping only the macros liblzma's sources read. Portable C only: no asm,
 * no CLMUL / ARM64 CRC32 intrinsics, internal SHA-256 (no CommonCrypto),
 * no lzip / MicroLZMA, no string conversion or file_info APIs (their sources
 * are not vendored). Threads are on: libarchive's config.h has
 * HAVE_LZMA_STREAM_ENCODER_MT, so lzma_stream_encoder_mt and lzma_cputhreads
 * must exist. TUKLIB_SYMBOL_PREFIX=lzma_ is set in Package.swift.
 */

/* Kernir: quiet vendored-liblzma noise in CI logs, as CLibArchive's config.h does (unsafeFlags is
 * not allowed in a package dependency). Every liblzma .c includes this first via sysdefs.h. The
 * only class measured on an iOS build is -Wshorten-64-to-32 (lz_decoder.h, lz_encoder.c). */
#ifdef __clang__
#pragma clang diagnostic ignored "-Wshorten-64-to-32"
#endif

#define NDEBUG 1

#define ASSUME_RAM 128
#define SIZEOF_SIZE_T 8

/* Integrity checks */
#define HAVE_CHECK_CRC32 1
#define HAVE_CHECK_CRC64 1
#define HAVE_CHECK_SHA256 1

/* Every filter: libarchive's 7-Zip reader can ask for any BCJ filter, delta, LZMA1 and LZMA2 */
#define HAVE_ENCODERS 1
#define HAVE_DECODERS 1
#define HAVE_ENCODER_LZMA1 1
#define HAVE_DECODER_LZMA1 1
#define HAVE_ENCODER_LZMA2 1
#define HAVE_DECODER_LZMA2 1
#define HAVE_ENCODER_DELTA 1
#define HAVE_DECODER_DELTA 1
#define HAVE_ENCODER_X86 1
#define HAVE_DECODER_X86 1
#define HAVE_ENCODER_POWERPC 1
#define HAVE_DECODER_POWERPC 1
#define HAVE_ENCODER_IA64 1
#define HAVE_DECODER_IA64 1
#define HAVE_ENCODER_ARM 1
#define HAVE_DECODER_ARM 1
#define HAVE_ENCODER_ARMTHUMB 1
#define HAVE_DECODER_ARMTHUMB 1
#define HAVE_ENCODER_ARM64 1
#define HAVE_DECODER_ARM64 1
#define HAVE_ENCODER_SPARC 1
#define HAVE_DECODER_SPARC 1
#define HAVE_ENCODER_RISCV 1
#define HAVE_DECODER_RISCV 1

/* Match finders */
#define HAVE_MF_HC3 1
#define HAVE_MF_HC4 1
#define HAVE_MF_BT2 1
#define HAVE_MF_BT3 1
#define HAVE_MF_BT4 1

/* Threading (POSIX threads; Apple has no pthread_condattr_setclock) */
#define MYTHREAD_POSIX 1
#define HAVE_CLOCK_GETTIME 1
#define HAVE_CLOCK_MONOTONIC 1

/* System facilities (same on macOS and iOS) */
#define TUKLIB_CPUCORES_SYSCTL 1
#define TUKLIB_PHYSMEM_SYSCONF 1
#define HAVE_STDBOOL_H 1
#define HAVE_STDINT_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_SYS_PARAM_H 1
#define HAVE__BOOL 1
#define HAVE___BUILTIN_ASSUME_ALIGNED 1
#define HAVE___BUILTIN_BSWAPXX 1

/* Symbols keep default visibility: the target is linked statically into each binary. */
#define HAVE_VISIBILITY 0

#if defined(__x86_64__) || defined(__aarch64__) || defined(__arm64__)
#define TUKLIB_FAST_UNALIGNED_ACCESS 1
#endif

#define PACKAGE "xz"
#define PACKAGE_NAME "XZ Utils"
#define PACKAGE_VERSION "5.8.4"
#define PACKAGE_BUGREPORT "xz@tukaani.org"
#define PACKAGE_URL "https://tukaani.org/xz/"
#define VERSION "5.8.4"
