// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KernirCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "KernirCore", targets: ["KernirCore"]),
    ],
    targets: [
        // Vendored xz-utils liblzma 5.8.4 (0BSD): iOS's system liblzma is private API (App Store
        // validation rejects its lzma_* symbols), so both platforms build this copy.
        .target(
            name: "CLZMA",
            path: "Sources/CLZMA",
            exclude: ["COPYING", "COPYING.0BSD", "VERSION"],
            cSettings: [
                .define("HAVE_CONFIG_H"),
                .define("TUKLIB_SYMBOL_PREFIX", to: "lzma_"),
                .headerSearchPath("."),
                .headerSearchPath("common"),
                .headerSearchPath("liblzma/common"),
                .headerSearchPath("liblzma/check"),
                .headerSearchPath("liblzma/lz"),
                .headerSearchPath("liblzma/rangecoder"),
                .headerSearchPath("liblzma/lzma"),
                .headerSearchPath("liblzma/delta"),
                .headerSearchPath("liblzma/simple"),
            ]
        ),
        // Vendored libarchive 3.8.10 (BSD); codecs come from the system (z, bz2, iconv, expat),
        // except liblzma (CLZMA above) and zstd: no Apple SDK ships it, so zstd 1.5.7's decoder
        // is vendored in zstd/ (BSD).
        .target(
            name: "CLibArchive",
            dependencies: ["CLZMA"],
            path: "Sources/CLibArchive",
            exclude: ["COPYING", "VERSION", "zstd/LICENSE", "patches"],
            cSettings: [
                .define("HAVE_CONFIG_H"),
                .headerSearchPath("."),
                .headerSearchPath("include"),
                .headerSearchPath("zstd"),
                // zstd: portable C only (no x86-64 asm), no trace hooks (weak symbols), no legacy formats.
                .define("ZSTD_DISABLE_ASM"),
                .define("ZSTD_TRACE", to: "0"),
                .define("ZSTD_LEGACY_SUPPORT", to: "0"),
            ],
            linkerSettings: [
                .linkedLibrary("z"),
                .linkedLibrary("bz2"),
                .linkedLibrary("iconv"),
                .linkedLibrary("expat"),
            ]
        ),
        .target(
            name: "KernirCore",
            dependencies: ["CLibArchive"],
            path: "Sources/KernirCore"
        ),
        .testTarget(
            name: "KernirCoreTests",
            dependencies: ["KernirCore", "CLibArchive", "CLZMA"],
            path: "Tests/KernirCoreTests"
        ),
    ]
)
