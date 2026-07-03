import Foundation

// MARK: - Claude Code Project Path Codec
//
// Portable (Foundation-only, zero AppKit/UIKit) codec for the encoding Claude
// Code uses to name the per-project session directories under
// `~/.claude/projects/` (macOS/Linux) and `%USERPROFILE%\.claude\projects\`
// (Windows). This is the shared ground truth that the W4 parser port (macOS and
// Windows) both build on, so it deliberately lives in the parser layer with no
// platform-specific dependencies and can be lifted verbatim to the Windows port.
//
// # The encoding (ground truth)
//
// Claude Code derives each project directory name from the session's absolute
// working directory (`cwd`) by replacing **every character that is not an ASCII
// letter or digit with a single hyphen**:
//
//     dirName = cwd.replace(/[^A-Za-z0-9]/g, "-")   // Claude Code (Node/JS)
//
// This was verified byte-for-byte against a live macOS install: 26 of 27 real
// sessions matched exactly (the lone outlier was a session `.jsonl` copied into
// a differently-named directory, not a counterexample). Concrete observed pairs:
//
//     /Users/alberto/Documents/Developer/BurnBar
//         -> -Users-alberto-Documents-Developer-BurnBar
//     /Users/alberto/.hermes/hermes-agent        (`/.` collapses to `--`)
//         -> -Users-alberto--hermes-hermes-agent
//     /Users/alberto/Library/Application Support/… (space -> `-`)
//         -> -Users-alberto-Library-Application-Support-…
//     …/ImagineThatAiApp/Imagine That Ai App 2.0  (space and `.` -> `-`)
//         -> …-ImagineThatAiApp-Imagine-That-Ai-App-2-0
//
// The two directory forms named in `VAL-P0-PATH-021` are the *same* algorithm
// applied to a POSIX vs. a Windows absolute path:
//
//     POSIX   /Users/alberto/project   -> -Users-alberto-project      (leading `/` -> `-`)
//     Windows C:\Users\alberto\project -> C--Users-alberto-project    (drive `C`, then `:` and `\` -> `--`)
//     UNC     \\server\share\project   -> --server-share-project      (leading `\\` -> `--`)
//
// # Why decoding is lossy (and what "round-trip" means here)
//
// Because `/`, `\`, `:`, `.`, `_`, spaces, literal hyphens, and every non-ASCII
// scalar all collapse to `-`, a perfect inverse is impossible in general. What
// IS guaranteed — and what this codec is built around — is the **canonical
// round-trip invariant**, which holds for *every* input by construction:
//
//     encode(decode(dirName).reconstructedPath) == dirName            // ALWAYS true
//
// (`decode` only ever emits separators — `/`, `\`, `:` — that `encode` maps back
// to `-`, plus the preserved ASCII alphanumerics, so re-encoding reproduces the
// exact directory name.)
//
// The stronger identity holds only for "clean" paths whose components are ASCII
// alphanumeric and whose separators are the style's canonical separator:
//
//     decode(encode(path)).reconstructedPath == path                  // iff `path` is clean
//
// For paths containing dots, spaces, underscores, literal hyphens, or non-ASCII,
// `decode` returns *a* path that re-encodes identically (canonical round-trip)
// but is not literally equal to the original — the inherent, documented loss.

enum ClaudeCodeProjectPathCodec {

    /// The path convention a directory name should be decoded under.
    enum PathStyle: String, Codable, Sendable, CaseIterable {
        /// POSIX absolute/relative paths: separator `/`, root `/`.
        case posix
        /// Windows paths: drive `X:\…`, UNC `\\host\share\…`, separator `\`.
        case windows
        /// Infer the concrete style from the encoded form (see `resolveForm`).
        case auto
    }

    /// The structural shape recovered from an encoded directory name.
    enum Form: String, Codable, Sendable {
        /// A POSIX absolute path (`/Users/…`).
        case posixAbsolute
        /// A Windows drive-qualified path (`C:\…`).
        case windowsDrive
        /// A Windows UNC / backslash-rooted path (`\\host\share\…`).
        case windowsUNC
        /// A path with no leading root separator (`project/sub`).
        case relative
    }

    /// The result of decoding an encoded `~/.claude/projects/` directory name.
    struct DecodedProjectPath: Equatable, Sendable {
        /// The directory name that was decoded (the codec input), unchanged.
        let encodedDirectoryName: String
        /// A reconstruction that satisfies `encode(reconstructedPath) == encodedDirectoryName`.
        /// This is the round-trip-exact form; separators may be duplicated where
        /// the original path had adjacent non-alphanumerics (e.g. `/.hidden`).
        let reconstructedPath: String
        /// A human-facing normalization of `reconstructedPath` (runs of the
        /// separator collapsed). Convenience for UI only — NOT round-trip safe.
        let displayPath: String
        /// The concrete style used (`.auto` is always resolved to `.posix`/`.windows`).
        let style: PathStyle
        /// The structural shape recovered.
        let form: Form
        /// The drive letter for `.windowsDrive`, otherwise `nil`.
        let driveLetter: Character?
        /// `true` when the root interpretation itself is ambiguous — currently a
        /// `--`-prefixed name under `.auto`, which is a POSIX `/.hidden…` path on
        /// macOS/Linux but a UNC `\\host\…` path on Windows. Callers that know the
        /// source OS should pass an explicit `style` to disambiguate.
        let isAmbiguous: Bool
    }

    // MARK: Encode (ground truth)

    /// Encode an absolute (or relative) path to its Claude Code directory name by
    /// replacing every non-`[A-Za-z0-9]` character with `-`.
    ///
    /// Iteration is over **UTF-16 code units** to match Claude Code's Node/JS
    /// `String.replace(/[^A-Za-z0-9]/g, "-")` semantics exactly: a BMP scalar such
    /// as `é` yields one `-`, while an astral scalar such as `😀` (a surrogate
    /// pair) yields two. (The astral detail is modeled on JS string semantics and
    /// is confirmed against a real Windows capture in `VAL-P0-PATH-022`.)
    static func encode(_ path: String) -> String {
        var result = ""
        result.reserveCapacity(path.utf16.count)
        for unit in path.utf16 {
            let isDigit = unit >= 0x30 && unit <= 0x39   // 0-9
            let isUpper = unit >= 0x41 && unit <= 0x5A   // A-Z
            let isLower = unit >= 0x61 && unit <= 0x7A   // a-z
            if isDigit || isUpper || isLower, let scalar = Unicode.Scalar(unit) {
                result.unicodeScalars.append(scalar)
            } else {
                result.append("-")
            }
        }
        return result
    }

    // MARK: Decode

    /// Decode a Claude Code project directory name back to a plausible path.
    ///
    /// Handles both observed forms — the drive-prefixed `C--Users-…` form and the
    /// leading-dash `-Users-…` form — plus UNC and relative shapes. The result
    /// always satisfies the canonical round-trip invariant
    /// `encode(result.reconstructedPath) == directoryName`.
    static func decode(_ directoryName: String, style: PathStyle = .auto) -> DecodedProjectPath {
        let form = resolveForm(directoryName, style: style)
        let concreteStyle: PathStyle = (form == .windowsDrive || form == .windowsUNC) ? .windows : .posix

        var driveLetter: Character?
        let reconstructed: String

        switch form {
        case .posixAbsolute, .relative:
            reconstructed = String(directoryName.map { $0 == "-" ? "/" : $0 })

        case .windowsUNC:
            reconstructed = String(directoryName.map { $0 == "-" ? "\\" : $0 })

        case .windowsDrive:
            let chars = Array(directoryName)
            driveLetter = chars.first
            var body = ""
            var placedColon = false
            for char in chars.dropFirst() {
                if char == "-" {
                    if placedColon {
                        body.append("\\")
                    } else {
                        body.append(":")
                        placedColon = true
                    }
                } else {
                    body.append(char)
                }
            }
            reconstructed = String(chars.first.map(String.init) ?? "") + body
        }

        let isAmbiguous = style == .auto
            && form == .posixAbsolute
            && directoryName.hasPrefix("--")

        return DecodedProjectPath(
            encodedDirectoryName: directoryName,
            reconstructedPath: reconstructed,
            displayPath: normalizeForDisplay(reconstructed, form: form),
            style: concreteStyle,
            form: form,
            driveLetter: driveLetter,
            isAmbiguous: isAmbiguous
        )
    }

    /// Classify the structural form of an encoded directory name under a style.
    static func resolveForm(_ name: String, style: PathStyle) -> Form {
        guard let first = name.first else { return .relative }
        let chars = Array(name)
        let startsWithDriveSingle = isASCIILetter(first) && chars.count >= 2 && chars[1] == "-"
        let startsWithDriveDouble = startsWithDriveSingle && chars.count >= 3 && chars[2] == "-"

        switch style {
        case .windows:
            if startsWithDriveSingle { return .windowsDrive }
            // Any non-drive Windows name is a backslash path; `--`-prefixed names
            // are UNC (`\\host\share`). We fold both under `.windowsUNC` because
            // the reconstruction (every `-` -> `\`) is identical.
            return .windowsUNC

        case .posix:
            return first == "-" ? .posixAbsolute : .relative

        case .auto:
            // The definitive Windows signal is a drive letter followed by `--`
            // (drive `:` then root `\`); a single trailing `-` is too ambiguous
            // with a relative name like `a-b`, so `.auto` does not treat it as a
            // drive.
            if startsWithDriveDouble { return .windowsDrive }
            if first == "-" { return .posixAbsolute }
            return .relative
        }
    }

    // MARK: Round-trip helpers

    /// The always-true canonical round-trip: re-encoding a decoded path reproduces
    /// the exact directory name. Useful as a property assertion over any input.
    static func canonicalRoundTrips(_ directoryName: String, style: PathStyle = .auto) -> Bool {
        encode(decode(directoryName, style: style).reconstructedPath) == directoryName
    }

    /// The stronger identity round-trip: `decode(encode(path)) == path`. Holds
    /// only for "clean" paths (ASCII-alphanumeric components separated by the
    /// style's canonical separator). Returns `false` for lossy paths — by design.
    static func cleanlyRoundTrips(_ path: String, style: PathStyle = .auto) -> Bool {
        decode(encode(path), style: style).reconstructedPath == path
    }

    // MARK: Display

    private static func normalizeForDisplay(_ path: String, form: Form) -> String {
        switch form {
        case .posixAbsolute, .relative:
            return collapseRuns(of: "/", in: path)
        case .windowsDrive:
            return collapseRuns(of: "\\", in: path)
        case .windowsUNC:
            // Preserve the leading `\\` UNC prefix; collapse the remainder.
            if path.hasPrefix("\\\\") {
                let tail = collapseRuns(of: "\\", in: String(path.dropFirst(2)))
                return "\\\\" + tail
            }
            return collapseRuns(of: "\\", in: path)
        }
    }

    private static func collapseRuns(of separator: Character, in path: String) -> String {
        var out = ""
        out.reserveCapacity(path.count)
        var previousWasSeparator = false
        for char in path {
            if char == separator {
                if previousWasSeparator { continue }
                previousWasSeparator = true
            } else {
                previousWasSeparator = false
            }
            out.append(char)
        }
        return out
    }

    private static func isASCIILetter(_ char: Character) -> Bool {
        ("a"..."z").contains(char) || ("A"..."Z").contains(char)
    }
}
