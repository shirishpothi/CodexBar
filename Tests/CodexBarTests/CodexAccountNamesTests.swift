import CodexBarCore
import Foundation
import Testing

struct CodexAccountNamesTests {
    @Test
    func `names follow a login and workspace across source and token changes`() {
        let original = Self.account(email: "USER@example.com", workspace: "team-a")
        let promoted = Self.account(
            email: "user@example.com", workspace: "team-a", source: .liveSystem,
            fingerprint: String(repeating: "b", count: 64))
        let otherLogin = Self.account(email: "other@example.com", workspace: "team-a")
        let otherWorkspace = Self.account(email: "user@example.com", workspace: "team-b")
        #expect(original.customNameKey == promoted.customNameKey)
        #expect(original.customNameKey != otherLogin.customNameKey)
        #expect(original.customNameKey != otherWorkspace.customNameKey)
    }

    @Test
    func `names survive config serialization and preserve account identity`() throws {
        let account = Self.account(email: "user@example.com", workspace: "team-a")
        var config = ProviderConfig(id: .codex)
        config.codexAccountNames = [account.customNameKey: "  School  "]
        let restored = try JSONDecoder().decode(ProviderConfig.self, from: JSONEncoder().encode(config))
        let projection = CodexVisibleAccountProjection(
            visibleAccounts: [account], activeVisibleAccountID: account.id,
            liveVisibleAccountID: nil, hasUnreadableAddedAccountStore: false)
        let renamed = try #require(projection.applyingCustomNames(restored.codexAccountNames ?? [:])
            .visibleAccounts.first)
        #expect(renamed.displayName == "School")
        #expect(renamed.menuDisplayName == "School")
        #expect(renamed.withCustomName(nil) == account)
        #expect(projection.applyingCustomNames([:]) == projection)
    }

    @Test
    func `empty names restore defaults and duplicate names stay distinguishable`() {
        let first = Self.account(email: "first@example.com", workspace: "team-a")
        let second = Self.account(email: "second@example.com", workspace: "team-a")
        #expect(first.withCustomName(" \n ").displayName == first.displayName)
        let projection = CodexVisibleAccountProjection(
            visibleAccounts: [first, second], activeVisibleAccountID: first.id,
            liveVisibleAccountID: nil, hasUnreadableAddedAccountStore: false)
            .applyingCustomNames([first.customNameKey: "Work", second.customNameKey: "Work"])
        #expect(Set(projection.visibleAccounts.map(\.menuDisplayName)).count == 2)
    }

    @Test
    func `names survive workspace discovery without leaking to a sibling workspace`() throws {
        let savedID = UUID()
        let unknown = Self.account(email: "user@example.com", workspace: nil, storedID: savedID)
        let resolved = Self.account(email: "user@example.com", workspace: "team-a", storedID: savedID)
        let sibling = Self.account(email: "user@example.com", workspace: "team-b")
        let names = [unknown.customNameKey: "School"]
        let projection = CodexVisibleAccountProjection(
            visibleAccounts: [resolved, sibling], activeVisibleAccountID: resolved.id,
            liveVisibleAccountID: nil, hasUnreadableAddedAccountStore: false)
            .applyingCustomNames(names)
        let renamed = try #require(projection.visibleAccounts.first { $0.storedAccountID == savedID })
        #expect(renamed.customName == "School")
        #expect(projection.visibleAccounts.first { $0.storedAccountID == sibling.storedAccountID }?.customName == nil)
        let preferred = projection
            .applyingCustomNames(names.merging([resolved.customNameKey: "Work"]) { _, new in new })
        #expect(preferred.visibleAccounts.first { $0.storedAccountID == savedID }?.customName == "Work")
    }

    private static func account(
        email: String, workspace: String?, storedID: UUID = UUID(),
        source: CodexActiveSource = .managedAccount(id: UUID()),
        fingerprint: String = String(repeating: "a", count: 64)) -> CodexVisibleAccount
    {
        CodexVisibleAccount(
            id: email, email: email, workspaceAccountID: workspace, authFingerprint: fingerprint,
            storedAccountID: storedID, selectionSource: source,
            isActive: true, isLive: source == .liveSystem, canReauthenticate: true, canRemove: true)
    }
}
