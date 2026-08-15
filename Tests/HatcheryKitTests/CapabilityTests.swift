import Foundation
import Testing

@testable import HatcheryKit

/// A capability is what a service does, as opposed to what it is.
///
/// The point of these is the refusal. A kind that never opted in must still reject the keys, because a contract that recognises everything catches no typos, which is the only reason it refuses a key at all.
@Suite("A capability adds keys a kind opts into")
struct CapabilityTests {
    @Test("MWServer opted into vault, so it recognises the keys")
    func mwserverTakesTheVaultKeys() {
        let contract = EnvContract.mwserver(backend: .dokku)
        #expect(contract.unknownKeys(in: ["VAULT_BASE_URL": "https://vault.example.net"]).isEmpty)
        #expect(contract.unknownKeys(in: ["VAULT_APP": "mwserver"]).isEmpty)
        #expect(contract.unknownKeys(in: ["VAULT_APP_KEY": "sk_live_x"]).isEmpty)
    }

    @Test("the app key is a secret, so nothing prints it")
    func appKeyIsSecret() {
        #expect(EnvContract.mwserver(backend: .dokku).secret.contains("VAULT_APP_KEY"))
        // The other two name a server and an app, and neither is worth hiding.
        #expect(!EnvContract.mwserver(backend: .dokku).secret.contains("VAULT_BASE_URL"))
    }

    @Test("every vault key is optional, because a service that stores nothing still boots")
    func vaultIsNeverRequired() {
        let contract = EnvContract.mwserver(backend: .dokku)
        for key in EnvContract.Capability.vault.optional {
            #expect(!contract.required.contains(key))
            #expect(contract.optional.contains(key))
        }
    }

    @Test("a kind that never opted in refuses the keys")
    func othersStillRefuse() {
        // This is the half worth holding. Adding the keys to one kind must not hand them to every kind.
        let gateway = EnvContract.paymentGateway(backend: .dokku)
        #expect(!gateway.unknownKeys(in: ["VAULT_APP_KEY": "sk_live_x"]).isEmpty)
        let communications = EnvContract.communicationGateway(backend: .dokku)
        #expect(!communications.unknownKeys(in: ["VAULT_BASE_URL": "https://vault.example.net"]).isEmpty)
    }

    @Test("opting in twice changes nothing, so a contract can be composed without care")
    func optingInIsRepeatable() {
        let once = EnvContract.mwserver(backend: .dokku)
        #expect(once.uses(.vault) == once)
    }

    @Test("a capability leaves the rest of a contract alone")
    func nothingElseMoves() {
        let plain = EnvContract(required: ["A"], optional: ["B"], secret: ["C"],
                                retired: ["D"], ignored: ["E"], ignoredPrefixes: ["F_"])
        let withVault = plain.uses(.vault)
        #expect(withVault.required == ["A"])
        #expect(withVault.retired == ["D"])
        #expect(withVault.ignored == ["E"])
        #expect(withVault.ignoredPrefixes == ["F_"])
        #expect(withVault.optional.contains("B"))
    }
}
