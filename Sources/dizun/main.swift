import DizunCore
import DizunFixtures
import Foundation

let version = "dizun-core 0.1.0"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func usage() -> Never {
    print("""
    \(version) — DIZUN ZIP engine CLI (development verification tool)

    USAGE
      dizun pack <source>... -o <output.zip> [--cp932]
      dizun unpack <archive.zip> [-o <dir>] [--encoding auto|utf8|cp932]
      dizun list <archive.zip> [--encoding utf8|cp932]
      dizun selftest
      dizun --version

    pack     Create a ZIP (NFC UTF-8 by default; --cp932 for legacy Japanese
             Windows tools). macOS junk files are excluded.
    unpack   Extract without ever overwriting existing files.
    list     Show entries (name, method, sizes, UTF-8 flag).
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
        default:
            sources.append(URL(fileURLWithPath: arg))
        }
        index += 1
    }
    guard !sources.isEmpty else { fail("pack: no sources") }
    guard let output else { fail("pack: -o <output.zip> is required") }
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
        default:
            input = URL(fileURLWithPath: arg)
        }
        index += 1
    }
    guard let input else { fail("unpack: no archive given") }
    do {
        let result = try Unpacker.unpack(zipURL: input, options: options)
        print("extracted \(result.extractedFiles) files, \(result.extractedDirectories) directories " +
              "→ \(result.root.lastPathComponent) (encoding: \(result.detectedEncoding.rawValue))")
        if !result.skippedUnsafe.isEmpty {
            print("skipped unsafe paths: \(result.skippedUnsafe.joined(separator: ", "))")
        }
        if !result.skippedSymlinks.isEmpty {
            print("skipped symlinks: \(result.skippedSymlinks.joined(separator: ", "))")
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
