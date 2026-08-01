import XCTest
@testable import HatcheryKit

final class ConfigValidationTests: XCTestCase {
    /// A config shaped like a real App Platform tenant.
    private func appPlatformConfig() -> [String: String] {
        [
            "DATABASE_URL": "postgresql://user:pw@host:25061/db",
            "DATABASE_OWNER_URL": "postgresql://owner:pw@host:25061/db",
            "DATABASE_APP_URL": "postgresql://app:pw@host:25061/db",
            "KEYPAIR_JWKS": "{\"keys\":[]}",
            "PRIVATE_KEY_PEM": "-----BEGIN PRIVATE KEY-----",
            "APP_URL": "https://tenant.example.com",
            "APP_ID": "tenant",
            "LOG_LEVEL": "info",
            "DATABASE_LOG_LEVEL": "debug",
            "PAYMENT_GATEWAY_URL": "https://gateway.example.com",
            "PAYMENT_GATEWAY_TOKEN": "token",
            "TEMPORAL_ADDRESS": "temporal.internal:7233",
            "TEMPORAL_NAMESPACE": "tenant",
        ]
    }

    func testCompleteAppPlatformConfigPasses() {
        let contract = EnvContract.mwserver(backend: .appPlatform)
        let issues = ConfigValidator.validate(appPlatformConfig(), against: contract)
        XCTAssertTrue(ConfigValidator.passes(issues), "unexpected issues: \(issues)")
    }

    func testMissingDatabaseURLIsAnError() {
        var config = appPlatformConfig()
        config.removeValue(forKey: "DATABASE_URL")

        let issues = ConfigValidator.validate(config, against: .mwserver(backend: .appPlatform))

        XCTAssertFalse(ConfigValidator.passes(issues))
        XCTAssertTrue(issues.contains { $0.key == "DATABASE_URL" && $0.severity == .error })
    }

    func testEmptyRequiredValueIsAnError() {
        var config = appPlatformConfig()
        config["APP_ID"] = "   "

        let issues = ConfigValidator.validate(config, against: .mwserver(backend: .appPlatform))

        XCTAssertFalse(ConfigValidator.passes(issues))
        XCTAssertTrue(issues.contains { $0.key == "APP_ID" && $0.message.contains("empty") })
    }

    /// The 2026-07-28 cutover: discrete keys are a latent boot failure on App Platform.
    func testRetiredDiscreteKeysAreErrorsOnAppPlatform() {
        var config = appPlatformConfig()
        config["DATABASE_HOST"] = "mwstack-pg-dev"
        config["DATABASE_PORT"] = "5432"

        let issues = ConfigValidator.validate(config, against: .mwserver(backend: .appPlatform))

        XCTAssertFalse(ConfigValidator.passes(issues))
        XCTAssertTrue(issues.contains { $0.key == "DATABASE_HOST" && $0.severity == .error })
        XCTAssertTrue(issues.contains { $0.key == "DATABASE_PORT" && $0.severity == .error })
    }

    /// The lab still runs pre-cutover images, so the same keys are legal there.
    func testDiscreteKeysAreAllowedOnDokku() {
        var config = appPlatformConfig()
        config.removeValue(forKey: "DATABASE_OWNER_URL")
        config["DATABASE_HOST"] = "mwstack-pg-dev"
        config["DATABASE_PORT"] = "5432"

        let issues = ConfigValidator.validate(config, against: .mwserver(backend: .dokku))

        XCTAssertTrue(ConfigValidator.passes(issues), "unexpected issues: \(issues)")
    }

    /// `DatabaseURL.owner` falls back to `DATABASE_URL` where no owner pool exists,
    /// so its absence is legal and must not read as a boot failure.
    func testMissingOwnerURLIsNotAnError() {
        var config = appPlatformConfig()
        config.removeValue(forKey: "DATABASE_OWNER_URL")

        let issues = ConfigValidator.validate(config, against: .mwserver(backend: .appPlatform))

        XCTAssertTrue(ConfigValidator.passes(issues), "unexpected issues: \(issues)")
    }

    /// `EnvironmentKeys.get` traps on these, so a tenant without them never boots.
    func testMissingTemporalKeysAreErrors() {
        var config = appPlatformConfig()
        config.removeValue(forKey: "TEMPORAL_ADDRESS")
        config.removeValue(forKey: "TEMPORAL_NAMESPACE")

        let issues = ConfigValidator.validate(config, against: .mwserver(backend: .appPlatform))

        XCTAssertFalse(ConfigValidator.passes(issues))
        XCTAssertTrue(issues.contains { $0.key == "TEMPORAL_ADDRESS" && $0.severity == .error })
        XCTAssertTrue(issues.contains { $0.key == "TEMPORAL_NAMESPACE" && $0.severity == .error })
    }

    /// The tuning and GSX keys are real keys the server reads. Reporting them as undeclared
    /// would train an operator to ignore the warnings.
    func testRecognisedOptionalKeysDoNotWarn() {
        var config = appPlatformConfig()
        for key in [
            "DATABASE_MAX_CONNECTIONS", "DATABASE_FLUENT_PER_LOOP", "DATABASE_PGCLIENT_MAX",
            "DATABASE_INFRA_MAX", "DATABASE_COMMAND_MAX_CONNECTIONS", "DATABASE_SSL_CERT_PATH",
            "NOISE_GATE_VALUE", "MAIL_OUTBOUND_DISCARD",
            "GSX_GATEWAY_HOST", "GSX_GATEWAY_PORT", "GSX_GATEWAY_TOKEN",
        ] {
            config[key] = "value"
        }

        let issues = ConfigValidator.validate(config, against: .mwserver(backend: .appPlatform))

        XCTAssertTrue(issues.isEmpty, "unexpected issues: \(issues)")
    }

    func testUndeclaredKeyIsAWarningNotAnError() {
        var config = appPlatformConfig()
        config["LEFTOVER_FLAG"] = "true"

        let issues = ConfigValidator.validate(config, against: .mwserver(backend: .appPlatform))

        XCTAssertTrue(ConfigValidator.passes(issues))
        XCTAssertTrue(issues.contains { $0.key == "LEFTOVER_FLAG" && $0.severity == .warning })
    }

    /// GIT_REV is set by dokku on every deploy and is not drift.
    func testDokkuInjectedKeysAreNotReported() {
        var config = appPlatformConfig()
        config["GIT_REV"] = String(repeating: "a", count: 40)

        let issues = ConfigValidator.validate(config, against: .mwserver(backend: .dokku))

        XCTAssertFalse(issues.contains { $0.key == "GIT_REV" })
    }

    func testPaymentGatewayRequiresKeypairJWKS() {
        let issues = ConfigValidator.validate(
            ["APP_URL": "https://paylab.example.com", "GATEWAY_ADMIN_TOKEN": "t", "DATABASE_URL": "postgresql://x"],
            against: .paymentGateway(backend: .appPlatform)
        )

        XCTAssertFalse(ConfigValidator.passes(issues))
        XCTAssertTrue(issues.contains { $0.key == "KEYPAIR_JWKS" && $0.severity == .error })
    }

    func testErrorsSortBeforeWarnings() {
        var config = appPlatformConfig()
        config.removeValue(forKey: "APP_URL")
        config["ZZZ_UNKNOWN"] = "x"

        let issues = ConfigValidator.validate(config, against: .mwserver(backend: .appPlatform))

        XCTAssertEqual(issues.first?.severity, .error)
        XCTAssertEqual(issues.last?.severity, .warning)
    }

    func testRedactionHidesSecretValuesButKeepsShape() {
        let contract = EnvContract.mwserver(backend: .appPlatform)
        let redacted = ConfigValidator.redact(appPlatformConfig(), contract: contract)

        XCTAssertEqual(redacted["APP_ID"], "tenant")
        XCTAssertNotEqual(redacted["PRIVATE_KEY_PEM"], "-----BEGIN PRIVATE KEY-----")
        XCTAssertTrue(redacted["PRIVATE_KEY_PEM"]?.hasPrefix("<redacted") ?? false)
    }
}
