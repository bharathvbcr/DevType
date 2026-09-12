import Foundation
import XCTest
import ExpanderEngine
@testable import DevTypeAppCore

@MainActor
final class SecretAccessAuditTests: XCTestCase {
    private final class Authenticator: BiometricAuthenticating {
        var reply: ((BiometricGate.Outcome) -> Void)?
        func availability() -> BiometricGate.Availability { .passwordOnly }
        func evaluate(reason: String, completion: @escaping (BiometricGate.Outcome) -> Void) { reply = completion }
        func invalidate() {}
    }

    private func library(_ secret: SecretModel) throws -> SnippetStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("library.json")
        try JSONEncoder().encode(SnippetDocument(groups: [], secrets: [secret])).write(to: file)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return SnippetStore(fileURL: file)
    }

    func testUnobservedExternalMetadataChangeCannotBeCopied() throws {
        let secret = SecretModel(title: "External change")
        let library = try library(secret)
        XCTAssertEqual(library.loadSecrets(), [secret])
        let values = SecretStore(backing: InMemorySecretBackingStore(seed: [secret.id.uuidString: "synthetic"]))
        try JSONEncoder().encode(SnippetDocument(groups: [])).write(to: library.activeLocationURL, options: .atomic)
        XCTAssertEqual(library.loadSecrets(), [secret], "The watcher has not adopted the external edit")
        var result: Result<String, SecretMenuFlow.ResolveFailure>?
        SecretMenuFlow.resolve(secret.snippetAdapter, secretStore: values, libraryStore: library,
                               preferenceEnabled: false) { result = $0 }
        XCTAssertEqual(result, .failure(.selectionChanged))
    }

    func testDisabledSecretCannotBeResolvedEvenWhenAStaleMenuSendsIt() throws {
        let secret = SecretModel(title: "Disabled", enabled: false)
        let library = try library(secret)
        let values = SecretStore(backing: InMemorySecretBackingStore(seed: [secret.id.uuidString: "synthetic"]))
        var result: Result<String, SecretMenuFlow.ResolveFailure>?
        SecretMenuFlow.resolve(secret.snippetAdapter, secretStore: values, libraryStore: library,
                               preferenceEnabled: false) { result = $0 }
        guard case .failure = result else { return XCTFail("Disabled secrets must never resolve") }
    }

    func testDeletingDisablingOrEditingDuringAuthenticationCannotRevealAStaleSecret() throws {
        for operation in 0..<3 {
            let secret = SecretModel(title: "Selected")
            let library = try library(secret)
            let values = SecretStore(backing: InMemorySecretBackingStore(seed: [secret.id.uuidString: "synthetic"]))
            let auth = Authenticator()
            let gate = BiometricGate(authenticator: auth)
            var result: Result<String, SecretMenuFlow.ResolveFailure>?
            SecretMenuFlow.resolve(secret.snippetAdapter, secretStore: values, libraryStore: library,
                                   gate: gate, preferenceEnabled: true) { result = $0 }
            XCTAssertNotNil(auth.reply)
            XCTAssertNil(result)
            var updated = secret
            if operation == 1 { updated.enabled = false }
            if operation == 2 { updated.title = "Changed" }
            XCTAssertTrue(library.saveGroups(SnippetDocument(groups: [], secrets: operation == 0 ? [] : [updated]).transactionGroups).didSave)
            auth.reply?(.authorized)
            XCTAssertNotNil(result)
            guard case .failure = result else { XCTFail("Operation \(operation) revealed a retired selection"); continue }
        }
    }

    func testARequestedAuthenticationCompletesEvenIfTheGateOwnerIsReleased() throws {
        let secret = SecretModel(title: "Selected")
        let library = try library(secret)
        let values = SecretStore(backing: InMemorySecretBackingStore(seed: [secret.id.uuidString: "synthetic"]))
        let auth = Authenticator()
        var result: Result<String, SecretMenuFlow.ResolveFailure>?
        SecretMenuFlow.resolve(secret.snippetAdapter, secretStore: values, libraryStore: library,
                               gate: BiometricGate(authenticator: auth), preferenceEnabled: true) { result = $0 }
        auth.reply?(.authorized)
        XCTAssertEqual(result, .success("synthetic"))
    }

    func testDuplicateAuthenticationCallbacksDeliverOnlyOneResult() throws {
        let secret = SecretModel(title: "Selected")
        let library = try library(secret)
        let values = SecretStore(backing: InMemorySecretBackingStore(seed: [secret.id.uuidString: "synthetic"]))
        let auth = Authenticator()
        let gate = BiometricGate(authenticator: auth)
        var results: [Result<String, SecretMenuFlow.ResolveFailure>] = []
        SecretMenuFlow.resolve(secret.snippetAdapter, secretStore: values, libraryStore: library,
                               gate: gate, preferenceEnabled: true) { results.append($0) }
        auth.reply?(.authorized)
        auth.reply?(.authorized)
        auth.reply?(.cancelled)
        XCTAssertEqual(results, [.success("synthetic")])
    }
}
