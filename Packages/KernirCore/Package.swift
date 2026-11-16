// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KernirCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "KernirCore", targets: ["KernirCore"]),
    ],
    targets: [
        // Vendored libarchive 3.8.10 (BSD); codecs come from the system (z, bz2, lzma, iconv, expat),
        // except zstd: no Apple SDK ships it, so zstd 1.5.7's decoder is vendored in zstd/ (BSD).
        .target(
            name: "CLibArchive",
            path: "Sources/CLibArchive",
            exclude: ["COPYING", "VERSION", "xz/COPYING", "zstd/LICENSE", "patches"],
            cSettings: [
                .define("HAVE_CONFIG_H"),
                .headerSearchPath("."),
                .headerSearchPath("include"),
                .headerSearchPath("xz"),
                .headerSearchPath("zstd"),
                // zstd: portable C only (no x86-64 asm), no trace hooks (weak symbols), no legacy formats.
                .define("ZSTD_DISABLE_ASM"),
                .define("ZSTD_TRACE", to: "0"),
                .define("ZSTD_LEGACY_SUPPORT", to: "0"),
            ],
            linkerSettings: [
                .linkedLibrary("z"),
                .linkedLibrary("bz2"),
                .linkedLibrary("lzma"),
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
            dependencies: ["KernirCore", "CLibArchive"],
            path: "Tests/KernirCoreTests"
        ),
    ]
)
