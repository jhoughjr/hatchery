import Foundation
import Testing

@testable import HatcheryKit

@Suite("The Cloud Run declaration and its Cloud SQL socket")
struct CloudSQLSocketTests {
    private func request(settings: [String: String]) -> ScaffoldRequest {
        let stack = StackSpec(
            name: "mwgcp", backend: .cloudRun,
            tofu: TofuBinding(directory: "/infra/gcp"), settings: settings, services: [])
        let service = ServiceSpec(
            name: "mwgcp", kind: .mwserver, image: "x/y:z", configFile: "mwgcp.config.json",
            imageVariable: "mwgcp_image")
        return ScaffoldRequest(stack: stack, service: service, containerPort: 8080)
    }

    @Test("a stack with a Cloud SQL instance mounts it at /cloudsql, and one without does not")
    func mountsTheInstance() throws {
        let with = try CloudRunProvider().declaration(for: request(settings: ["db_cluster": "mws-sql"]))
        let body = try #require(with.first { $0.role == .declaration }?.contents)
        #expect(body.contains("mount_path = \"/cloudsql\""))
        #expect(body.contains("instances = [\"${var.gcp_project}:${var.gcp_region}:mws-sql\"]"))

        let without = try CloudRunProvider().declaration(for: request(settings: [:]))
        let plain = try #require(without.first { $0.role == .declaration }?.contents)
        #expect(!plain.contains("cloudsql"))
    }

    @Test("a socket endpoint makes a socket URL, and an address endpoint keeps TLS")
    func socketURL() {
        let plan = DatabaseClonePlan(
            serverApp: "mws-sql", port: "5432", scheme: "postgresql", database: "mwgcp_mwserver",
            owner: "mwserver", appUser: "mwserver_app",
            emitted: ["DATABASE_URL", "DATABASE_APP_URL"], mode: .none, managed: true)
        let socket = plan.values(
            DatabaseCredentials(
                ownerPassword: "o", appPassword: "a",
                endpoint: DatabaseEndpoint(host: "34.1.2.3", port: "5432", socket: "/cloudsql/mws-lab:us-central1:mws-sql")))
        #expect(socket["DATABASE_URL"] == "postgresql://mwserver:o@/mwgcp_mwserver?host=/cloudsql/mws-lab:us-central1:mws-sql")
        #expect(socket["DATABASE_APP_URL"] == "postgresql://mwserver_app:a@/mwgcp_mwserver?host=/cloudsql/mws-lab:us-central1:mws-sql")

        let address = plan.values(
            DatabaseCredentials(ownerPassword: "o", appPassword: nil, endpoint: DatabaseEndpoint(host: "34.1.2.3", port: "5432")))
        #expect(address["DATABASE_URL"] == "postgresql://mwserver:o@34.1.2.3:5432/mwgcp_mwserver?sslmode=require")
    }
}
