import Foundation

// Compiles the shipping parser (Sources/Core/YamlEditor/YamlScalar.swift) in.
// EngineControl.tunDevicePin() delegates to YamlScalar.nestedScalar, so this
// suite pins the real production path instead of re-implementing the scan.

var failures = 0, checks = 0
func expect(_ cond: Bool, _ what: String) {
    checks += 1
    if !cond { failures += 1; print("  ✗ FAIL: \(what)") } else { print("  ✓ \(what)") }
}
func section(_ s: String) { print("\n── \(s) ──") }

func pin(_ text: String) -> String? {
    YamlScalar.nestedScalar(in: text, block: "tun", key: "device")
}

// MARK: - Nested block location

section("块内定位")
expect(pin("tun:\n  enable: true\n  device: utun100\n") == "utun100", "基本形态")
expect(pin("tun:\n\tdevice: utun101\n") == "utun101", "tab 缩进")
expect(pin("dns:\n  device: en0\ntun:\n  device: utun100\n") == "utun100", "块外同名键不串味")
expect(pin("tun:\n  device: utun100\ndns:\n  device: en0\n") == "utun100", "只取 tun 块内首个")
expect(pin("tun:  # 设备选项\n  device: utun100\n") == "utun100", "顶层键带行尾注释")
expect(pin("port: 7890\n  device: utun100\n") == nil, "不在 tun 块里的缩进行忽略")
expect(pin("tun:\n  device:\n") == nil, "空值视为 nil")
expect(pin("tun:\n  enable: true\n") == nil, "没有 device 键")

// MARK: - Quotes and inline comments

section("引号与注释口径")
expect(pin("tun:\n  device: \"utun100\"\n") == "utun100", "双引号剥离")
expect(pin("tun:\n  device: 'utun100'\n") == "utun100", "单引号剥离")
expect(pin("tun:\n  device: utun100   # 固定设备\n") == "utun100", "行尾注释剥离")
expect(pin("tun:\n  device: \"utun100\" # 固定设备\n") == "utun100", "引号后注释剥离")
expect(pin("tun:\n  device: \"a#b\"\n") == "a#b", "引号内 # 是数据")
expect(pin("tun:\n  device: utun100#tag\n") == "utun100#tag", "无空白的 # 是数据，不再误当注释")

print("\n\(checks - failures)/\(checks) 通过")
if failures > 0 {
    print("\(failures) 项失败")
    exit(1)
}
