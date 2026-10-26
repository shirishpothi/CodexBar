import AppKit
import Observation
import SwiftUI
import XCTest
@testable import CodexBar
@testable import CodexBarCore

/// Opt-in native interaction proof. It never opens the installed app or a real credential file.
@MainActor
final class CodexAccountNamesNativeProofTests: XCTestCase {
    func test_syntheticRenameAndRelaunch() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["CODEXBAR_ACCOUNT_NAMES_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_ACCOUNT_NAMES_PROOF_DIR for isolated account-name proof")
        }
        guard SettingsStore.isRunningTests,
              environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1",
              environment[CodexCredentialFileAccess.isolationEnvironmentKey] == "1",
              environment["CODEXBAR_TEST_SESSION_FILE_ISOLATION"] == "1",
              environment["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"] != "1",
              environment["CODEXBAR_TEST_CODEX_FILE_FIXTURES"] == nil
        else { return XCTFail("Proof requires isolated credentials, sessions, defaults, and a standalone test host") }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let relaunch = environment["CODEXBAR_ACCOUNT_NAMES_PROOF_RELAUNCH"] == "1"
        let model = try AccountNamesProofModel(directory: output, relaunch: relaunch)
        let app = NSApplication.shared
        guard app.delegate == nil else { return XCTFail("Use a standalone native test host") }
        let previousPolicy = app.activationPolicy()
        let previousApp = NSWorkspace.shared.frontmostApplication
        _ = app.setActivationPolicy(.regular)
        app.finishLaunching()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1060, height: 740),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "CodexBar account names · Synthetic accounts only"
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = NSHostingView(rootView: AccountNamesProofView(model: model))
        defer {
            window.close()
            model.store.stopSharedSpendDashboardPublication()
            _ = app.setActivationPolicy(previousPolicy)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                previousApp?.activate()
            }
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(700))
        if relaunch {
            XCTAssertEqual(model.names, ["Personal", "School"])
            try self.capture("07-relaunched", window: window, output: output)
        } else {
            XCTAssertEqual(model.names, [nil, nil])
            try self.capture("01-existing-data", window: window, output: output)
            try await self.rename(index: 0, to: "Personal", model: model, window: window, output: output)
            try await self.rename(index: 1, to: "School", model: model, window: window, output: output)
            try self.capture("03-saved", window: window, output: output)
            try await self.rename(index: 1, to: "Personal", model: model, window: window, output: output)
            XCTAssertEqual(Set(model.accounts.map(\.menuDisplayName)).count, 2)
            try self.capture("04-duplicate", window: window, output: output)
            let privacy = try XCTUnwrap(self.elements(window).first {
                $0.accessibilityRole() == .checkBox && self.title($0) == "Hide personal info"
            })
            XCTAssertTrue(privacy.accessibilityPerformPress())
            try await self.waitUntil { model.settings.hidePersonalInfo }
            XCTAssertTrue(model.accounts.allSatisfy { model.card(for: $0)?.providerName == "Codex" })
            XCTAssertFalse(model.privateLabels.values.contains { $0.contains("Personal") })
            try self.capture("05-private", window: window, output: output)
            XCTAssertTrue(privacy.accessibilityPerformPress())
            try await self.waitUntil { !model.settings.hidePersonalInfo }
            try await self.rename(index: 1, to: "", model: model, window: window, output: output)
            XCTAssertEqual(model.names, ["Personal", nil])
            try self.capture("06-cleared", window: window, output: output)
            try await self.rename(index: 1, to: "School", model: model, window: window, output: output)
            XCTAssertEqual(model.names, ["Personal", "School"])
        }
        let receipt: [String: Any] = [
            "syntheticOnly": true,
            "relaunch": relaunch,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "configVersion": model.settings.configSnapshot.version,
            "registryVersion": 3,
            "names": model.names.map { $0 ?? "" },
            "renameCallbacks": model.renameCallbacks,
        ]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent(relaunch ? "relaunch.json" : "interaction.json"))
    }

    private func rename(
        index: Int,
        to name: String,
        model: AccountNamesProofModel,
        window: NSWindow,
        output: URL) async throws
    {
        let buttons = self.elements(window).filter { $0.accessibilityRole() == .button && self.title($0) == "Rename" }
        let button = try XCTUnwrap(buttons.indices.contains(index) ? buttons[index] : nil)
        XCTAssertTrue(button.accessibilityPerformPress())
        try await self.waitUntil { window.attachedSheet != nil }
        let sheet = try XCTUnwrap(window.attachedSheet)
        if model.renameCallbacks == 0 {
            try self.capture("02-rename-dialog", window: sheet, output: output)
        }
        let field = try XCTUnwrap(self.elements(sheet).first { $0.accessibilityRole() == .textField })
        field.setAccessibilityValue(name)
        if let textField = field as? NSTextField {
            textField.delegate?.controlTextDidChange?(Notification(
                name: NSControl.textDidChangeNotification,
                object: textField))
        }
        let save = try XCTUnwrap(self.elements(sheet)
            .first { $0.accessibilityRole() == .button && self.title($0) == "Save" })
        let before = model.renameCallbacks
        XCTAssertTrue(save.accessibilityPerformPress())
        try await self.waitUntil { model.renameCallbacks == before + 1 && window.attachedSheet == nil }
        XCTAssertEqual(model.names[index], name.isEmpty ? nil : name)
        try await Task.sleep(for: .milliseconds(150))
    }

    private func title(_ element: any NSAccessibilityProtocol) -> String? {
        element.accessibilityLabel() ?? element.accessibilityTitle()
    }

    private func elements(_ root: Any, depth: Int = 0) -> [any NSAccessibilityProtocol] {
        guard depth < 25, let element = root as? any NSAccessibilityProtocol else { return [] }
        return [element] + (element.accessibilityChildren() ?? []).flatMap { self.elements($0, depth: depth + 1) }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw NSError(
            domain: "AccountNamesProof",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "UI action timed out"])
    }

    private func capture(_ name: String, window: NSWindow, output: URL) throws {
        window.layoutIfNeeded()
        window.displayIfNeeded()
        // Capture this process's own view pixels only. No desktop capture or Screen Recording permission.
        let view = try XCTUnwrap(window.contentView)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: output.appendingPathComponent(name + ".png"))
    }
}

@MainActor
@Observable
private final class AccountNamesProofModel {
    let settings: SettingsStore
    let store: UsageStore
    let original: [CodexVisibleAccount]
    var renameCallbacks = 0

    init(directory: URL, relaunch: Bool) throws {
        let configURL = directory.appendingPathComponent("synthetic-config.json")
        let accountURL = directory.appendingPathComponent("synthetic-accounts.json")
        if !relaunch {
            try Data(#"{"version":1,"providers":[{"id":"codex","enabled":false}]}"#.utf8).write(to: configURL)
            let accounts = (0..<2).map { index in
                ManagedCodexAccount(
                    id: UUID(uuidString: index == 0 ? "11111111-1111-1111-1111-111111111111" :
                        "22222222-2222-2222-2222-222222222222")!,
                    email: index == 0 ? "personal@example.invalid" : "school@example.invalid",
                    workspaceLabel: "Example Workspace",
                    workspaceAccountID: "example-workspace",
                    managedHomePath: directory.appendingPathComponent("unused-\(index)").path,
                    createdAt: 1,
                    updatedAt: 2,
                    lastAuthenticatedAt: 2)
            }
            try JSONEncoder().encode(ManagedCodexAccountSet(version: 3, accounts: accounts)).write(to: accountURL)
        }
        let accounts = try FileManagedCodexAccountStore(fileURL: accountURL).loadAccountMetadata().accounts
        self.original = accounts.enumerated().map { index, account in
            CodexVisibleAccount(
                id: account.email,
                email: account.email,
                workspaceLabel: account.workspaceLabel,
                workspaceAccountID: account.workspaceAccountID,
                authFingerprint: String(repeating: "a", count: 64),
                storedAccountID: account.id,
                selectionSource: .managedAccount(id: account.id),
                isActive: index == 0,
                isLive: false,
                canReauthenticate: true,
                canRemove: true)
        }
        let settings = SettingsStore(
            userDefaults: InMemoryUserDefaults(),
            configStore: CodexBarConfigStore(fileURL: configURL),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            codexCookieStore: InMemoryCookieHeaderStore(),
            claudeCookieStore: InMemoryCookieHeaderStore(),
            cursorCookieStore: InMemoryCookieHeaderStore(),
            opencodeCookieStore: InMemoryCookieHeaderStore(),
            factoryCookieStore: InMemoryCookieHeaderStore(),
            minimaxCookieStore: InMemoryMiniMaxCookieStore(),
            minimaxAPITokenStore: InMemoryMiniMaxAPITokenStore(),
            kimiTokenStore: InMemoryKimiTokenStore(),
            augmentCookieStore: InMemoryCookieHeaderStore(),
            ampCookieStore: InMemoryCookieHeaderStore(),
            copilotTokenStore: InMemoryCopilotTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore())
        self.settings = settings
        settings.costUsageEnabled = false
        settings.paceVisible = false
        self.store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        self.store._test_providerRefreshOverride = { _ in }
    }

    var accounts: [CodexVisibleAccount] {
        CodexVisibleAccountProjection(
            visibleAccounts: self.original,
            activeVisibleAccountID: self.original[0].id,
            liveVisibleAccountID: nil,
            hasUnreadableAddedAccountStore: false)
            .applyingCustomNames(self.settings.codexAccountNames).visibleAccounts
    }

    var names: [String?] {
        self.accounts.map(\.customName)
    }

    var privateLabels: [String: String] {
        CodexAccountSwitcherLabeling.labels(for: self.accounts, hidePersonalInfo: true)
    }

    func card(for account: CodexVisibleAccount) -> UsageMenuCardView.Model? {
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 20,
                windowMinutes: 300,
                resetsAt: Date().addingTimeInterval(7200),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 10,
                windowMinutes: 10080,
                resetsAt: Date().addingTimeInterval(432_000),
                resetDescription: nil),
            updatedAt: Date())
        return self.store.codexAccountMenuCardModel(for: account, accountSnapshot: CodexAccountUsageSnapshot(
            account: account,
            snapshot: snapshot,
            error: nil,
            sourceLabel: "synthetic"))
    }
}

@MainActor
private struct AccountNamesProofView: View {
    @Bindable var model: AccountNamesProofModel

    var body: some View {
        @Bindable var settings = self.model.settings
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Account naming · Synthetic data").font(.title2.bold())
                Form {
                    CodexAccountsSectionView(
                        state: CodexAccountsSectionState(
                            visibleAccounts: self.model.accounts,
                            activeVisibleAccountID: self.model.accounts[0].id,
                            liveVisibleAccountID: nil,
                            hasUnreadableManagedAccountStore: false,
                            isAuthenticatingManagedAccount: false,
                            authenticatingManagedAccountID: nil,
                            isRemovingManagedAccount: false,
                            isAuthenticatingLiveAccount: false,
                            isPromotingSystemAccount: false,
                            notice: nil),
                        setActiveVisibleAccount: { _ in },
                        reauthenticateAccount: { _ in },
                        removeAccount: { _ in },
                        requestSystemVisibleAccount: { _ in },
                        addAccount: {},
                        renameAccount: { account, name in
                            self.model.settings.renameCodexAccount(account, to: name)
                            self.model.renameCallbacks += 1
                        })
                }
                .formStyle(.grouped)
                Toggle("Hide personal info", isOn: $settings.hidePersonalInfo)
                    .toggleStyle(.checkbox)
                Text("Production Settings and menu-card views. No real accounts or credentials.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 630)
            VStack(spacing: 12) {
                AccountNamesProofSwitcher(accounts: self.model.accounts, hidePersonalInfo: settings.hidePersonalInfo)
                    .frame(width: 350, height: 28)
                ForEach(self.model.accounts) { account in
                    if let card = self.model.card(for: account) {
                        UsageMenuCardView(model: card, width: 350)
                    }
                }
            }
            .frame(width: 350)
        }
        .padding(24)
        .frame(width: 1060, height: 740, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

@MainActor
private struct AccountNamesProofSwitcher: NSViewRepresentable {
    let accounts: [CodexVisibleAccount]
    let hidePersonalInfo: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.subviews.forEach { $0.removeFromSuperview() }
        let switcher = CodexAccountSwitcherView(
            accounts: self.accounts,
            selectedAccountID: self.accounts[0].id,
            width: 350,
            hidePersonalInfo: self.hidePersonalInfo,
            onSelect: { _ in })
        switcher.frame = nsView.bounds
        switcher.autoresizingMask = [.width, .height]
        nsView.addSubview(switcher)
    }
}
