# Third-party notices

Kernir is MIT-licensed (see [LICENSE](LICENSE)). It includes or links the following third-party software.

## libarchive

Vendored as C source in `Packages/KernirCore/Sources/CLibArchive` and compiled into the app.

- Version: 3.8.10
- Project: https://www.libarchive.org, https://github.com/libarchive/libarchive
- License: BSD 2-Clause (below), except:
  - `archive_read_support_filter_compress.c` and `archive_write_add_filter_compress.c`, which are also partly under a 3-clause UC Regents (BSD) copyright;
  - `archive_parse_date.c`, which is in the public domain;
  - the BLAKE2 files (`archive_blake2*.{c,h}`), which may be used under your choice of CC0 1.0, OpenSSL or Apache 2.0.
- The authoritative text is the verbatim `COPYING` file at `Packages/KernirCore/Sources/CLibArchive/COPYING`.

```
Copyright (c) 2003-2018 Tim Kientzle and the libarchive contributors
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer
   in this position and unchanged.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR(S) ``AS IS'' AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
IN NO EVENT SHALL THE AUTHOR(S) BE LIABLE FOR ANY DIRECT, INDIRECT,
INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## zstd

Zstandard's decompression library, vendored as C source in `Packages/KernirCore/Sources/CLibArchive/zstd` and compiled into the app. It decodes .zst files; macOS and iOS ship no zstd library.

- Version: 1.5.7
- Project: https://facebook.github.io/zstd/, https://github.com/facebook/zstd
- License: dual-licensed under BSD or GPLv2; Kernir uses it under the BSD license (below).
- The authoritative text is the verbatim `LICENSE` file at `Packages/KernirCore/Sources/CLibArchive/zstd/LICENSE`.

```
BSD License

For Zstandard software

Copyright (c) Meta Platforms, Inc. and affiliates. All rights reserved.

Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

 * Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

 * Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

 * Neither the name Facebook, nor Meta, nor the names of its contributors may
   be used to endorse or promote products derived from this software without
   specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## xz liblzma

XZ Utils' liblzma, vendored as C source in `Packages/KernirCore/Sources/CLZMA` and compiled into the app. It reads and writes .xz and .lzma files and the LZMA/LZMA2 data inside 7z and zip archives. This software includes code from XZ Utils <https://tukaani.org/xz/>.

- Version: 5.8.4
- Project: https://tukaani.org/xz/, https://github.com/tukaani-project/xz
- License: BSD Zero Clause License (0BSD, below). Copyright (C) The XZ Utils authors and contributors.
- The authoritative texts are the verbatim `COPYING` and `COPYING.0BSD` files at `Packages/KernirCore/Sources/CLZMA`.

```
Permission to use, copy, modify, and/or distribute this
software for any purpose with or without fee is hereby granted.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL
WARRANTIES WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL
THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR
CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM
LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT,
NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN
CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
```

## System libraries

Compression codecs (zlib, bzip2, libcompression) are the copies that ship with macOS and iOS. They are linked dynamically and are not redistributed with Kernir.
