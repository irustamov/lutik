/* Kernir patch 0009 (patches/0009-zip-name-charset-hooks.patch): zip entry-name hooks.
 * Implemented in libarchive/archive_read_support_format_zip.c and archive_write_set_format_zip.c. */
#ifndef KERNIR_NAMES_H
#define KERNIR_NAMES_H

#include <stddef.h>
#include <stdint.h>

struct archive;

/* 1: the current zip entry's name was declared Unicode (bit 11, or an Info-ZIP Unicode Path field 0x7075 was used).
   0: stored in an undeclared code page. -1: the archive is not being read as zip. */
int kernir_read_zip_entry_name_declared(struct archive *a);

/* For the next archive_write_header only (zip writer): write the entry's MBS pathname and symlink bytes
   verbatim (no charset conversion, no "Can't translate" warning) and set bit 11 iff utf8_flag != 0.
   Returns ARCHIVE_OK, or ARCHIVE_FATAL if the writer is not zip.
   The flag resets at the start of every archive_write_header, whether that header succeeds or fails. */
int kernir_write_zip_next_name_raw(struct archive *a, int utf8_flag);

/* Kernir patch 0010 (patches/0010-rar4-name-unicode-accessor.patch), libarchive/archive_read_support_format_rar.c.
   1: libarchive's RAR4 reader used a Unicode name for the current header (FHD_UNICODE set and either the
   encoded UTF-16 part was decoded, or the name was taken as plain UTF-8 because there is no NUL separator).
   0: the reader used the OEM bytes, or the archive is not being read as RAR4 (RAR5 included).
   Reset at the start of every header read, and 0 after a header that fails. */
int kernir_read_rar_entry_name_declared(struct archive *a);

/* Kernir patch 0012 (patches/0012-zip-comments.patch): zip comments, raw bytes.
   libarchive/archive_read_support_format_zip.c, archive_write_set_format_zip.c, archive_write.c. */

/* The current zip entry's central-directory comment. 1: *bytes and *length are set (length 0: no comment; the bytes
   stay valid until the next header read). 0: no central-directory record for this entry (the streaming reader,
   which libarchive uses when it cannot find the end record, or no current entry). -1: not being read as zip. */
int kernir_read_zip_entry_comment(struct archive *a, const void **bytes, size_t *length);

/* For the next archive_write_header only (zip writer): store `length` bytes (at most 0xffff; 0: none) verbatim as
   that entry's central-directory comment. Taken at the start of every archive_write_header, like
   kernir_write_zip_next_name_raw, whether that header succeeds or fails. ARCHIVE_FATAL if the writer is not zip or
   the length is over 0xffff. */
int kernir_write_zip_next_comment(struct archive *a, const void *bytes, size_t length);

/* The zip archive comment (at most 0xffff bytes, verbatim; 0: none), written after the end-of-central-directory
   record when the archive is closed. Call any time before archive_write_close; a later call replaces it.
   ARCHIVE_FATAL if the writer is not zip or the length is over 0xffff. */
int kernir_write_zip_archive_comment(struct archive *a, const void *bytes, size_t length);

/* Kernir patch 0016 (patches/0016-entry-count-limits.patch): the limits the 7zip and xar readers hold a whole
   header or TOC to, which they parse before the first header is returned. libarchive/archive_read.c,
   archive_read_support_format_7zip.c, archive_read_support_format_xar.c.
   - max_entries: most 7z files (numFiles), folders and unpack streams (4 times as many pack streams), and most
     <ea> elements in a xar; listed xar <file> elements over it are refused, and any <file> over 2 × it (bounded
     memory; patch 0019); also most <ea> elements in one xar file: KERNIR_XAR_EAS_PER_FILE.
   - names_bytes, name_bytes_per_entry: the xar names (pathnames, link targets, hardlink target copies and <ea> names, patch 0020) may take max(names_bytes, name_bytes_per_entry × the
     <file> elements so far) bytes of UTF-8; the allowance stops growing at max_entries elements. A 7z names block may take 2 × names_bytes (UTF-16) plus 2 bytes per
     entry, whatever numFiles claims: the block is allocated before any entry is parsed.
   Patch 0022: the seekable zip reader holds its central-directory records to max_entries (records with a new local
   header offset: the headers it returns) and 2 × max_entries (every record, saturated, before it is allocated), and
   the record names to max(names_bytes, name_bytes_per_entry × the listed records so far). Patch 0025: the record
   comments it keeps (patch 0012) are charged to that names total too, before they are copied.
   The defaults below are NestingLimits.standard's (maxEntries, maxTotalNameBytes, nameBytesPerEntry), which a
   test checks. Set before archive_read_open; ARCHIVE_OK then. A call after it returns ARCHIVE_FATAL and also puts
   the handle itself in ARCHIVE_STATE_FATAL (archive_check_magic), so the open read fails from then on; only
   archive_read_free is left. */
#define KERNIR_READ_MAX_ENTRIES 4000000
#define KERNIR_READ_NAMES_BYTES 268435456
#define KERNIR_READ_NAME_BYTES_PER_ENTRY 512
int kernir_read_set_name_limits(struct archive *a, uint64_t max_entries, uint64_t names_bytes,
                                uint64_t name_bytes_per_entry);
/* The limits set on `a` (the defaults until kernir_read_set_name_limits). */
int kernir_read_get_name_limits(struct archive *a, uint64_t *max_entries, uint64_t *names_bytes,
                                uint64_t *name_bytes_per_entry);

/* Kernir patch 0021 (patches/0021-iso9660-directory-limits.patch, archive_read_support_format_iso9660.c): the
   ISO 9660 reader holds these limits too, while it reads a directory: it counts every directory record, the root
   included, against max_entries before it allocates it, and holds Rockridge names and link targets to 65,536 bytes
   each and to max(names_bytes, name_bytes_per_entry × the records so far) in all; the continuation-area (CE) bytes
   each record parses are held to that allowance plus the bytes of the image read so far, as a total of their own. */

#endif
