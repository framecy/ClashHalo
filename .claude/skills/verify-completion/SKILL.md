---
name: verify-completion
description: 代码改动收尾前的强制审查关卡。UI 布局、SwiftUI 视图容器、YAML/分享链接等数据格式解析或写入、跨文件批量/正则编辑之后必须跑一遍；全部关卡过了才能向用户报告"完成"。
---

# 收尾审查关卡

这个 skill 存在的原因：本会话里多次把"能编译"当成"做完了"，结果用户在真机上截图揪出编译期查不出来的 bug——Grid 没撑满宽度导致内容缩在窗口一角、正则批量插入落在了不该改的位置、订阅 URL 解析被空行打断状态机、字符串 trim 顺序错误。这些全部符合 Swift 语法、编译通过、单看代码逻辑也说得通，只有跑起来 / 拿真实数据核一遍才会暴露。**"builds successfully" 只证明语法合法，不证明语义正确、视觉正确、功能正确。**

不要凭"看起来对"就报告完成。凡是下面任意一条命中，收尾前必须走完对应关卡；关卡没过，不许说"完成"/"done"，要么继续修，要么明确告诉用户卡在哪一步、什么现象、你的猜测原因。

## 触发条件

- 改了 `Sources/UI/**` 下任何 SwiftUI 视图文件
- 改了任何解析/序列化外部数据格式的代码（YAML 行扫描、分享链接、JSON、配置文件读写）
- 用脚本/正则做了跨多个位置的批量编辑（不是手动一处一处改的）
- 新增了 Swift 源文件
- 用户明确指出了一个具体的视觉/行为 bug，你要修它

## 关卡 0 — 编译

```bash
xcodebuild -project ClashHalo.xcodeproj -scheme ClashHalo -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|warning:|BUILD"
```

`BUILD SUCCEEDED` 是及格线，不是终点。新出现的 warning（尤其是 unused variable/never used，说明有代码路径没接上）要看一眼是不是自己引入的。

## 关卡 1 — 布局容器是否真的撑满可用空间

本会话踩过的坑：`Grid` / 手写 `HStack` 在 `ScrollView` 里默认按内容算固有宽度，不会主动撑满父容器——不加 `.frame(maxWidth: .infinity, alignment: .leading)` 的话，内容会缩在窗口左上角一小块，右边/下边大片留白，窗口越宽越明显。

改了/新增了任何 `Grid(`、顶层 `ScrollView` 里的 `VStack`/`HStack` 之后：

```bash
grep -n "Grid(alignment" Sources/UI/**/*.swift
```

对每一处，人工确认对应的 `Grid { ... }` 闭合之后、下一个 `.padding(.horizontal, DS.Layout.pageContentInset)` 之前，有 `.frame(maxWidth: .infinity, alignment: .leading)`（或等价的撑满写法）。逐处看，不要只看数量对不对——见关卡 3。

如果同一个 `GridRow` 里有多张卡需要等高，确认每张卡都传了同一个 `height:` 或都传了 `stretch: true`，不能有的传有的没传。

## 关卡 2 — 设计系统字面量（design.md §8 既有自检，原样照跑）

```bash
rg '\.font\(\.system\(size:' Sources/UI Sources/App
rg 'foregroundColor\(\.(red|green|orange|cyan|blue|purple)\b' Sources/UI Sources/App
rg 'cornerRadius: *[0-9]' Sources/UI Sources/App
rg '\.padding\((\.\w+, *)?[0-9]' Sources/UI Sources/App
```

命中的每一行确认是否在 `DesignTokens.swift`（token 定义本身允许字面量）之外——外面命中的要么改成 `DS.*` token，要么在注释里写清楚为什么这里必须是字面量。

## 关卡 3 — 批量/正则编辑：逐处核对，不要信数量

用 `python3 -c` / `sed` / 正则做过跨文件或跨多处的替换之后：

```bash
grep -n "<刚插入的那一行特征文本>" <改动的文件>
```

把每一个命中位置都读一遍上下文（`sed -n 'N-5,N+5p' 文件`），确认它是你想改的那个结构（比如确实是某个 `Grid` 的收尾），而不是模式恰好也匹配上的别的地方。本会话里一次批量插入 6 处，有 2 处是误伤——都是先看"替换了 N 处，数量对"就当完事，后来才发现插到了不相关的 `HStack`/`ScrollView` 上。**数量对不代表位置对。**

## 关卡 4 — 数据格式解析/写入：拿真实数据跑一遍，不要只读代码

如果改动涉及读写 config.yaml、分享链接、订阅缓存文件等手写文本格式解析器：

1. 复制真实文件到 scratchpad（不要碰用户正在跑的实例的原文件）：
   ```bash
   cp "/Users/framed/Library/Application Support/ClashHalo/config.yaml" "$SCRATCHPAD/test.yaml"
   ```
2. 把改动的核心逻辑抽成一个独立 `.swift` 脚本（`swift file.swift` 直接跑，不需要整个 App 编译），对着真实文件跑一遍，打印中间结果，人工核对是否符合预期——不是"读代码觉得逻辑对"，是实际执行看输出。
3. 如果改动最终要交给 mihomo 内核加载，用真实内核二进制做最后一层校验：
   ```bash
   "/Users/framed/Library/Application Support/ClashHalo/bin/mihomo" -t -d "$SCRATCHPAD目录" -f test.yaml
   ```
   看到 `test is successful` 才算数，看到 `BUILD SUCCEEDED` 不算数——这是两件事，`xcodebuild` 只保证 Swift 代码本身编译通过，不保证生成的 YAML 内核愿意加载。
4. 边界情况至少测一个：空输入、找不到匹配、字段缺失、这次改动之前会触发 bug 的那个具体输入（复现 bug 的最小案例）。
5. 用完删掉 scratchpad 里的临时文件。

## 关卡 5 — 新增 Swift 文件是否进了 Xcode 工程

这个项目是 `.xcodeproj`，不是 SPM，新建的 `.swift` 文件不会自动被编译——必须手动加进 `project.pbxproj`（用 `xcodeproj` gem 或直接改 pbxproj），否则会报 "cannot find type in scope"，而且报错信息不会提示你"这个文件没注册"。

```bash
grep -c "<新文件名>.swift" ClashHalo.xcodeproj/project.pbxproj
```

至少要有 3 处命中（PBXBuildFile / PBXFileReference / Sources build phase 里各一处）。

## 关卡 6 — 如果是在修用户指出的具体 bug

复述一遍："旧代码为什么会产生这个症状"——具体到哪一行、哪个机制。如果说不出旧代码为什么会产生用户截图里那个现象，就还没真正定位根因，不要动手改；改完之后，确认新代码消除的正是那个机制，不是"看起来合理的另一处改动"。

## 报告完成时要说清楚跑过哪些关卡

不要只说"修好了"。至少要带：编译状态、哪些关卡跑了、静态检查有没有新增命中、如果涉及数据格式解析——用什么真实数据验证的、结果是什么。没跑的关卡（比如没法做的真机视觉验证）要明说没跑，不要含糊带过当作已验证。
