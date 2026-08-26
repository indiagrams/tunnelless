// Unit tests for HTTP parsing and the reader's rendering rules.
//
// This is where a saved service degrades *silently* rather than visibly. A mis-split
// header/body boundary, or a wrong content-type branch, produces a reader full of raw
// markup or an empty pane — not an error, and not something a status code would reveal.
// The device probe proves bytes traverse the tunnel; these prove what happens after.

@testable import Tunnelless_iOS
import XCTest

final class ServiceRenderingTests: XCTestCase {
    private func raw(_ s: String) -> Data {
        Data(s.utf8)
    }

    // MARK: - Parsing

    func testParsesStatusHeadersAndBody() {
        let r = SOCKS5Client.parse(raw(
            "HTTP/1.0 200 OK\r\nContent-Type: application/json\r\nContent-Length: 9\r\n\r\n{\"a\":1}\r\n"
        ))
        XCTAssertEqual(r.statusCode, 200)
        XCTAssertEqual(r.reason, "OK")
        XCTAssertEqual(r.contentType, "application/json")
        XCTAssertTrue(r.bodyText.contains("{\"a\":1}"))
    }

    /// Header names are case-insensitive per RFC 9110, and real servers vary.
    func testHeaderLookupIsCaseInsensitive() {
        let r = SOCKS5Client.parse(raw("HTTP/1.1 200 OK\r\nCONTENT-TYPE: text/plain\r\n\r\nhi"))
        XCTAssertEqual(r.contentType, "text/plain")
    }

    /// "text/html; charset=utf-8" must match the html branch, not fall through.
    func testContentTypeParametersAreStripped() {
        let r = SOCKS5Client.parse(raw("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<p>x</p>"))
        XCTAssertEqual(r.contentType, "text/html")
    }

    /// A body containing a blank line must not be truncated at the *second* CRLFCRLF.
    func testBodyWithBlankLinesSurvivesIntact() {
        let r = SOCKS5Client.parse(raw("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nline1\r\n\r\nline2"))
        XCTAssertTrue(r.bodyText.contains("line1"))
        XCTAssertTrue(r.bodyText.contains("line2"), "split must use the FIRST boundary only")
    }

    func testNonSuccessStatusIsReported() {
        let r = SOCKS5Client.parse(raw("HTTP/1.1 404 Not Found\r\n\r\nnope"))
        XCTAssertEqual(r.statusCode, 404)
        XCTAssertEqual(r.reason, "Not Found")
    }

    func testHeadersWithoutBody() {
        let r = SOCKS5Client.parse(raw("HTTP/1.1 204 No Content\r\nServer: nginx\r\n\r\n"))
        XCTAssertEqual(r.statusCode, 204)
        XCTAssertTrue(r.body.isEmpty)
        XCTAssertEqual(ResponseRenderer.text(for: r), "(empty response)")
    }

    // MARK: - Rendering

    func testJSONIsPrettyPrinted() throws {
        let r = SOCKS5Client.parse(raw(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"b\":2,\"a\":[1,2]}"
        ))
        let out = ResponseRenderer.text(for: r)
        XCTAssertTrue(out.contains("\n"), "pretty-printed JSON should span lines")
        XCTAssertLessThan(
            try XCTUnwrap(out.range(of: "\"a\"")?.lowerBound), try XCTUnwrap(out.range(of: "\"b\"")?.lowerBound),
            "keys are sorted so repeat fetches are diffable by eye"
        )
    }

    /// A lot of self-hosted endpoints send octet-stream for JSON. Falling back to a
    /// byte count there would make a working service look unreadable.
    func testJSONDetectedDespiteWrongContentType() {
        let r = SOCKS5Client.parse(raw(
            "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n\r\n{\"ok\":true}"
        ))
        XCTAssertTrue(ResponseRenderer.text(for: r).contains("\"ok\""))
    }

    func testHTMLIsReducedToText() {
        let r = SOCKS5Client.parse(raw(
            "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n"
                + "<html><head><style>.x{color:red}</style></head>"
                + "<body><h1>Storage</h1><p>Pool <b>tank</b> is healthy.</p>"
                + "<script>var a=1;</script></body></html>"
        ))
        let out = ResponseRenderer.text(for: r)
        XCTAssertTrue(out.contains("Storage"))
        XCTAssertTrue(out.contains("tank"))
        XCTAssertFalse(out.contains("var a=1"), "script contents must be dropped, not shown")
        XCTAssertFalse(out.contains("color:red"), "style contents must be dropped")
        XCTAssertFalse(out.contains("<"), "no markup should survive")
    }

    func testHTMLEntitiesAreDecoded() {
        let r = SOCKS5Client.parse(raw(
            "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<p>disk &gt; 80&#39;s &amp; rising</p>"
        ))
        let out = ResponseRenderer.text(for: r)
        XCTAssertTrue(out.contains("disk > 80's & rising"), "got: \(out)")
    }

    func testPlainTextPassesThrough() {
        let r = SOCKS5Client.parse(raw("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nall good"))
        XCTAssertEqual(ResponseRenderer.text(for: r), "all good")
    }

    func testMarkupOnlyHTMLSaysSoRatherThanShowingBlank() {
        let r = SOCKS5Client.parse(raw("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<div><span></span></div>"))
        XCTAssertEqual(ResponseRenderer.text(for: r), "(no readable text in this HTML)")
    }

    // MARK: - Saved services

    func testDisplayURLOmitsThePortWhenItIsEighty() {
        XCTAssertEqual(SavedService(name: "NAS", host: "nas", port: 80).displayURL, "http://nas/")
        XCTAssertEqual(
            SavedService(name: "Grafana", host: "grafana", port: 3000).displayURL,
            "http://grafana:3000/"
        )
    }

    func testPathIsNormalisedToStartWithSlash() {
        XCTAssertEqual(SavedService(name: "x", host: "h", port: 80, path: "api/v1").path, "/api/v1")
    }

    func testSavingTheSameAddressTwiceReplacesRatherThanDuplicates() {
        SavedServiceStore.clear()
        defer { SavedServiceStore.clear() }

        SavedServiceStore.add(SavedService(name: "NAS", host: "nas", port: 80))
        SavedServiceStore.add(SavedService(name: "NAS renamed", host: "nas", port: 80))

        let all = SavedServiceStore.load()
        XCTAssertEqual(all.count, 1, "saving a peer that is already bookmarked must not duplicate it")
        XCTAssertEqual(all.first?.name, "NAS renamed")
    }

    func testDifferentPortsAreDifferentServices() {
        SavedServiceStore.clear()
        defer { SavedServiceStore.clear() }

        SavedServiceStore.add(SavedService(name: "NAS", host: "nas", port: 80))
        SavedServiceStore.add(SavedService(name: "NAS admin", host: "nas", port: 5000))
        XCTAssertEqual(SavedServiceStore.load().count, 2)
    }
}
