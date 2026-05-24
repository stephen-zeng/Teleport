import AppKit
import SwiftUI

enum InspectorPanelVisualStyle {
    static let sectionFill = dynamicColor(
        light: NSColor.black.withAlphaComponent(0.045),
        dark: NSColor.white.withAlphaComponent(0.07)
    )
    static let sectionStroke = dynamicColor(
        light: NSColor.black.withAlphaComponent(0.08),
        dark: NSColor.white.withAlphaComponent(0.10)
    )
    static let sectionShadow = dynamicColor(
        light: NSColor.black.withAlphaComponent(0.05),
        dark: NSColor.black.withAlphaComponent(0.22)
    )
    static let inlineFill = dynamicColor(
        light: NSColor.black.withAlphaComponent(0.035),
        dark: NSColor.white.withAlphaComponent(0.055)
    )
    static let inlineStroke = dynamicColor(
        light: NSColor.black.withAlphaComponent(0.06),
        dark: NSColor.white.withAlphaComponent(0.08)
    )
    static let codeFill = dynamicColor(
        light: NSColor.black.withAlphaComponent(0.055),
        dark: NSColor.white.withAlphaComponent(0.08)
    )

    private static func dynamicColor(light: NSColor, dark: NSColor) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                switch appearance.bestMatch(from: [.darkAqua, .aqua]) {
                case .darkAqua:
                    return dark
                default:
                    return light
                }
            }
        )
    }
}

struct InspectorPanelSection<Content: View>: View {
    let title: LocalizedStringResource?
    let isExpanded: Binding<Bool>?
    @ViewBuilder let content: () -> Content

    init(_ title: LocalizedStringResource? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.isExpanded = nil
        self.content = content
    }

    init(
        _ title: LocalizedStringResource,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.isExpanded = isExpanded
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                if let isExpanded {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isExpanded.wrappedValue.toggle()
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Text(title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)

                            Spacer(minLength: 8)

                            Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                }
            }

            if isExpanded?.wrappedValue ?? true {
                content()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(InspectorPanelVisualStyle.sectionFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(InspectorPanelVisualStyle.sectionStroke)
        )
        .shadow(color: InspectorPanelVisualStyle.sectionShadow, radius: 10, y: 4)
    }
}

struct InspectorInlineDisclosure<Content: View>: View {
    let title: LocalizedStringResource
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    Spacer(minLength: 8)

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                content()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(InspectorPanelVisualStyle.inlineFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(InspectorPanelVisualStyle.inlineStroke)
        )
    }
}

struct PythonDependencyInstallSheet: View {
    let guide: PythonDependencyInstallGuide
    let dismissAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Install or Upgrade pymobiledevice3")
                        .font(.title3.weight(.semibold))

                    Text(
                        "Physical-device simulation needs pymobiledevice3 5.0 or newer in the exact Python interpreter selected for the helper. Run the fix command as your normal macOS user so Teleport can reuse that package path after administrator approval."
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let installedVersion = guide.installedVersion, !installedVersion.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Installed Version")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    SelectableCodeRow(text: installedVersion)
                }
            }

            if let minimumVersion = guide.minimumSupportedVersion, !minimumVersion.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Minimum Supported Version")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    SelectableCodeRow(text: minimumVersion)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Resolved Python")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                SelectableCodeRow(text: guide.resolvedPythonPath)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Fix Command")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                SelectableCodeRow(text: guide.installCommand)
            }

            Text(
                "Run the command in Terminal as your normal macOS user, then return here and retry the physical-device location action."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button("Copy Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(guide.installCommand, forType: .string)
                }
                .buttonStyle(.borderedProminent)

                Button("Close") {
                    dismissAction()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}

struct SelectableCodeRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(InspectorPanelVisualStyle.codeFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(InspectorPanelVisualStyle.inlineStroke)
            )
    }
}

enum StatusTone {
    case neutral
    case active
    case good
    case error

    var foregroundColor: Color {
        switch self {
        case .neutral:
            return .secondary
        case .active:
            return .blue
        case .good:
            return .green
        case .error:
            return .red
        }
    }

    var backgroundColor: Color {
        switch self {
        case .neutral:
            return Color.secondary.opacity(0.12)
        case .active:
            return Color.blue.opacity(0.14)
        case .good:
            return Color.green.opacity(0.14)
        case .error:
            return Color.red.opacity(0.14)
        }
    }
}

struct StatusRow: View {
    let title: LocalizedStringResource
    let value: UserFacingText
    let tone: StatusTone

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            StatusRowValue(value: value, tone: tone)
        }
    }
}

struct StatusRowValue: View {
    let value: UserFacingText
    let tone: StatusTone

    var body: some View {
        Text(value)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tone.foregroundColor)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(tone.backgroundColor)
            )
    }
}

struct CopiedPopup: View {
    var body: some View {
        Text("Copied")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(NSColor.windowBackgroundColor).opacity(0.96))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08))
            )
            .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
    }
}

struct USBOnboardingSheet: View {
    @State private var suppressFuturePrompts = false

    let guide: USBSetupGuide?
    let continueAction: (Bool) -> Void
    let cancelAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.blue.opacity(0.9), Color.cyan.opacity(0.7)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 52, height: 52)

                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Physical Device Setup")
                        .font(.title3.weight(.semibold))
                    Text(
                        "Before simulating location on a physical iPhone, confirm the device and host are ready."
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                SimpleSecurityRow(
                    icon: "iphone.gen3.badge.exclamationmark",
                    text: "Enable Developer Mode on the iPhone in Settings > Privacy & Security > Developer Mode."
                )
                SimpleSecurityRow(
                    icon: "hammer",
                    text:
                        "Install Xcode and open it once so Apple's developer tools finish setup and `xcrun` can access device and simulator tooling."
                )
                SimpleSecurityRow(
                    icon: "terminal",
                    text: "Install Python 3 on this Mac so `python3` resolves from your shell."
                )
                SimpleSecurityRow(
                    icon: "shippingbox",
                    text:
                        "Install or upgrade pymobiledevice3 5.0 or newer for the same Python interpreter used by the device helper. The command below is meant to run as your normal macOS user."
                )
                SimpleSecurityRow(
                    icon: "wifi",
                    text:
                        "For Wi-Fi discovery, connect once over USB first, accept pairing, then keep the iPhone unlocked on the same local network."
                )
                SimpleSecurityRow(
                    icon: "checkmark.shield",
                    text:
                        "macOS will ask for your administrator password in a separate system dialog when the physical-device tunnel starts."
                )
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(InspectorPanelVisualStyle.inlineFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(InspectorPanelVisualStyle.inlineStroke)
            )

            VStack(alignment: .leading, spacing: 8) {
                Text("Developer Tools")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                SelectableCodeRow(text: "xcode-select --install")
                SelectableCodeRow(text: "sudo xcode-select -s /Applications/Xcode.app/Contents/Developer")
            }

            Text(
                "`xcrun` is not guaranteed to be usable on a clean macOS install. If macOS reports missing developer tools, install them with `xcode-select --install`. If full Xcode is already installed but the active developer directory is wrong, run `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`, then launch Xcode once to finish setup."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Text("Resolved Python")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                SelectableCodeRow(
                    text: guide?.pythonStatusText ?? String(localized: TeleportStrings.selectUSBDeviceToResolvePython))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Install or Upgrade Command")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                SelectableCodeRow(
                    text: guide?.pythonInstallCommand ?? "python3 -m pip install --upgrade pymobiledevice3"
                )
            }

            Text(
                "Run the command in Terminal as your normal macOS user if needed, then continue. You can copy it directly from this sheet."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Toggle("Don't show this again", isOn: $suppressFuturePrompts)
                .toggleStyle(.checkbox)

            HStack {
                Button(String(localized: TeleportStrings.cancel), role: .cancel) {
                    cancelAction()
                }

                Button("Copy Install Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        guide?.pythonInstallCommand ?? "python3 -m pip install --upgrade pymobiledevice3",
                        forType: .string
                    )
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Continue") {
                    continueAction(suppressFuturePrompts)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}

struct SimpleSecurityRow: View {
    let icon: String
    let text: LocalizedStringResource

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 18)

            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
