# 同步基础类型（第一阶段）

0.6.0 的新增内容仅在 FritCore，依赖 Foundation，可在 Linux 测试。没有创建文件、读账号、修改 entitlement、启动监听或同步 App 数据。FritSync 的文件协调、Engine、冲突清理、退出提交和各 App 迁移仍未交付。

App 的内容类型实现 `FritCore.SyncContent`：`static format` 是支持的格式上限，`isEmptyForSync` 决定首次开启是否需要选择，`merging(cloud:)` 保留 App 自己的首次字段合并。`static contentKey` 默认 `content`；Proxi 的适配类型提供 `config` 即可保留原文件外形，不使用可变泛型静态全局键。静态 `format` 可以与内容已有的实例 `format` 字段共存。

```swift
let document = SyncDocument(updatedAt: now, device: deviceName, content: current)
let bytes = try document.encoded()
let restored = try SyncDocument<MyContent>.decode(bytes, unknownDevice: localizedUnknownDevice)
```

文档包含 `format/updatedAt/device` 和指定的内容键。外层未来格式先于日期/内容解码检查，直接 Codable 入口也不能绕过；编码时同样拒绝未来格式。缺失版本头固定当旧 format1，缺失日期是 `Date.distantPast`，缺失设备名使用调用者的 `unknownDevice`（默认空字符串）。标准方法保持旧 ISO8601 和稳定键排序，每次创建独立的编解码器。

Core 只知道外层格式。内层 `config.format`、未知字段/项目往返、业务模型的迁移与有效性必须由 Content 自己的解码适配保留；不能把默认 Codable 模型当成真实 App 的兼容迁移。测试中的 content/config 模型是合成夹具，不是用户导出。

`SyncRules.shouldApply(remote:local:lastSynced:)` 只在远端既不同于本机也不同于上次基线时应用；`shouldPush` 比较本机与基线；`needsChoice` 要求远端不同且非空。这里没有执行三方字段合并。`SyncDocument.newest` 只按时间、设备名选择，同时间同设备保留先出现者；不是 Stox 多版本冲突合并的替代品。

`SyncLocation.resolve(override:containerRoot:driveRoot:driveFolder:containerSubfolder:)` 保留覆盖目录、已解析容器、云盘的优先级。有容器权限但容器暂不可用时，调用者传 `driveRoot:nil`，不能悄悄写进第二处。文件夹/文件名拒绝绝对路径、空组件、`.`/`..` 和 NUL，根目录只接收 file URL；函数不判断位置是否真实可用。`fileURL(named:)` 默认 `sync.json`，Proxi 可用 `config.json`。

下一阶段必须保留 Stox 已上线的同一基线下多版本三方合并、会话/操作代际与写中继续编辑；Proxi 保留双层格式检查、旧目录占位保护。只有完成这些及实际文件协调、假云目录测试后才接入 App，真实 iCloud 会话验收另计。

来源：`stox@5e54ee1` 的 `Sources/StoxCore/Sync.swift` 与 `SyncLocation.swift`；config 键对照 Proxi 既有 `SyncedConfig`。业务模型、未知项目、合并字段和本地化留在 App。


## 最小文件层（0.7.0候选）

独立`FritSync`产品在macOS/iOS提供`CloudFile<Content>`，显式传入file URL、最大文档字节数（默认8MiB）、未知设备文本。不查询账号/entitlement/容器，也不替App决定位置；Linux为空模块，不能把Linux编译当实际文件协调验收。

```swift
let file = try CloudFile<MyContent>(at: fileURL)
let remote = try await file.read()
let saved = try await file.update(proposed, base: lastSynced) { base, proposed, current in
    // App提供自己的持续三方合并；current在写协调区内重新读取。
    try reconcile(base: base, proposed: proposed, current: current)
}
```

每实例独立串行Dispatch队列等待NSFileCoordinator，Swift协作线程/MainActor只等continuation；reconcile是后台同步Sendable回调，只处理值，不访问MainActor上的App状态。`read`只在不存在时返回nil；占位、格式、解码与协调错误继续抛出。`update`必须提供合并函数，在协调区内重新读当前文档、检查外层及Content自己的内层格式、执行合并、以相同Content解码器重新验证编码输出并原子写入；不会默认为“最新文档胜出”。有旧式`.文件名.icloud`或系统未下载状态时申请下载并报告notDownloaded，不能当不存在写入。读取至多上限+1字节用于拒绝过大输入；输出超过上限也不落盘。

调用前已取消不入队；一旦接纳，操作不因Task取消而提前返回，也不声称文件副作用被撤销。协调IO/系统调度没有墙钟截止。未来Engine仍须另行实现会话/操作代际与真实提交边界，不能将这个文件层当作disable之后不会写入的完整保证。

本阶段不枚举、清理或标记NSFileVersion，不做旧目录迁移、监听、Engine或App替换；未经冲突和会话阶段验收不能迁入现有App。测试只在普通临时目录实际协调，不等于真实iCloud、容器、跨设备或用户数据兼容验收。来源为stox@5e54ee1的CloudFile协调合并，补充目的文档、占位、有限读取与后台执行保护。
