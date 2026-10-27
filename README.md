# haha-relax · 保持在线 / KeepOnline

A small native macOS menu-bar app. Red means this app is keeping the Mac awake; gray means its session is off. Orange identifies an operation or unresolved state.

**Architecture 3.0 preview implementation. Battery-powered, closed-lid operation has no validated backend and is unavailable.** Ordinary mode does not prevent lid-close or manual sleep. The app does not claim to keep Wi-Fi, VPN, or SSH sessions connected indefinitely.

## 功能与边界

- 原生菜单栏与控制面板，支持深浅外观、文字状态及辅助功能标签。
- 面板按菜单栏图标所在屏幕的可用区域限高；小屏幕和展开内容通过内部滚动访问。
- 30 分钟、1 小时、2 小时或手动结束；屏幕可以正常熄灭。
- 可选磁盘防空闲请求，默认关闭；不通过写磁盘保活。
- 系统托管短期电源请求，到期释放；健康界面每 30 秒续期，90 秒内没有续期则到期。不自动重建已过期请求。
- 电池供电降至 20% 或系统热压力达到 critical 时，停止本工具请求。serious 提示用户。
- 电源、热状态和网络路径仅作本机观察；无应用层网络心跳。
- 无 root、无后台 daemon、无全局电源设置写入，无用户命令行入口。

**合盖能力尚未完成。** 面板明确显示“未验证 · 当前不可用”。研究与应用隔离，不把私有属性、共享内核位或旧版全局睡眠开关当作已验证能力。完整需求的验收仍包括电池合盖，普通模式通过不代表全部目标已完成。

## 本地安装与使用

将 `保持在线.app` 放到个人应用程序文件夹 `~/Applications/`，然后双击打开。应用仅在菜单栏显示，不在 Dock 显示窗口。

1. 点击菜单栏的灰色电源图标，选择持续时间，再点击“开始保持唤醒”。
2. 红色表示本工具的防休眠会话正在生效；灰色表示已关闭；橙色表示操作中或状态待确认。
3. 需要时在“更多选项”中启用磁盘防空闲或登录启动。两者默认关闭。
4. 点击“结束保持唤醒”结束会话；退出应用也会先释放本工具的电源请求。

当前预览包使用本地临时签名，未经过 Apple 公证；自行从源码构建见下节。合盖功能当前不可用，网络连接也不作持续在线保证。

## 构建应用

需要 macOS 14+、Swift 6 工具链。当前交付的预编译应用只验证了 Apple Silicon / macOS 26.4；最低部署版本不等于所有机型和系统均已验证。

```sh
bash scripts/build-app.sh
open build/保持在线.app
```

脚本生成 `.app` 并作本地临时签名。正式 GitHub 下载包需要维护者提供 Developer ID 签名并完成 Apple 公证；本仓库不包含证书或发布凭据。可通过 `CODE_SIGN_IDENTITY` 指定已配置的签名身份。构建缓存与产物留在 `build/`。

默认登录启动关闭；可在面板的“更多选项”中启用。系统可能要求你在“登录项与扩展”中批准。手动从源码构建与注册登录启动是两件独立的事。

## 测试

完整 Xcode：

```sh
swift test
```

仅 Command Line Tools、没有 XCTest 的机器，可以复用同一组核心场景运行便携断言适配器：

```sh
python3 scripts/check-core-portable.py
```

这是显式的便携验证器，不是 XCTest 框架；标准 XCTest 在本次机器上未能运行，原因是没有安装完整 Xcode。系统集成测试在本机创建有限时长的请求，不修改全局电源偏好：

```sh
swift build --product LeaseProbe
python3 scripts/verify-system-leases.py "$(swift build --show-bin-path)/LeaseProbe"
python3 -m unittest discover -s Research -p 'test_*.py'
python3 scripts/check-app-smoke.py build/保持在线.app
python3 scripts/check-panel-layout.py
```

集成测试核验普通、磁盘请求，挂起所有者后的系统到期，过期请求无法续期，以及进程强制退出的清理。它不是合盖、温度保护或长时间网络测试。`LeaseProbe` 仅是内部测试夹具，不随 `.app` 分发。

面板布局检查需要可用的 macOS 桌面，单独编译生产视图与布局策略，在原生弹出窗口中验证默认、小尺寸及展开后的边界和滚动。它不创建电源请求，也不修改登录启动设置；虚拟屏幕坐标检查不代表物理多显示器认证。

## 工程结构

- `Sources/KeepOnlineCore`：唯一会话所有者、资源标识、单调截止、环境停止策略。
- `Sources/KeepOnlinePlatform`：公开 IOPM 电源请求与只读系统事件。
- `Sources/KeepOnlineApp`：菜单栏、原生面板、登录启动和退出交互。
- `Tests`：模拟后端的确定性场景及平台输入校验。
- `Research`：隔离的只读库存工具与隐私测试，不能启用合盖。
- `docs`：架构、兼容性、验证记录和维护说明。

视图读取状态不能续期。MainActor 停止处理事件或进程挂起后，没有独立看门狗替它续期。原生标识可能复用；generation 校验和 native 调用在同一 actor 执行段内，旧会话不能操作新资源。正常退出先尝试释放；不能确认清理时保留运行并提示，系统期限仍在。

## 升级与卸载

退出旧版，再打开新版；本版不自动启动会话。退出本工具后即可删除 `.app`。如果启用过登录启动，先在面板或系统设置关闭。

早期原型使用过全局合盖设置；本版不会自动认领或恢复其他工具的系统设置。如果你曾启用旧版合盖模式，应先通过旧版恢复并退出，再使用本版。不要将系统本来不休眠误认为本版仍持有请求。

## Open source / English

源码仓库：[relaxcrazy528-prog/haha-relax](https://github.com/relaxcrazy528-prog/haha-relax)。本项目采用 [MIT 协议](LICENSE)，保留仓库原有的版权声明。分发源码或其重要部分时，请保留版权声明和许可文本。

KeepOnline is MIT-licensed and hosted in the haha-relax repository. There is no telemetry or automatic update service. The [build and test workflow](docs/ci-build-and-test.yml) is retained as an inactive template; this source-only publication does not enable GitHub Actions or request workflow permission. Any future pull-request CI must receive no signing secrets and must not run global sleep-setting tests.

The shipping app is a single unprivileged process using public, system-expiring IOPM assertions. Disk prevention is opt-in. Sleep, battery, thermal, and network-path observations do not guarantee hardware behavior or application-level connectivity. Closed-lid battery support remains a separate, unvalidated research requirement; it is not silently replaced by `pmset disablesleep`, private entitlements, or an undocumented kernel selector.

See [architecture](docs/Architecture.md), [verification](docs/Verification.md), [lid research](docs/LidCompatibility.md), [security](SECURITY.md), and [license](LICENSE).
