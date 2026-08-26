// Unit tests for the peer-list presentation rules.
//
// These exist because the rules were wrong the first time and only a run against a real
// tailnet revealed it: `HostName` came back as "localhost" for three peers and was
// duplicated across two more, so a list keyed on it showed "localhost" three times.
// The fixture below is trimmed from an actual /localapi/v0/status response.
//
// Run via:
//   xcodebuild test -project app/Tunnelless.xcodeproj \
//     -scheme Tunnelless-iOS -destination 'platform=iOS Simulator,name=iPhone 16 Plus,OS=latest'

import TailscaleKit
@testable import Tunnelless_iOS
import XCTest

final class TailnetPeerTests: XCTestCase {
    /// Shape and field names match tsnet's LocalAPI; decoding through
    /// `IpnState.Status` is itself part of what this asserts.
    private let fixture = """
    {
      "Version": "1.102.3",
      "BackendState": "Running",
      "AuthURL": "",
      "CurrentTailnet": {
        "Name": "example@gmail.com",
        "MagicDNSSuffix": "tail1234.ts.net",
        "MagicDNSEnabled": true
      },
      "Peer": {
        "k1": {
          "ID": "1", "HostName": "localhost", "DNSName": "pixel-8a.tail1234.ts.net.",
          "TailscaleIPs": ["100.103.164.60"], "Online": false,
          "ExitNode": false, "ExitNodeOption": false
        },
        "k2": {
          "ID": "2", "HostName": "Mac's MacBook Pro", "DNSName": "macs-macbook-pro.tail1234.ts.net.",
          "TailscaleIPs": ["100.73.22.58"], "Online": true, "Relay": "sfo",
          "ExitNode": false, "ExitNodeOption": true
        },
        "k3": {
          "ID": "3", "HostName": "aardvark", "DNSName": "aardvark.tail1234.ts.net.",
          "TailscaleIPs": ["100.1.2.3"], "Online": false, "CurAddr": "10.0.0.5:41641",
          "ExitNode": false, "ExitNodeOption": false, "Expired": true,
          "Tags": ["tag:server"]
        }
      }
    }
    """.data(using: .utf8)!

    private func rows() throws -> [TailnetPeer] {
        try JSONDecoder().decode(IpnState.Status.self, from: fixture).peerRows()
    }

    func testDecodesLocalAPIStatus() throws {
        let status = try JSONDecoder().decode(IpnState.Status.self, from: fixture)
        XCTAssertEqual(status.BackendState, "Running")
        XCTAssertEqual(status.CurrentTailnet?.MagicDNSSuffix, "tail1234.ts.net")
        XCTAssertEqual(status.Peer?.count, 3)
    }

    func testOnlinePeersSortFirst() throws {
        let flags = try rows().map(\.online)
        XCTAssertEqual(flags, [true, false, false], "online peers must lead the list")
    }

    func testOfflinePeersSortAlphabeticallyByDisplayName() throws {
        let offline = try rows().filter { !$0.online }.map(\.displayName)
        XCTAssertEqual(offline, ["aardvark", "pixel-8a"])
    }

    func testDisplayNamePrefersMagicDNSAndTrimsSuffix() throws {
        let peer = try XCTUnwrap(rows().first { $0.id == "1" })
        // HostName is "localhost" here — useless as a label, and not unique.
        XCTAssertEqual(peer.displayName, "pixel-8a")
        XCTAssertNil(peer.subtitle, "a 'localhost' HostName adds nothing and must be hidden")
    }

    func testSubtitleShownOnlyWhenItAddsInformation() throws {
        let mac = try XCTUnwrap(rows().first { $0.id == "2" })
        XCTAssertEqual(mac.displayName, "macs-macbook-pro")
        XCTAssertEqual(mac.subtitle, "Mac's MacBook Pro")

        let aardvark = try XCTUnwrap(rows().first { $0.id == "3" })
        XCTAssertEqual(aardvark.displayName, "aardvark")
        XCTAssertNil(aardvark.subtitle, "subtitle repeating the title must be hidden")
    }

    func testRouteReportsDirectVersusRelay() throws {
        // CurAddr set ⇒ a direct path exists, regardless of Relay.
        XCTAssertEqual(try XCTUnwrap(rows().first { $0.id == "3" }).route, "direct")
        // No CurAddr but a Relay region ⇒ traffic goes via DERP.
        XCTAssertEqual(try XCTUnwrap(rows().first { $0.id == "2" }).route, "relay sfo")
        // Neither ⇒ no active path, and the badge is omitted rather than guessed at.
        XCTAssertNil(try XCTUnwrap(rows().first { $0.id == "1" }).route)
    }

    func testIPv4Selected() throws {
        XCTAssertEqual(try XCTUnwrap(rows().first { $0.id == "2" }).ipv4, "100.73.22.58")
    }

    func testFlagsAndTagsCarryThrough() throws {
        let aardvark = try XCTUnwrap(rows().first { $0.id == "3" })
        XCTAssertTrue(aardvark.expired)
        XCTAssertEqual(aardvark.tags, ["tag:server"])

        let mac = try XCTUnwrap(rows().first { $0.id == "2" })
        XCTAssertTrue(mac.offersExitNode)
        XCTAssertFalse(mac.isExitNode, "offering an exit node is not the same as being the one in use")
    }
}
