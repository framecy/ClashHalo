import Foundation

// 注册全拦截 URLProtocol；测试绝不连接用户内核或访问远程订阅。
final class MockController: URLProtocol {
    static var status = 204
    static var captured: URLRequest?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.captured = request
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

var failures = 0
func expect(_ ok: Bool, _ label: String) {
    if ok { print("✓ \(label)") } else { failures += 1; print("✗ \(label)") }
}
Task { @MainActor in
    // ephemeral session 不继承全局 registerClass，必须在配置中显式注入。
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockController.self]
    let session = URLSession(configuration: config)
    let client = MihomoClient(session: session)
    // 此独立测试程序的 defaults，不是 App 的 preferences。
    client.host = "example.com"
    client.port = 80
    client.secret = ""
    do {
        try await client.updateProvider("订阅/A %2F?#")
        expect(MockController.captured?.httpMethod == "PUT", "实际发送 PUT")
        let path = MockController.captured?.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath } ?? ""
        expect(path.hasSuffix("%2FA%20%252F%3F%23"), "名称中的斜线/百分号/查询/fragment 编为单段")
        expect(MockController.captured?.timeoutInterval == 60, "远端下载使用 60 秒超时")
    } catch { expect(false, "204 必须成功") }
    for code in [401, 404, 500] {
        MockController.status = code
        do {
            try await client.updateProvider("example")
            expect(false, "HTTP \(code) 必须失败")
        } catch { expect(true, "HTTP \(code) 如实失败") }
    }
    exit(failures == 0 ? 0 : 1)
}
dispatchMain()
