import Foundation
import Testing

@testable import HatcheryKit

private func manifest(_ json: String) throws -> StackManifest {
    try StackManifest.decode(from: Data(json.utf8))
}

private let estate = """
    {"version": 1, "stacks": [
      {"name": "box", "backend": "host", "host": "jimmy@opi", "settings": {"platform": "linux"}, "services": [
        {"name": "roost-node-report", "kind": "job", "image": "", "domains": [], "configFile": "r.config.json",
         "job": {"program": ["/home/jimmy/roost/bin/node-report.sh"], "keepAlive": false, "runAtLoad": true}}]},
      {"name": "mini", "backend": "host", "host": "j@mini", "settings": {"platform": "darwin"}, "services": [
        {"name": "roost-node-report", "kind": "job", "image": "", "domains": [], "configFile": "r.config.json",
         "job": {"program": ["/Users/j/repos/roost/bin/node-report.sh"], "keepAlive": false, "runAtLoad": true}}]},
      {"name": "estate", "backend": "dokku", "host": "dokku@opi", "services": []}
    ]}
    """

@Suite("The boxes that vote")
struct BoxVotersTests {
    @Test("enrolling a box declares the watcher from its roost checkout and names it, and a second box becomes its peer")
    func enrol() throws {
        var m = try manifest(estate)
        try BoxVoters.enrol(stack: "box", as: "opi", address: "opi.example:9211", in: &m)
        try BoxVoters.enrol(stack: "mini", as: "mini", address: "mini.example:9211", in: &m)

        let voters = BoxVoters.voters(in: [m])
        #expect(voters.map(\.name) == ["opi", "mini"])
        let box = try #require(m.stacks.first { $0.name == "box" }?.services.first { $0.name == "box-watch" })
        #expect(box.job?.program == ["/home/jimmy/roost/bin/box-watch.py"])
        #expect(box.job?.keepAlive == true)
        let mini = try #require(m.stacks.first { $0.name == "mini" }?.services.first { $0.name == "box-watch" })
        #expect(mini.job?.program == ["/Users/j/repos/roost/bin/box-watch.py"])
        #expect(mini.job?.log == "/Users/j/Library/Logs/box-watch.log")
        #expect(BoxVoters.peersLine(for: voters[0], among: voters) == "mini=mini.example:9211")
        #expect(BoxVoters.peersLine(for: voters[1], among: voters) == "opi=opi.example:9211")
    }

    @Test("enrolling twice keeps one job and takes the new address, and a config keeps what a person set")
    func enrolTwice() throws {
        var m = try manifest(estate)
        try BoxVoters.enrol(stack: "box", as: "opi", address: "old:9211", in: &m)
        try BoxVoters.enrol(stack: "box", as: "opi", address: "new:9211", in: &m)
        #expect(m.stacks[0].services.filter { $0.name == "box-watch" }.count == 1)
        let voters = BoxVoters.voters(in: [m])
        #expect(voters == [BoxVoters.Voter(stack: "box", name: "opi", address: "new:9211")])
        let config = BoxVoters.config(for: voters[0], among: voters, existing: ["BOX_WATCH_MESH": "/x", "BOX_WATCH_STACKS": "box,estate"])
        #expect(config["BOX_WATCH_MESH"] == "/x")
        #expect(config["BOX_WATCH_STACKS"] == "box,estate")
        #expect(config["BOX_WATCH_PEERS"] == "")
        #expect(config["BOX_WATCH_INTERVAL"] == "30")
    }

    @Test("removing a box takes it out of the vote and out of every peers line")
    func remove() throws {
        var m = try manifest(estate)
        try BoxVoters.enrol(stack: "box", as: "opi", address: "opi.example:9211", in: &m)
        try BoxVoters.enrol(stack: "mini", as: "mini", address: "mini.example:9211", in: &m)
        try BoxVoters.remove(stack: "mini", from: &m)

        let voters = BoxVoters.voters(in: [m])
        #expect(voters.map(\.name) == ["opi"])
        #expect(BoxVoters.peersLine(for: voters[0], among: voters) == "")
        #expect(m.stacks[1].services.contains { $0.name == "box-watch" } == false)
        #expect(throws: BoxVoters.Failure.notAVoter("mini")) { try BoxVoters.remove(stack: "mini", from: &m) }
    }

    @Test("only a box votes, and a box with no roost checkout is refused in words")
    func refusals() throws {
        var m = try manifest(estate)
        #expect(throws: BoxVoters.Failure.notAHost("estate")) { try BoxVoters.enrol(stack: "estate", as: "e", address: "e:1", in: &m) }
        #expect(throws: BoxVoters.Failure.noStack("ghost")) { try BoxVoters.enrol(stack: "ghost", as: "g", address: "g:1", in: &m) }
    }
}
