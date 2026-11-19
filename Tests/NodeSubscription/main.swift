import Foundation

// 直接编译生产源码（Sources/Core/Subscription/NodeSubscription.swift +
// Sources/Core/YamlEditor/YamlScalar.swift），不在这里复刻解析规则。
//
// 钉住的现场：`.txt` + `text/plain` + base64 编码的分享链接订阅（vless:// /
// hysteria2:// …）。mihomo 只吃 YAML；旧实现用 `content.contains(":")` 判订阅
// 有效、用 `looksLikeMihomoConfig` 拒订阅刷新，而 base64 字母表不含冒号 ——
// 于是这类订阅连导入这一步都过不去，用户侧看到的就是「始终无法使用」。
//
// 断言只依赖合成 fixture：不联网、不碰开发机的订阅/节点/网卡。

var failures = 0, checks = 0
func expect(_ cond: Bool, _ what: String) {
    checks += 1
    if !cond { failures += 1; print("  ✗ FAIL: \(what)") } else { print("  ✓ \(what)") }
}
func section(_ s: String) { print("\n── \(s) ──") }
func contains(_ haystack: String, _ needle: String) -> Bool { haystack.contains(needle) }

func b64(_ s: String) -> String { Data(s.utf8).base64EncodedString() }
func b64url(_ s: String) -> String {
    b64(s).replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

let vlessLine = "vless://11111111-2222-3333-4444-555555555555@a.example.com:443"
    + "?encryption=none&security=reality&sni=cdn.example.com&fp=chrome"
    + "&pbk=PUBKEY123&sid=abcd&type=ws&host=ws.example.com&path=%2Fws#%E9%A6%99%E6%B8%AF%2001"
let hy2Line = "hysteria2://letmein@b.example.com:8443"
    + "?sni=cdn.example.com&insecure=1&obfs=salamander&obfs-password=xyz#US%20Node"
let trojanLine = "trojan://secret@d.example.com:443"
    + "?security=tls&sni=cdn.example.com&type=grpc&serviceName=gs#TJ"
let ssSIP002 = "ss://" + b64("aes-256-gcm:pass") + "@e.example.com:8388#SS1"
let ssLegacy = "ss://" + b64("chacha20-ietf-poly1305:pw@f.example.com:12345") + "#SS2"
let tuicLine = "tuic://uuid-x:pass-y@g.example.com:443"
    + "?sni=cdn.example.com&alpn=h3&congestion_control=bbr&udp_relay_mode=native&allow_insecure=1#TUIC"
let vmessJSON = "{\"v\":\"2\",\"ps\":\"VM Node\",\"add\":\"c.example.com\",\"port\":\"443\","
    + "\"id\":\"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\",\"aid\":\"0\",\"net\":\"ws\","
    + "\"type\":\"none\",\"host\":\"ws.example.com\",\"path\":\"/vm\",\"tls\":\"tls\","
    + "\"sni\":\"cdn.example.com\"}"
let vmessLine = "vmess://" + b64(vmessJSON)

// MARK: - 判定

section("内容判定")
expect(NodeSubscription.detect("mixed-port: 7890\nproxies:\n  - name: a") == .mihomoConfig,
       "mihomo YAML 被识别为配置")
expect(NodeSubscription.detect(b64(vlessLine + "\n" + hy2Line)) == .shareLinks,
       "base64 分享链接列表被识别为订阅")
expect(NodeSubscription.detect(vlessLine) == .shareLinks, "明文分享链接也算订阅")
expect(NodeSubscription.detect("<html><title>502 Bad Gateway</title></html>") == .unknown,
       "HTML 错误页不是任何可用格式")
expect(NodeSubscription.detect("") == .unknown, "空响应")
expect(NodeSubscription.looksLikeMihomoConfig("mix" + "ed-port: 7890") == true, "顶层键识别")
expect(NodeSubscription.looksLikeMihomoConfig(vlessLine) == false, "分享链接不是配置")

section("base64 解码容错")
expect(NodeSubscription.decodeBase64(b64(vlessLine)) == vlessLine, "标准 base64")
expect(NodeSubscription.decodeBase64(b64url(vlessLine)) == vlessLine, "URL-safe + 无 padding")
expect(NodeSubscription.decodeBase64("  " + b64(vlessLine) + "\n") == vlessLine, "首尾空白/换行")
expect(NodeSubscription.decodeBase64("!!!!") == nil, "垃圾输入返回 nil")

// MARK: - 协议解析

section("vless（reality + ws）")
let vlessYaml = NodeSubscription.render(b64(vlessLine)).yaml ?? ""
expect(contains(vlessYaml, "type: vless"), "type")
expect(contains(vlessYaml, "server: a.example.com"), "server")
expect(contains(vlessYaml, "port: 443"), "port")
expect(contains(vlessYaml, "uuid: 11111111-2222-3333-4444-555555555555"), "uuid")
expect(contains(vlessYaml, "tls: true"), "security=reality 打开 tls")
expect(contains(vlessYaml, "servername: cdn.example.com"), "sni → servername")
expect(contains(vlessYaml, "client-fingerprint: chrome"), "fp")
expect(contains(vlessYaml, "public-key: PUBKEY123"), "reality public-key")
expect(contains(vlessYaml, "short-id: abcd"), "reality short-id")
expect(contains(vlessYaml, "network: ws"), "transport ws")
expect(contains(vlessYaml, "path: /ws"), "ws path（URL 编码已解开）")
expect(contains(vlessYaml, "Host: ws.example.com"), "ws Host 头")
expect(contains(vlessYaml, "香港 01"), "节点名来自 fragment（已 percent-decode）")

section("hysteria2")
let hy2Yaml = NodeSubscription.render(hy2Line).yaml ?? ""
expect(contains(hy2Yaml, "type: hysteria2"), "type")
expect(contains(hy2Yaml, "password: letmein"), "userinfo → password")
expect(contains(hy2Yaml, "port: 8443"), "port")
expect(contains(hy2Yaml, "sni: cdn.example.com"), "sni")
expect(contains(hy2Yaml, "skip-cert-verify: true"), "insecure=1")
expect(contains(hy2Yaml, "obfs: salamander"), "obfs")
expect(contains(hy2Yaml, "obfs-password: xyz"), "obfs-password")
expect(contains(hy2Yaml, "US Node"), "节点名")

section("vmess（base64 JSON）")
let vmessYaml = NodeSubscription.render(vmessLine).yaml ?? ""
expect(contains(vmessYaml, "type: vmess"), "type")
expect(contains(vmessYaml, "uuid: aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"), "id → uuid")
expect(contains(vmessYaml, "alterId: 0"), "aid → alterId")
expect(contains(vmessYaml, "cipher: auto"), "scy 缺省 auto")
expect(contains(vmessYaml, "tls: true"), "tls 字段")
expect(contains(vmessYaml, "servername: cdn.example.com"), "sni")
expect(contains(vmessYaml, "network: ws"), "net → network")
expect(contains(vmessYaml, "path: /vm"), "ws path")

section("trojan（grpc）")
let trojanYaml = NodeSubscription.render(trojanLine).yaml ?? ""
expect(contains(trojanYaml, "type: trojan"), "type")
expect(contains(trojanYaml, "password: secret"), "password")
expect(contains(trojanYaml, "network: grpc"), "type=grpc")
expect(contains(trojanYaml, "grpc-service-name: gs"), "serviceName")

section("ss（SIP002 与旧格式）")
let ss1 = NodeSubscription.render(ssSIP002).yaml ?? ""
expect(contains(ss1, "type: ss"), "SIP002 type")
expect(contains(ss1, "cipher: aes-256-gcm"), "SIP002 cipher")
expect(contains(ss1, "password: pass"), "SIP002 password")
expect(contains(ss1, "server: e.example.com"), "SIP002 server")
expect(contains(ss1, "port: 8388"), "SIP002 port")
let ss2 = NodeSubscription.render(ssLegacy).yaml ?? ""
expect(contains(ss2, "cipher: chacha20-ietf-poly1305"), "旧格式 cipher")
expect(contains(ss2, "server: f.example.com"), "旧格式 server")
expect(contains(ss2, "port: 12345"), "旧格式 port")

section("tuic")
let tuicYaml = NodeSubscription.render(tuicLine).yaml ?? ""
expect(contains(tuicYaml, "type: tuic"), "type")
expect(contains(tuicYaml, "uuid: uuid-x"), "uuid")
expect(contains(tuicYaml, "password: pass-y"), "password")
expect(contains(tuicYaml, "congestion-controller: bbr"), "congestion_control")
expect(contains(tuicYaml, "udp-relay-mode: native"), "udp_relay_mode")
expect(contains(tuicYaml, "alpn: [h3]"), "alpn 列表")
expect(contains(tuicYaml, "skip-cert-verify: true"), "allow_insecure=1")

// MARK: - 组装出的配置

section("生成的配置本身要合法")
let many = NodeSubscription.render([vlessLine, hy2Line, trojanLine, tuicLine, ssSIP002]
    .joined(separator: "\n") + "\n")
let manyYaml = many.yaml ?? ""
expect(many.nodeCount == 5, "5 条全部转换（实得 \(many.nodeCount)）")
expect(many.skipped.isEmpty, "没有跳过条目")
expect(NodeSubscription.looksLikeMihomoConfig(manyYaml), "生成物通过配置特征检查")
expect(contains(manyYaml, "proxies:"), "有 proxies")
expect(contains(manyYaml, "proxy-groups:"), "有 proxy-groups")
expect(contains(manyYaml, "  - name: PROXY"), "默认选路组")
expect(contains(manyYaml, "type: url-test"), "自动选择组")
expect(contains(manyYaml, "  - MATCH,PROXY"), "兜底规则指向 PROXY")
expect(contains(manyYaml, "mixed-port: 7890"), "端口")
// 模板不再写死 controller 端口：EngineControl.hardenControllerConfig 缺键时
// 统一插 127.0.0.1:9092，MihomoClient.applyController 从 config.yaml 发现端口。
expect(!contains(manyYaml, "external-controller"), "模板不写 external-controller（口径归 harden 兜底）")

section("不支持 / 坏条目的如实报告")
let mixed = NodeSubscription.render([vlessLine, "ssr://" + b64("x"), "garbage line",
                                     "hysteria://old@h.example.com:443"].joined(separator: "\n"))
expect(mixed.nodeCount == 1, "只有 vless 成功（实得 \(mixed.nodeCount)）")
expect(mixed.skipped.count == 3, "三条被跳过（实得 \(mixed.skipped.count)）")
expect(mixed.skipped.contains { $0.contains("ssr") }, "ssr 给出明确原因")
expect(mixed.skipped.contains { $0.contains("hysteria://") }, "hysteria v1 给出明确原因")
expect(NodeSubscription.render("ssr://" + b64("x")).yaml == nil, "全是坏条目时不产出半截配置")

section("重名去重（mihomo 要求 proxy 名唯一）")
let dup = NodeSubscription.render([vlessLine, vlessLine].joined(separator: "\n")).yaml ?? ""
expect(contains(dup, "香港 01 (2)"), "第二个同名节点得到后缀")
expect(dup.components(separatedBy: "- name: ").count - 1 == 4,
       "2 个节点 + 2 个策略组 = 4 个 name（实得 \(dup.components(separatedBy: "- name: ").count - 1)）")

section("YAML 标量引号（与 EngineControl 同一实现）")
expect(YamlScalar.quoteIfNeeded("*") == "\"*\"", "裸 * 必须引号（别名节点是语法错误）")
expect(YamlScalar.quoteIfNeeded("plain") == "plain", "普通值不加引号")
expect(YamlScalar.quoteIfNeeded("a: b") == "\"a: b\"", "含 ': ' 加引号")
expect(YamlScalar.quoteIfNeeded("has # hash") == "\"has # hash\"", "含 ' #' 加引号")
expect(YamlScalar.quoteIfNeeded("\"quoted\"") == "\"\\\"quoted\\\"\"", "首字符是引号时整串引号并转义")

// MARK: - 汇总

print("\n════════════════════════════════════════════════")
if failures == 0 {
    print("NodeSubscription: PASS \(checks) 断言")
    exit(0)
} else {
    print("NodeSubscription: FAIL \(failures)/\(checks)")
    exit(1)
}
