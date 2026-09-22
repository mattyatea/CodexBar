import Foundation

/// A selectable SSH destination. The same value type can represent a host
/// discovered from OpenSSH config or one entered manually by the user.
public struct RemoteSSHHost: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let displayName: String
    public let alias: String
    public let hostname: String?
    public let user: String?
    public let port: Int?

    public var id: String {
        self.alias
    }

    public init(
        displayName: String? = nil,
        alias: String,
        hostname: String? = nil,
        user: String? = nil,
        port: Int? = nil)
    {
        self.alias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = Self.nonEmpty(displayName) ?? self.alias
        self.hostname = Self.nonEmpty(hostname)
        self.user = Self.nonEmpty(user)
        self.port = port.flatMap { (1...65535).contains($0) ? $0 : nil }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

/// Reads the non-secret connection metadata CodexBar needs to present SSH
/// destinations. OpenSSH `Include` files are expanded without executing a
/// shell; missing files and include cycles are ignored like optional config
/// fragments.
public enum RemoteSSHConfig {
    public static func hosts(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default) throws -> [RemoteSSHHost]
    {
        let configURL = homeDirectory
            .appendingPathComponent(".ssh", isDirectory: true)
            .appendingPathComponent("config", isDirectory: false)
        guard fileManager.fileExists(atPath: configURL.path) else { return [] }
        return try self.hosts(
            at: configURL,
            fileManager: fileManager,
            homeDirectory: homeDirectory)
    }

    public static func hosts(
        at configURL: URL,
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> [RemoteSSHHost]
    {
        var visited: Set<String> = []
        let contents = try self.expandedContents(
            at: configURL,
            fileManager: fileManager,
            homeDirectory: homeDirectory,
            visited: &visited,
            depth: 0)
        return self.parse(contents)
    }

    private static let maximumIncludeDepth = 16

    private static func expandedContents(
        at configURL: URL,
        fileManager: FileManager,
        homeDirectory: URL,
        visited: inout Set<String>,
        depth: Int) throws -> String
    {
        guard depth <= self.maximumIncludeDepth else { return "" }
        let normalizedURL = configURL.standardizedFileURL
        guard visited.insert(normalizedURL.path).inserted else { return "" }

        let contents = try String(contentsOf: normalizedURL, encoding: .utf8)
        var expanded = ""
        for rawLine in contents.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard let tokens = self.tokens(in: line), !tokens.isEmpty else {
                expanded += line + "\n"
                continue
            }

            let (keyword, arguments) = self.directive(from: tokens)
            guard keyword.caseInsensitiveCompare("include") == .orderedSame else {
                expanded += line + "\n"
                continue
            }

            for argument in arguments {
                let includeURLs = self.includeURLs(
                    for: argument,
                    includingFile: normalizedURL,
                    homeDirectory: homeDirectory,
                    fileManager: fileManager)
                for includeURL in includeURLs {
                    guard let included = try? self.expandedContents(
                        at: includeURL,
                        fileManager: fileManager,
                        homeDirectory: homeDirectory,
                        visited: &visited,
                        depth: depth + 1)
                    else { continue }
                    expanded += included
                }
            }
        }
        return expanded
    }

    private static func includeURLs(
        for rawPattern: String,
        includingFile: URL,
        homeDirectory: URL,
        fileManager: FileManager) -> [URL]
    {
        var pattern = rawPattern
        if pattern == "~" {
            pattern = homeDirectory.path
        } else if pattern.hasPrefix("~/") {
            pattern = homeDirectory
                .appendingPathComponent(String(pattern.dropFirst(2)))
                .path
        } else if pattern.hasPrefix("%d/") {
            pattern = homeDirectory
                .appendingPathComponent(String(pattern.dropFirst(3)))
                .path
        } else if !(pattern as NSString).isAbsolutePath {
            pattern = includingFile
                .deletingLastPathComponent()
                .appendingPathComponent(pattern)
                .path
        }

        return self.expandPath(pattern, fileManager: fileManager)
    }

    private static func expandPath(_ path: String, fileManager: FileManager) -> [URL] {
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        guard let first = components.first else { return [] }
        var candidates = [URL(fileURLWithPath: first == "/" ? "/" : first, isDirectory: true)]

        for component in components.dropFirst() {
            var next: [URL] = []
            for candidate in candidates {
                if self.containsGlob(component) {
                    guard let children = try? fileManager.contentsOfDirectory(
                        at: candidate,
                        includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                        options: [.skipsHiddenFiles])
                    else { continue }
                    next.append(contentsOf: children.filter {
                        self.glob(component, matches: $0.lastPathComponent)
                    })
                } else {
                    next.append(candidate.appendingPathComponent(component))
                }
            }
            candidates = next
            if candidates.isEmpty { return [] }
        }

        return candidates
            .filter { url in
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]) else { return false }
                return values.isRegularFile == true
            }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func containsGlob(_ value: String) -> Bool {
        value.contains("*") || value.contains("?") || value.contains("[")
    }

    public static func parse(_ contents: String) -> [RemoteSSHHost] {
        var sections: [Section] = [Section(patterns: nil)]

        for rawLine in contents.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            guard let tokens = self.tokens(in: String(rawLine)), !tokens.isEmpty else { continue }
            let (keyword, arguments) = self.directive(from: tokens)
            guard !keyword.isEmpty else { continue }

            if keyword.caseInsensitiveCompare("host") == .orderedSame {
                guard !arguments.isEmpty else { continue }
                sections.append(Section(patterns: arguments))
                continue
            }

            guard let value = arguments.first else { continue }
            let sectionIndex = sections.index(before: sections.endIndex)
            switch keyword.lowercased() {
            case "hostname":
                if sections[sectionIndex].hostname == nil {
                    sections[sectionIndex].hostname = value
                }
            case "user":
                if sections[sectionIndex].user == nil {
                    sections[sectionIndex].user = value
                }
            case "port":
                if sections[sectionIndex].port == nil,
                   let port = Int(value),
                   (1...65535).contains(port)
                {
                    sections[sectionIndex].port = port
                }
            default:
                continue
            }
        }

        let aliases = self.concreteAliases(in: sections)
        return aliases.map { alias in
            var hostname: String?
            var user: String?
            var port: Int?

            for section in sections where section.matches(alias) {
                if hostname == nil { hostname = section.hostname }
                if user == nil { user = section.user }
                if port == nil { port = section.port }
            }

            return RemoteSSHHost(
                alias: alias,
                hostname: hostname,
                user: user,
                port: port)
        }
    }

    private struct Section {
        let patterns: [String]?
        var hostname: String?
        var user: String?
        var port: Int?

        init(patterns: [String]?) {
            self.patterns = patterns
        }

        func matches(_ alias: String) -> Bool {
            guard let patterns else { return true }

            var positiveMatch = false
            for rawPattern in patterns {
                if rawPattern.hasPrefix("!") {
                    let pattern = String(rawPattern.dropFirst())
                    if RemoteSSHConfig.glob(pattern, matches: alias) { return false }
                } else if RemoteSSHConfig.glob(rawPattern, matches: alias) {
                    positiveMatch = true
                }
            }
            return positiveMatch
        }
    }

    private static func concreteAliases(in sections: [Section]) -> [String] {
        var seen: Set<String> = []
        var aliases: [String] = []

        for section in sections {
            guard let patterns = section.patterns else { continue }
            for pattern in patterns where self.isConcreteAlias(pattern) {
                let key = pattern.lowercased()
                if seen.insert(key).inserted {
                    aliases.append(pattern)
                }
            }
        }
        return aliases
    }

    private static func isConcreteAlias(_ pattern: String) -> Bool {
        !pattern.isEmpty &&
            !pattern.hasPrefix("!") &&
            !pattern.contains("*") &&
            !pattern.contains("?")
    }

    private static func directive(from tokens: [String]) -> (keyword: String, arguments: [String]) {
        guard let first = tokens.first else { return ("", []) }
        if let equals = first.firstIndex(of: "=") {
            let keyword = String(first[..<equals])
            let inlineValue = String(first[first.index(after: equals)...])
            let values = inlineValue.isEmpty ? Array(tokens.dropFirst()) : [inlineValue] + tokens.dropFirst()
            return (keyword, values)
        }

        var arguments = Array(tokens.dropFirst())
        if arguments.first == "=" {
            arguments.removeFirst()
        } else if let value = arguments.first, value.hasPrefix("=") {
            arguments[0] = String(value.dropFirst())
        }
        return (first, arguments)
    }

    /// Tokenizes the small OpenSSH subset this parser consumes. Quotes and
    /// backslash escapes are handled so values such as `User "build user"`
    /// remain intact. A malformed quoted line is ignored as a whole.
    private static func tokens(in line: String) -> [String]? {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false
        var tokenStarted = false

        for character in line {
            if escaping {
                current.append(character)
                tokenStarted = true
                escaping = false
                continue
            }

            if character == "\\" {
                escaping = true
                tokenStarted = true
                continue
            }

            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                tokenStarted = true
                continue
            }

            if character == "\"" || character == "'" {
                quote = character
                tokenStarted = true
            } else if character == "#" {
                break
            } else if character.isWhitespace {
                if tokenStarted {
                    tokens.append(current)
                    current = ""
                    tokenStarted = false
                }
            } else {
                current.append(character)
                tokenStarted = true
            }
        }

        guard quote == nil else { return nil }
        if escaping {
            current.append("\\")
        }
        if tokenStarted {
            tokens.append(current)
        }
        return tokens
    }

    private static func glob(_ pattern: String, matches value: String) -> Bool {
        let pattern = Array(pattern.lowercased())
        let value = Array(value.lowercased())
        var patternIndex = 0
        var valueIndex = 0
        var starIndex: Int?
        var starValueIndex = 0

        while valueIndex < value.count {
            if patternIndex < pattern.count,
               pattern[patternIndex] == "?" || pattern[patternIndex] == value[valueIndex]
            {
                patternIndex += 1
                valueIndex += 1
            } else if patternIndex < pattern.count, pattern[patternIndex] == "*" {
                starIndex = patternIndex
                patternIndex += 1
                starValueIndex = valueIndex
            } else if let starIndex {
                patternIndex = starIndex + 1
                starValueIndex += 1
                valueIndex = starValueIndex
            } else {
                return false
            }
        }

        while patternIndex < pattern.count, pattern[patternIndex] == "*" {
            patternIndex += 1
        }
        return patternIndex == pattern.count
    }
}
