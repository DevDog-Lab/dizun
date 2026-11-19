import DizunCore
import DizunFixtures
import DizunImage
import Foundation

import Darwin

let version = "dizun-core 0.1.0"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

/// Hidden-input prompt (passwords never appear in argv, logs or the screen).
func promptHidden(_ prompt: String) -> String? {
    print(prompt, terminator: ": ")
    fflush(stdout)
    var term = termios()
    tcgetattr(STDIN_FILENO, &term)
    var saved = term
    term.c_lflag &= ~tcflag_t(ECHO)
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &term)
    let line = readLine()
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &saved)
    print()
    return line
}

/// Ask twice and require a match; empty input means "no encryption".
func promptNewPassword() -> String? {
    guard let first = promptHidden("パスワード"), !first.isEmpty else { return nil }
    guard let second = promptHidden("パスワード（確認）"), first == second else {
        fail("パスワードが一致しません")
    }
    return first
}

func usage() -> Never {
    print("""
    \(version) — DIZUN ZIP engine CLI (development verification tool)

    USAGE
      dizun pack <source>... -o <output.zip> [--cp932]
      dizun unpack <archive.zip> [-o <dir>] [--encoding auto|utf8|cp932]
      dizun list <archive.zip> [--encoding utf8|cp932]
      dizun optimize <image>... [--max-dimension <px>]
      dizun selftest
      dizun --version

    pack     Create a ZIP (NFC UTF-8 by default; --cp932 for legacy Japanese
             Windows tools). macOS junk files are excluded.
    unpack   Extract without ever overwriting existing files.
    list     Show entries (name, method, sizes, UTF-8 flag).
    optimize Shrink images in place (lossless; metadata removed, optional
             web resize). Files that would not shrink are left untouched.
    selftest Run the engine verification scenarios.
    """)
    exit(0)
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { usage() }
arguments.removeFirst()

switch command {
case "--version":
    print(version)
case "selftest":
    var failures = 0
    for scenario in Scenarios.all {
        do {
            try scenario.run()
            print("PASS  \(scenario.name)")
        } catch {
            failures += 1
            print("FAIL  \(scenario.name): \(error)")
        }
    }
    print("\(Scenarios.all.count - failures)/\(Scenarios.all.count) scenarios passed")
    exit(failures == 0 ? 0 : 1)
case "pack":
    var sources: [URL] = []
    var output: URL?
    var options = Packer.Options()
    var wantsPassword = false
    var legacyCrypto = false
    var index = 0
    while index < arguments.count {
        let arg = arguments[index]
        switch arg {
        case "-o":
            index += 1
            guard index < arguments.count else { fail("pack: -o needs a path") }
            output = URL(fileURLWithPath: arguments[index])
        case "--cp932":
            options.nameEncoding = .cp932
        case "--password":
            wantsPassword = true
        case "--zipcrypto":
            legacyCrypto = true
        default:
            sources.append(URL(fileURLWithPath: arg))
        }
        index += 1
    }
    guard !sources.isEmpty else { fail("pack: no sources") }
    guard let output else { fail("pack: -o <output.zip> is required") }
    if wantsPassword, let password = promptNewPassword() {
        options.encryption = legacyCrypto
            ? .zipCrypto(password: password)
            : .aes256(password: password)
        if legacyCrypto {
            FileHandle.standardError.write(Data((
                "警告: ZipCryptoは脆弱な方式です。可能な限りAES-256を使用してください。\n").utf8))
        }
    }
    do {
        let result = try Packer.pack(sources, to: output, options: options) { name in
            print("      \(name)")
        }
        print("created \(output.lastPathComponent): \(result.fileCount) files, " +
              "\(result.directoryCount) directories" +
              (result.excludedJunk.isEmpty ? "" : ", \(result.excludedJunk.count) junk excluded") +
              (result.skippedSymlinks.isEmpty ? "" : ", \(result.skippedSymlinks.count) symlinks skipped"))
    } catch {
        fail("pack failed: \(error)")
    }
case "unpack":
    var input: URL?
    var options = Unpacker.Options()
    var index = 0
    while index < arguments.count {
        let arg = arguments[index]
        switch arg {
        case "-o":
            index += 1
            guard index < arguments.count else { fail("unpack: -o needs a path") }
            options.destination = URL(fileURLWithPath: arguments[index])
        case "--encoding":
            index += 1
            guard index < arguments.count else { fail("unpack: --encoding needs a value") }
            switch arguments[index] {
            case "auto": options.forcedEncoding = nil
            case "utf8": options.forcedEncoding = .utf8
            case "cp932": options.forcedEncoding = .cp932
            default: fail("unpack: unknown encoding \(arguments[index])")
            }
        case "--password":
            options.password = promptHidden("パスワード") ?? ""
        default:
            input = URL(fileURLWithPath: arg)
        }
        index += 1
    }
    guard let input else { fail("unpack: no archive given") }
    do {
        // An encrypted archive without a password prompts once and retries.
        var result: Unpacker.Result
        do {
            result = try Unpacker.unpack(zipURL: input, options: options)
        } catch let error as DizunError where error == .passwordRequired {
            guard let password = promptHidden("パスワード"), !password.isEmpty else {
                fail("パスワードが必要です")
            }
            options.password = password
            result = try Unpacker.unpack(zipURL: input, options: options)
        }
        print("extracted \(result.extractedFiles) files, \(result.extractedDirectories) directories " +
              "→ \(result.root.lastPathComponent) (encoding: \(result.detectedEncoding.rawValue))")
        if !result.skippedUnsafe.isEmpty {
            print("skipped unsafe paths: \(result.skippedUnsafe.joined(separator: ", "))")
        }
        if !result.skippedSymlinks.isEmpty {
            print("skipped symlinks: \(result.skippedSymlinks.joined(separator: ", "))")
        }
        if !result.skippedJunk.isEmpty {
            print("skipped macOS junk: \(result.skippedJunk.count) entries")
        }
        if !result.renamedDuplicates.isEmpty {
            let pairs = result.renamedDuplicates.map { "\($0.original) → \($0.chosen)" }
            print("renamed duplicates: \(pairs.joined(separator: ", "))")
        }
        if !result.quarantineFailures.isEmpty {
            print("warning: quarantine not applied to \(result.quarantineFailures.count) items")
        }
    } catch {
        fail("unpack failed: \(error)")
    }
case "optimize":
    var files: [URL] = []
    var maxDimension: Int?
    var index = 0
    while index < arguments.count {
        let arg = arguments[index]
        if arg == "--max-dimension", index + 1 < arguments.count {
            index += 1
            guard let px = Int(arguments[index]), px > 0 else {
                fail("optimize: --max-dimension needs a positive pixel count")
            }
            maxDimension = px
        } else {
            files.append(URL(fileURLWithPath: arg))
        }
        index += 1
    }
    guard !files.isEmpty else { fail("optimize: no files given") }
    var totalBefore = 0
    var totalAfter = 0
    var savedFiles = 0
    for file in files {
        guard ImageOptimizer.isSupported(file) else {
            print("skip (unsupported): \(file.lastPathComponent)")
            continue
        }
        do {
            let result = try ImageOptimizer.optimize(file, options: .init(maxDimension: maxDimension))
            if result.skipped {
                print("keep  \(file.lastPathComponent) (\(result.originalSize) bytes)")
            } else {
                savedFiles += 1
                let percent = 100 * result.savedBytes / max(result.originalSize, 1)
                print("done  \(file.lastPathComponent): \(result.originalSize) → \(result.optimizedSize) bytes (\(percent)% smaller\(result.reencoded ? ", re-encoded" : ""))")
            }
            totalBefore += result.originalSize
            totalAfter += result.skipped ? result.originalSize : result.optimizedSize
        } catch {
            fail("optimize failed for \(file.lastPathComponent): \(error)")
        }
    }
    if totalBefore > 0 {
        let percent = 100 * (totalBefore - totalAfter) / totalBefore
        print("total: \(savedFiles) shrunk, \(totalBefore) → \(totalAfter) bytes (\(percent)% smaller)")
    }
case "list":
    var input: URL?
    var forced: NameEncoding?
    var index = 0
    while index < arguments.count {
        let arg = arguments[index]
        if arg == "--encoding", index + 1 < arguments.count {
            index += 1
            switch arguments[index] {
            case "utf8": forced = .utf8
            case "cp932": forced = .cp932
            default: fail("list: unknown encoding \(arguments[index])")
            }
        } else if !arg.hasPrefix("-") {
            input = URL(fileURLWithPath: arg)
        }
        index += 1
    }
    guard let input else { fail("list: no archive given") }
    do {
        let reader = try ZipReader(url: input)
        let entries = forced.map { reader.entriesDecoded(as: $0) } ?? reader.entries
        print("\(input.lastPathComponent): \(entries.count) entries, " +
              "encoding: \(forced?.rawValue ?? reader.detectedEncoding.rawValue)")
        for entry in entries {
            let method = entry.method == Zip.methodStore ? "store"
                : entry.method == Zip.methodDeflate ? "deflate" : "method\(entry.method)"
            let kind = entry.isDirectory ? "dir " : entry.isSymlink ? "link" : "file"
            let flag = entry.isUTF8Flagged ? "utf8" : "raw"
            print("  \(method.padding(toLength: 8, withPad: " ", startingAt: 0)) " +
                  "\(kind) \(String(entry.uncompressedSize).padding(toLength: 10, withPad: " ", startingAt: 0)) " +
                  "\(String(entry.compressedSize).padding(toLength: 10, withPad: " ", startingAt: 0)) " +
                  "[\(flag)] \(entry.name)")
        }
    } catch {
        fail("list failed: \(error)")
    }
default:
    usage()
}
