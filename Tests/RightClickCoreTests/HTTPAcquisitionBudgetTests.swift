import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import RightClickProtocol
@testable import RightClickProviders

final class HTTPAcquisitionBudgetTests: XCTestCase {
    func testDelayedLargeHostSpecificationUsesSeparateFiniteBudgetWithoutExpandingOrdinaryExchange() throws {
        let directory = NativeHTTPFixture.temporaryDirectory.appendingPathComponent("rightclick-http-budget-" + UUID().uuidString)
        try NativeHTTPFixture.createPrivateDirectory(directory)
        defer { try? NativeHTTPFixture.remove(directory) }
        let bodyFile = directory.appendingPathComponent("body.json")
        let marker = directory.appendingPathComponent("port")
        let requestCountFile = directory.appendingPathComponent("request-count")
        let script = directory.appendingPathComponent("server.py")
        var body = Data("{\"openapi\":\"3.1.0\",\"paths\":{}}".utf8)
        body.append(Data(repeating: 32, count: 12_901_084 - body.count))
        try NativeHTTPFixture.writePrivate(body, to: bodyFile)
        let source = """
        import http.server,pathlib,sys,threading,time
        payload=pathlib.Path(sys.argv[1]).read_bytes()
        count_file=pathlib.Path(sys.argv[3])
        count_lock=threading.Lock()
        request_count=0
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self,*args): pass
            def do_GET(self):
                global request_count
                with count_lock:
                    request_count+=1
                    temporary_count=count_file.with_suffix('.tmp')
                    temporary_count.write_text(str(request_count))
                    temporary_count.replace(count_file)
                self.send_response(200)
                self.send_header('Content-Type','application/json')
                self.send_header('Content-Length',str(len(payload)))
                self.end_headers()
                time.sleep(6)
                try: self.wfile.write(payload)
                except (BrokenPipeError,ConnectionResetError): pass
        server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
        server.daemon_threads=True
        marker=pathlib.Path(sys.argv[2])
        temporary=marker.with_suffix('.tmp')
        temporary.write_text(str(server.server_address[1]))
        temporary.replace(marker)
        server.serve_forever()
        """
        try NativeHTTPFixture.writePrivate(Data(source.utf8), to: script)
        let process = Process()
        process.executableURL = try NativeHTTPFixture.python()
        process.arguments = ["-I", "-S", script.path, bodyFile.path, marker.path, requestCountFile.path]
        process.standardOutput = FileHandle.nullDevice
        try NativeHTTPFixture.runFixture(process)
        defer {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
        }
        let port = try NativeHTTPFixture.waitForPort(marker, process: process)
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/specification"))
        var outcomes: [Bool] = []
        for index in 0..<3 {
            let began = ProcessInfo.processInfo.systemUptime
            var completed = false, deadlineObserved = false
            do {
                let received = index == 1 ? try OriginPinnedHTTP.loadOpenAPISpecification(url) :
                    try OriginPinnedHTTP.loadOpenAPISpecification(url, deadline: 5)
                completed = true
                XCTAssertEqual(received.count, body.count)
                XCTAssertTrue(received == body)
            } catch {
                let native = error as NSError
                deadlineObserved = (native.domain == NSURLErrorDomain && native.code == NSURLErrorTimedOut) ||
                    error.localizedDescription == "HTTP provider document acquisition exceeded the deadline."
                XCTAssertTrue(deadlineObserved)
            }
            XCTAssertEqual(completed, index == 1)
            XCTAssertEqual(deadlineObserved, index != 1)
            outcomes.append(completed)
            let elapsed = ProcessInfo.processInfo.systemUptime - began
            XCTAssertGreaterThanOrEqual(elapsed, index == 1 ? 6 : 4.5)
            XCTAssertLessThan(elapsed, index == 1 ? 30 : 7)
            let unchangedBody = try Data(contentsOf: bodyFile) == body
            XCTAssertTrue(unchangedBody)
            print("HTTPAcquisitionBudget profile=\(index == 1 ? "hostSpecification" : (index == 0 ? "boundedBefore" : "boundedAfter")) outcome=\(completed ? "completed" : (deadlineObserved ? "deadlineExceeded" : "unexpectedFailure")) elapsedMilliseconds=\(elapsed * 1000) bytes=\(body.count) unchangedBody=\(unchangedBody)")
        }
        XCTAssertEqual(outcomes, [false, true, false])
        let requestCount = try String(contentsOf: requestCountFile, encoding: .utf8)
        XCTAssertEqual(requestCount, "3")
        print("HTTPAcquisitionBudget actualRequestCount=\(requestCount) expectedRequestCount=3")
        var admitted = false
        XCTAssertThrowsError(try OriginPinnedHTTP.exchange(URLRequest(url: url), deadline: 10.001,
            admitStart: { enqueue in admitted = true; enqueue() })) { error in
            XCTAssertEqual(error as? RCIRError, .invalidLimit)
        }
        XCTAssertFalse(admitted)
        for invalid in [0, -1, 30.001, .infinity, .nan] as [TimeInterval] {
            XCTAssertThrowsError(try OriginPinnedHTTP.loadOpenAPISpecification(url, deadline: invalid)) { error in
                XCTAssertEqual(error as? RCIRError, .invalidLimit)
            }
        }
    }
}
