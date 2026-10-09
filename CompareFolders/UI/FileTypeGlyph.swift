// MARK: - FileTypeGlyph.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Maps a filename extension to the SF Symbol a row is drawn with, from a small
// table built once per process. Deliberately not exhaustive: consulting
// `UTType` / Launch Services per row would be too slow while scrolling.

import Foundation

/// The glyph an item is drawn with, chosen from its filename extension.
///
/// This costs the comparison nothing. The engine never consults it: the lookup
/// happens in `ComparisonCellView.configure`, for the two or three dozen rows
/// actually on screen, and it is a single hash of a short string against a
/// table built once for the life of the process. Scanning a folder of a hundred
/// thousand items is exactly as fast as it was before.
///
/// The table is deliberately not exhaustive. `UTType` could classify anything
/// the system knows about, but it consults Launch Services, which means disk
/// and IPC per unknown extension — an unacceptable price to pay while
/// scrolling. Covering the extensions people actually have folders full of gets
/// nearly all of the benefit for none of the cost, and anything unrecognized
/// falls back to the plain document glyph it had before.
enum FileTypeGlyph {
    static let folder = "folder.fill"
    static let file = "doc.fill"
    static let symbolicLink = "link"
    /// A Finder alias. Not a document at all — it is a pointer to one, and the
    /// standard document glyph says the opposite.
    static let alias = "arrowshape.bounce.forward.fill"

    /// The glyph for a filename extension, or `nil` if it is not one we know.
    ///
    /// Applies to folders as well as files, because several of the things
    /// macOS presents as documents — `.pages`, `.numbers`, `.key`, `.rtfd` —
    /// are directories underneath. An item that looks like a document in the
    /// Finder should look like one here.
    static func symbol(forExtension pathExtension: String) -> String? {
        guard !pathExtension.isEmpty else { return nil }
        return table[pathExtension.lowercased()]
    }

    /// Built once, on first use, and never rebuilt.
    private static let table: [String: String] = {
        var table: [String: String] = [:]
        for (symbol, extensions) in groups {
            for name in extensions { table[name] = symbol }
        }
        return table
    }()

    /// Note `ts`: it is both MPEG transport stream and TypeScript. Video wins,
    /// because a folder of transport streams is a folder of thousands of them
    /// while a folder of TypeScript is a handful among other source files that
    /// are already covered.
    private static let groups: [(String, [String])] = [
        ("photo.fill", [
            "jpg", "jpeg", "jpe", "jfif", "png", "gif", "heic", "heif", "avif",
            "tiff", "tif", "bmp", "webp", "psd", "svg", "ico", "icns", "exr",
            "raw", "dng", "cr2", "cr3", "nef", "arw", "orf", "rw2", "raf", "srw"
        ]),
        ("film.fill", [
            "mp4", "m4v", "mov", "mkv", "avi", "wmv", "flv", "f4v", "webm",
            "mpg", "mpeg", "mpe", "m2v", "ts", "m2ts", "mts", "3gp", "3g2",
            "ogv", "vob", "rm", "rmvb", "asf", "divx", "mxf"
        ]),
        ("music.note", [
            "mp3", "m4a", "m4b", "aac", "flac", "alac", "wav", "wave", "aiff",
            "aif", "aifc", "caf", "ogg", "oga", "opus", "wma", "ape", "wv",
            "mid", "midi", "amr", "dsf", "dff", "au", "m4r"
        ]),
        ("text.document.fill", [
            "txt", "text", "rtf", "rtfd", "md", "markdown", "pages", "doc",
            "docx", "odt", "tex", "log", "nfo", "srt", "vtt", "sub", "wpd"
        ]),
        ("doc.richtext.fill", ["pdf", "ps", "eps", "xps", "oxps"]),
        ("tablecells.fill", ["csv", "tsv", "xls", "xlsx", "xlsm", "numbers", "ods"]),
        ("rectangle.on.rectangle.fill", ["key", "ppt", "pptx", "odp"]),
        ("books.vertical.fill", ["epub", "mobi", "azw", "azw3", "ibooks", "djvu", "cbz", "cbr"]),
        ("doc.zipper", [
            "zip", "tar", "gz", "tgz", "bz2", "tbz", "xz", "txz", "7z", "rar",
            "zst", "lz", "lz4", "lzma", "cpio", "pax", "sit", "sitx", "z"
        ]),
        ("externaldrive.fill", [
            "dmg", "iso", "img", "sparseimage", "sparsebundle", "cdr", "toast",
            "vhd", "vhdx", "vmdk", "qcow2"
        ]),
        ("app.fill", ["app", "exe", "msi", "pkg", "mpkg", "deb", "rpm", "appimage", "apk"]),
        ("chevron.left.forwardslash.chevron.right", [
            "swift", "c", "h", "cpp", "cc", "cxx", "hpp", "hh", "m", "mm",
            "java", "kt", "kts", "js", "jsx", "mjs", "cjs", "tsx", "py", "rb",
            "go", "rs", "php", "pl", "pm", "sh", "bash", "zsh", "fish", "sql",
            "lua", "r", "scala", "dart", "cs", "vb", "asm", "s", "css", "scss",
            "less", "html", "htm", "erb", "hbs"
        ]),
        ("curlybraces", [
            "json", "xml", "yaml", "yml", "plist", "toml", "ini", "conf",
            "cfg", "properties", "env", "lock"
        ]),
        ("textformat", ["ttf", "otf", "ttc", "otc", "woff", "woff2", "dfont", "pfb", "suit"]),
        ("cube.fill", ["obj", "fbx", "stl", "dae", "blend", "usdz", "usd", "gltf", "glb", "3ds"])
    ]
}
