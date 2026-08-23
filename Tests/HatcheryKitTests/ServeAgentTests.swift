import Foundation
import Testing

@testable import HatcheryKit

@Suite("The agent that keeps serve running")
struct ServeAgentTests {
    @Test("the launchd plist spells out every argument and keeps the server alive")
    func plistShape() {
        let plist = ServeAgent.plist(
            binary: "/usr/local/bin/hatchery", manifest: "/infra/hatchery.json",
            bind: "192.168.0.162", port: 7878, token: "s3cret", home: "/Users/op")
        #expect(plist.contains("<string>net.jimmyhoughjr.hatchery-serve</string>"))
        for argument in ["/usr/local/bin/hatchery", "serve", "--manifest", "/infra/hatchery.json",
                         "--bind", "192.168.0.162", "--port", "7878", "--token", "s3cret"] {
            #expect(plist.contains("<string>\(argument)</string>"))
        }
        #expect(plist.contains("<key>KeepAlive</key>"))
        #expect(plist.contains("<key>RunAtLoad</key>"))
        #expect(plist.contains("/Users/op/Library/Logs/hatchery-serve.log"))

        let local = ServeAgent.plist(
            binary: "/b", manifest: "/m", bind: "127.0.0.1", port: 7878, token: nil, home: "/h")
        #expect(!local.contains("--token"))
    }

    @Test("the systemd unit restarts always and quotes what needs quoting")
    func unitShape() {
        let unit = ServeAgent.unit(
            binary: "/opt/hatchery/bin/hatchery", manifest: "/infra state/hatchery.json",
            bind: "0.0.0.0", port: 7878, token: nil)
        #expect(unit.contains("ExecStart=/opt/hatchery/bin/hatchery serve --manifest \"/infra state/hatchery.json\" --bind 0.0.0.0 --port 7878"))
        #expect(unit.contains("Restart=always"))
        #expect(unit.contains("WantedBy=default.target"))
        #expect(!unit.contains("--token"))
        #expect(ServeAgent.unitPath(home: "/home/op") == "/home/op/.config/systemd/user/hatchery-serve.service")
    }

    @Test("an XML-hostile value is escaped rather than trusted")
    func escaping() {
        let plist = ServeAgent.plist(
            binary: "/b", manifest: "/m", bind: "127.0.0.1", port: 7878,
            token: "a<b&c", home: "/h")
        #expect(plist.contains("<string>a&lt;b&amp;c</string>"))
    }
}
