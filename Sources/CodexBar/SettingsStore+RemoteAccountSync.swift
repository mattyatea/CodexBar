import CodexBarCore
import Foundation

extension SettingsStore {
    var remoteAccountSyncHostList: [String] {
        self.remoteAccountSyncHosts
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func synchronizeRemoteAccount(_ selection: RemoteAccountSyncSelection) async -> [RemoteAccountSyncHostResult] {
        guard self.remoteAccountSyncEnabled else { return [] }
        let hosts = self.remoteAccountSyncHostList
        guard !hosts.isEmpty else { return [] }
        let request = RemoteAccountSyncRequest(
            provider: self.remoteProvider(for: selection),
            selection: selection)
        return await RemoteAccountSynchronizer().synchronize(hosts: hosts, request: request)
    }

    func enqueueRemoteAccountSync(_ selection: RemoteAccountSyncSelection) {
        guard self.remoteAccountSyncEnabled, !self.remoteAccountSyncHostList.isEmpty else { return }
        let previousTask = self.remoteAccountSyncTask
        self.remoteAccountSyncTask = Task { @MainActor [weak self] in
            if let previousTask {
                await previousTask.value
            }
            guard let self else { return }
            let results = await self.synchronizeRemoteAccount(selection)
            let failedHosts = results.filter { !$0.succeeded }.map(\.host)
            guard !failedHosts.isEmpty else { return }
            CodexBarLog.logger(LogCategories.settings).warning(
                "Remote account sync failed",
                metadata: ["hosts": failedHosts.joined(separator: ",")])
        }
    }

    private func remoteProvider(for selection: RemoteAccountSyncSelection) -> String {
        switch selection {
        case .codex:
            "codex"
        case .tokenAccount:
            // The token-account caller supplies the provider through the overload below.
            ""
        case .claudeSwap:
            "claude"
        }
    }

    func synchronizeRemoteTokenAccount(
        provider: UsageProvider,
        account: ProviderTokenAccount) async -> [RemoteAccountSyncHostResult]
    {
        guard self.remoteAccountSyncEnabled else { return [] }
        let selection = RemoteAccountSyncSelection.tokenAccount(
            externalIdentifier: account.externalIdentifier,
            label: account.label)
        let hosts = self.remoteAccountSyncHostList
        guard !hosts.isEmpty else { return [] }
        let request = RemoteAccountSyncRequest(provider: provider.rawValue, selection: selection)
        return await RemoteAccountSynchronizer().synchronize(hosts: hosts, request: request)
    }

    func enqueueRemoteTokenAccountSync(provider: UsageProvider, account: ProviderTokenAccount) {
        guard self.remoteAccountSyncEnabled, !self.remoteAccountSyncHostList.isEmpty else { return }
        let previousTask = self.remoteAccountSyncTask
        self.remoteAccountSyncTask = Task { @MainActor [weak self] in
            if let previousTask {
                await previousTask.value
            }
            guard let self else { return }
            let results = await self.synchronizeRemoteTokenAccount(provider: provider, account: account)
            let failedHosts = results.filter { !$0.succeeded }.map(\.host)
            guard !failedHosts.isEmpty else { return }
            CodexBarLog.logger(LogCategories.settings).warning(
                "Remote account sync failed",
                metadata: [
                    "provider": provider.rawValue,
                    "hosts": failedHosts.joined(separator: ","),
                ])
        }
    }
}
