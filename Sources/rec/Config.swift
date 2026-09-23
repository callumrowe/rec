import Foundation

/// `~/.config/rec/config.json`. Transcription needs an Obsidian vault; recording doesn't.
struct Config: Codable {
    /// Absolute path to the Obsidian vault. Transcripts go to `<vault>/transcriptions/`.
    var vault: String
    /// Parakeet model: "v2" (English, default) or "v3" (25 European languages).
    var model: String?

    static let url = Paths.home.appendingPathComponent(".config/rec/config.json")

    static func load() -> Config? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Config.self, from: data)
    }

    func save() throws {
        try FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: Self.url, options: .atomic)
    }

    var transcriptionsDir: URL {
        URL(fileURLWithPath: vault, isDirectory: true).appendingPathComponent("transcriptions", isDirectory: true)
    }
}

enum Vault {
    enum Problem: Error, CustomStringConvertible {
        case missing(String), notObsidian(String)
        var description: String {
            switch self {
            case .missing(let path): "\(path) is not a directory"
            case .notObsidian(let path): "\(path) has no .obsidian/ folder, so it isn't an Obsidian vault (open it in Obsidian once first)"
            }
        }
    }

    static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    static func check(_ path: String) -> Problem? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return .missing(path) }
        let marker = URL(fileURLWithPath: path).appendingPathComponent(".obsidian").path
        guard FileManager.default.fileExists(atPath: marker, isDirectory: &isDir), isDir.boolValue else { return .notObsidian(path) }
        return nil
    }

    /// Creates `<vault>/transcriptions/` if needed. Returns true if it was created.
    @discardableResult
    static func ensureTranscriptionsDir(_ config: Config) throws -> Bool {
        let dir = config.transcriptionsDir
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) {
            guard isDir.boolValue else { throw Problem.missing(dir.path) }
            return false
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        return true
    }

    /// Vaults Obsidian knows about, most recently opened first.
    static func known() -> [String] {
        let url = Paths.home.appendingPathComponent("Library/Application Support/obsidian/obsidian.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vaults = json["vaults"] as? [String: [String: Any]] else { return [] }
        return vaults.values
            .compactMap { v -> (String, Double)? in
                guard let path = v["path"] as? String else { return nil }
                return (path, v["ts"] as? Double ?? 0)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
            .filter { check($0) == nil }
    }
}

enum ConfigCommand {
    /// `rec config [--vault PATH] [--model v2|v3] [--show]`
    static func run(_ args: [String]) -> Never {
        var vault: String?
        var model: String?
        var show = false
        var it = args.makeIterator()
        while let arg = it.next() {
            switch arg {
            case "--vault":
                guard let value = it.next() else { fail("--vault needs a path", code: 64) }
                vault = value
            case "--model":
                guard let value = it.next(), ["v2", "v3"].contains(value) else { fail("--model takes v2 or v3", code: 64) }
                model = value
            case "--show": show = true
            default: fail("unknown option \(arg)", code: 64)
            }
        }
        let current = Config.load()
        if show {
            guard let current else { print("\(Style.warn) not configured; run `rec config`"); exit(1) }
            print("vault: \(current.vault)")
            print("transcripts: \(current.transcriptionsDir.path)")
            print("model: \(current.model ?? "v2")")
            print("config: \(Config.url.path)")
            exit(0)
        }

        let path: String
        if let vault {
            path = Vault.normalize(vault)
            if let problem = Vault.check(path) { fail(problem.description) }
        } else if model != nil, let current {
            path = current.vault
        } else {
            guard isatty(STDIN_FILENO) != 0 else { fail("no terminal; use `rec config --vault PATH`", code: 64) }
            guard let chosen = promptForVault(current: current?.vault) else { fail("no vault chosen") }
            path = chosen
        }
        let config = Config(vault: path, model: model ?? current?.model)
        apply(config)
        exit(0)
    }

    /// First-run setup from `rec start`. Returns nil if the user skipped it.
    static func firstRun() -> Config? {
        print("rec transcribes each recording into an Obsidian vault. Which one? (you can change it later with `rec config`)")
        guard let path = promptForVault(current: nil) else {
            print("\(Style.warn) transcription is off until you run `rec config`")
            return nil
        }
        let config = Config(vault: path, model: nil)
        apply(config)
        return config
    }

    private static func apply(_ config: Config) {
        do {
            let created = try Vault.ensureTranscriptionsDir(config)
            try config.save()
            print("  \(Style.dim("vault      "))  \(Style.path(config.vault))")
            print("  \(Style.dim("transcripts"))  \(Style.path(config.transcriptionsDir.path))  \(Style.dim(created ? "created" : "exists"))")
        } catch {
            fail("cannot set up \(config.transcriptionsDir.path): \(error.localizedDescription)")
        }
    }

    /// Lists vaults Obsidian knows about and accepts a number or a path.
    private static func promptForVault(current: String?) -> String? {
        var options = Vault.known()
        if let current, !options.contains(current) { options.insert(current, at: 0) }
        let defaultIndex = current.flatMap { options.firstIndex(of: $0) } ?? (options.isEmpty ? nil : 0)

        print("Obsidian vault for transcripts:")
        for (i, path) in options.enumerated() {
            print("  \(i == defaultIndex ? "›" : " ") \(i + 1)) \(path)")
        }
        if options.isEmpty { print("  (Obsidian has no vaults registered on this Mac)") }
        while true {
            print(defaultIndex.map { "Choose a number or type a path [\($0 + 1)]: " } ?? "Vault path: ", terminator: "")
            fflush(stdout)
            guard let line = readLine() else { return defaultIndex.map { options[$0] } }
            let text = line.trimmingCharacters(in: .whitespaces)
            let path: String
            if text.isEmpty {
                guard let defaultIndex else { return nil }
                path = options[defaultIndex]
            } else if let n = Int(text), options.indices.contains(n - 1) {
                path = options[n - 1]
            } else {
                path = Vault.normalize(text)
            }
            if let problem = Vault.check(path) {
                print(problem.description)
                continue
            }
            return path
        }
    }
}
