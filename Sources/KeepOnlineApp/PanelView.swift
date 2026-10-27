import AppKit
import SwiftUI

enum SessionLength: String, CaseIterable, Identifiable {
    case halfHour = "30 分钟"
    case hour = "1 小时"
    case twoHours = "2 小时"
    case manual = "手动结束"

    var id: String { rawValue }
    var seconds: TimeInterval? {
        switch self {
        case .halfHour: 1_800
        case .hour: 3_600
        case .twoHours: 7_200
        case .manual: nil
        }
    }
}

enum StatusAppearance {
    case inactive, active, attention

    var color: Color {
        switch self {
        case .inactive: Color(nsColor: .secondaryLabelColor)
        case .active: Color(red: 0.96, green: 0.12, blue: 0.16)
        case .attention: Color(nsColor: .systemOrange)
        }
    }

    var nsColor: NSColor {
        switch self {
        case .inactive: .secondaryLabelColor
        case .active: NSColor(srgbRed: 0.96, green: 0.12, blue: 0.16, alpha: 1)
        case .attention: .systemOrange
        }
    }
}

struct PanelPresentation {
    var appearance: StatusAppearance = .inactive
    var status = "已关闭"
    var headline = "让任务继续，屏幕安心熄灭。"
    var detail = "需要长时间构建、下载或远程开发时，保持 Mac 唤醒。"
    var remaining = "开启后开始计时"
    var running = false
    var busy = false
    var hasResources = false
    var note: String?
    var diagnostic: String = "尚未启动防休眠会话。"
    var power = "正在读取"
    var powerIcon = "battery.100percent"
    var network = "正在读取"
    var networkIcon = "network"
    var thermal = "正在读取"
    var thermalWarning = false
    var loginEnabled = false
    var loginNeedsApproval = false
    var loginError: String?
}

struct PanelView: View {
    let state: PanelPresentation
    var viewportSize: NSSize = PanelLayout.preferredSize
    @Binding var duration: SessionLength
    @Binding var keepDiskActive: Bool
    @Binding var showOptions: Bool
    @Binding var showHelp: Bool
    let toggle: () -> Void
    let setLogin: (Bool) -> Void
    let openLoginSettings: () -> Void
    let quit: () -> Void

    private var card: Color { Color(nsColor: .controlBackgroundColor) }

    var body: some View {
        ScrollView(.vertical) { content }
            .scrollBounceBehavior(.basedOnSize)
            .frame(width: viewportSize.width, height: viewportSize.height)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("保持在线").font(.system(size: 20, weight: .semibold))
                    Text("KeepOnline").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                }
                Spacer()
                Label(state.status, systemImage: state.appearance == .attention ? "exclamationmark.circle.fill" : "circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(state.appearance.color)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(state.appearance.color.opacity(0.10), in: Capsule())
                    .accessibilityLabel("防休眠状态：\(state.status)")
            }

            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "power.circle.fill")
                        .font(.system(size: 38, weight: .regular))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.white, state.appearance.color)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(state.headline).font(.system(size: 14, weight: .semibold))
                        Text(state.remaining)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(state.running ? state.appearance.color : .secondary)
                    }
                }
                Text(state.detail)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(3)

                if !state.running && !state.hasResources {
                    Picker("保持时长", selection: $duration) {
                        ForEach(SessionLength.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(state.busy)
                    .accessibilityLabel("保持时长")
                }

                Button(action: toggle) {
                    HStack(spacing: 7) {
                        Spacer(minLength: 0)
                        if state.busy {
                            ProgressView().controlSize(.small).scaleEffect(0.8)
                        } else {
                            Image(systemName: state.hasResources ? "stop.fill" : "power")
                        }
                        Text(state.busy ? "正在处理…" : state.hasResources ? "结束保持唤醒" : "开始保持唤醒")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer(minLength: 0)
                    }
                    .frame(height: 41)
                    .foregroundStyle(Color.white)
                    .background(state.appearance == .attention ? Color.orange : Color(red: 0.96, green: 0.12, blue: 0.16), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .controlSize(.large)
                .disabled(state.busy)
                .keyboardShortcut(.return, modifiers: [])
            }
            .padding(15)
            .background(card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.primary.opacity(0.045), lineWidth: 1))

            if let note = state.note {
                Label {
                    Text(note).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: state.appearance == .attention ? "exclamationmark.circle" : "info.circle")
                }
                .foregroundStyle(state.appearance == .attention ? Color.orange : .secondary)
            }

            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 9) {
                    Image(systemName: "laptopcomputer").font(.system(size: 16)).frame(width: 22)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("合盖防休眠").font(.system(size: 12, weight: .medium))
                        Text("未验证 · 当前不可用").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "lock.circle").foregroundStyle(.tertiary)
                        .accessibilityLabel("合盖防休眠尚未验证，当前不可用")
                }
                Text("普通模式允许合盖后进入睡眠。合盖能力需独立验证，通过前不会更改系统睡眠设置。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).lineSpacing(2)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    environmentLabel(state.power, icon: state.powerIcon)
                    Spacer()
                    environmentLabel(state.thermal, icon: "thermometer.medium", warning: state.thermalWarning)
                }
                environmentLabel(state.network, icon: state.networkIcon)
                Text("网络路径状态仅供参考，防休眠不能保证连接不断。")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }

            DisclosureGroup("更多选项", isExpanded: $showOptions) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(isOn: $keepDiskActive) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("保持磁盘活跃").font(.system(size: 12))
                            Text("按需启用，开始前可更改。")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch).controlSize(.small).tint(.red)
                    .disabled(state.hasResources || state.busy)

                    Toggle("登录时打开", isOn: Binding(get: { state.loginEnabled }, set: { value in setLogin(value) }))
                        .font(.system(size: 12)).toggleStyle(.switch).controlSize(.small).tint(.red)
                    if state.loginNeedsApproval {
                        Button("在系统设置中允许登录启动", action: openLoginSettings)
                            .font(.system(size: 11)).buttonStyle(.link)
                    }
                    if let loginError = state.loginError {
                        Text(loginError).font(.system(size: 10)).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(.top, 10)
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)

            HStack {
                Button(showHelp ? "收起帮助" : "帮助与诊断") { showHelp.toggle() }
                    .buttonStyle(.link).font(.system(size: 11))
                Spacer()
                Button("退出", action: quit).font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(.secondary)
                    .keyboardShortcut("q")
            }

            if showHelp {
                VStack(alignment: .leading, spacing: 8) {
                    Text("屏幕可以熄灭，手动睡眠和系统电源策略仍然有效。电池降至 20% 或系统热压力达到极高等级时，本工具结束会话。网络、VPN 和 SSH 有各自的连接规则。")
                    Text("本工具无需管理员权限，不安装后台服务，不修改全局睡眠设置。防休眠请求由系统限时管理；应用卡住后，请求会到期释放，不会自动重新开启。")
                    Text(state.diagnostic).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12).background(card, in: RoundedRectangle(cornerRadius: 9))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func environmentLabel(_ text: String, icon: String, warning: Bool = false) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 11))
            .foregroundStyle(warning ? Color.orange : Color.secondary)
            .lineLimit(1)
            .accessibilityLabel(text)
    }
}
