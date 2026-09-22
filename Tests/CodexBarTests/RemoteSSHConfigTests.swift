import CodexBarCore
import Foundation
import Testing

struct RemoteSSHConfigTests {
    @Test
    func `empty and comment only configs produce no hosts`() {
        #expect(RemoteSSHConfig.parse("").isEmpty)
        #expect(RemoteSSHConfig.parse("# comment\n   # another comment\n").isEmpty)
    }

    @Test
    func `parses concrete aliases and connection metadata`() {
        let hosts = RemoteSSHConfig.parse(
            """
            Host build staging
              HostName build.internal.example
              User deploy
              Port 2222

            Host database
              HostName 10.0.0.12
            """)

        #expect(hosts == [
            RemoteSSHHost(
                alias: "build",
                hostname: "build.internal.example",
                user: "deploy",
                port: 2222),
            RemoteSSHHost(
                alias: "staging",
                hostname: "build.internal.example",
                user: "deploy",
                port: 2222),
            RemoteSSHHost(alias: "database", hostname: "10.0.0.12"),
        ])
    }

    @Test
    func `wildcard and negated patterns are not selectable candidates`() {
        let hosts = RemoteSSHConfig.parse(
            """
            Host *
              User default-user
              Port 2200

            Host *.corp !blocked.corp jumpbox
              HostName gateway.corp

            Host api?
              User ignored-pattern-user
            """)

        #expect(hosts == [
            RemoteSSHHost(
                alias: "jumpbox",
                hostname: "gateway.corp",
                user: "default-user",
                port: 2200),
        ])
    }

    @Test
    func `duplicate aliases are emitted once and first obtained values win`() {
        let hosts = RemoteSSHConfig.parse(
            """
            Host shared
              User first-user

            Host shared
              User later-user
              HostName shared.example.com
              Port 2022
            """)

        #expect(hosts == [
            RemoteSSHHost(
                alias: "shared",
                hostname: "shared.example.com",
                user: "first-user",
                port: 2022),
        ])
    }

    @Test
    func `quoted values comments and equals syntax are handled`() {
        let hosts = RemoteSSHConfig.parse(
            """
            Host "quoted-host" # visible candidate
              HostName="host.example.com"
              User "build user"
              Port="2024"
              IdentityFile "~/.ssh/private key" # intentionally ignored
            """)

        #expect(hosts == [
            RemoteSSHHost(
                alias: "quoted-host",
                hostname: "host.example.com",
                user: "build user",
                port: 2024),
        ])
    }

    @Test
    func `malformed lines and invalid ports do not discard valid hosts`() {
        let hosts = RemoteSSHConfig.parse(
            """
            Host valid
              HostName valid.example.com
              Port nope
              User "unterminated
              this is not a supported directive

            Host second
              Port 70000
              User operator
            """)

        #expect(hosts == [
            RemoteSSHHost(alias: "valid", hostname: "valid.example.com"),
            RemoteSSHHost(alias: "second", user: "operator"),
        ])
    }

    @Test
    func `parse keeps include directives outside the pure string parser boundary`() {
        let hosts = RemoteSSHConfig.parse(
            """
            Include ~/.ssh/conf.d/*
            Host local-only
              HostName local.example.com
            """)

        #expect(hosts == [RemoteSSHHost(alias: "local-only", hostname: "local.example.com")])
    }

    @Test
    func `hosts expands relative and home based include globs`() throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("remote-ssh-config-\(UUID().uuidString)", isDirectory: true)
        let sshDirectory = home.appendingPathComponent(".ssh", isDirectory: true)
        let fragmentsDirectory = sshDirectory.appendingPathComponent("conf.d", isDirectory: true)
        try fileManager.createDirectory(at: fragmentsDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: home) }

        let configURL = sshDirectory.appendingPathComponent("config")
        try "Include ~/.ssh/conf.d/*.conf\nHost local-only\n  HostName local.example.com\n"
            .write(to: configURL, atomically: true, encoding: .utf8)
        try "Host included\n  HostName included.example.com\n"
            .write(
                to: fragmentsDirectory.appendingPathComponent("included.conf"),
                atomically: true,
                encoding: .utf8)

        let hosts = try RemoteSSHConfig.hosts(
            at: configURL,
            fileManager: fileManager,
            homeDirectory: home)

        #expect(hosts == [
            RemoteSSHHost(alias: "included", hostname: "included.example.com"),
            RemoteSSHHost(alias: "local-only", hostname: "local.example.com"),
        ])
    }

    @Test
    func `manual hosts use the same normalized value type`() {
        let host = RemoteSSHHost(
            displayName: "Build box",
            alias: " build ",
            hostname: " build.example.com ",
            user: " deploy ",
            port: 2222)

        #expect(host.displayName == "Build box")
        #expect(host.alias == "build")
        #expect(host.hostname == "build.example.com")
        #expect(host.user == "deploy")
        #expect(host.port == 2222)
        #expect(host.id == "build")
    }
}
