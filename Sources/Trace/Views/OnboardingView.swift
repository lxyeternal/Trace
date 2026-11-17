import SwiftUI
import TraceCore

/// First launch: language and appearance, the Accessibility permission, and
/// launch at login.
struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var watcher: ActivityWatcher

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 12) {
                BrandMark(size: 40)
                VStack(alignment: .leading, spacing: 0) {
                    Text(L("Welcome to Trace")).font(.system(size: 24, weight: .bold)).tracking(-0.2)
                    Text(L("Three steps to set up, then it records quietly from the menu bar"))
                        .foregroundStyle(Theme.muted)
                }
            }

            VStack(spacing: 12) {
                step(1, state: .done, title: L("Choose language and appearance"),
                     note: L("Both can be changed later in Settings")) {
                    HStack(spacing: 8) {
                        Picker(L("Language"), selection: $model.language) {
                            Text(L("System")).tag(AppLanguage.system)
                            Text("简体中文").tag(AppLanguage.zhHans)
                            Text("English").tag(AppLanguage.en)
                            Text("Русский").tag(AppLanguage.ru)
                        }
                        Picker(L("Appearance"), selection: $model.appearance) {
                            Text(L("Light")).tag(Appearance.light)
                            Text(L("Dark")).tag(Appearance.dark)
                            Text(L("System")).tag(Appearance.system)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                step(2, state: watcher.isTrusted ? .done : .current, title: L("Grant Accessibility access"),
                     note: L("Used to read the current window's title, file path and browser URL. Keystrokes and screen contents are never recorded.")) {
                    if watcher.isTrusted {
                        Text(L("Done")).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ok)
                    } else {
                        Button(L("Open System Settings")) {
                            AXReader.requestTrust()
                            AXReader.openSettings()
                        }
                        .buttonStyle(TRButtonStyle(kind: .prominent, height: 32))
                    }
                }
                step(3, state: watcher.isTrusted ? .current : .pending, title: L("Launch at login"),
                     note: L("Start recording after you log in; pause any time from the menu bar")) {
                    Toggle(L("Launch at login"), isOn: Binding(get: { model.launchAtLogin },
                                                              set: { model.setLaunchAtLogin($0) }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }

            Spacer(minLength: 0)

            VStack(spacing: 20) {
                Hairline()
                HStack(spacing: 16) {
                    Image(systemName: "lock").font(.system(size: 16)).foregroundStyle(Theme.muted)
                    Text(L("All data stays on this Mac. Trace is open source: no network, no uploads, no account."))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                    Spacer(minLength: 12)
                    if !watcher.isTrusted {
                        Button(L("Skip for now")) { model.finishOnboarding() }.buttonStyle(.trLink)
                    }
                    Button(L("Start recording")) { model.finishOnboarding() }
                        .buttonStyle(TRButtonStyle(kind: .prominent, height: 34))
                        .disabled(!watcher.isTrusted)
                }
            }
        }
        .padding(EdgeInsets(top: 48, leading: 64, bottom: 40, trailing: 64))
        .frame(width: 880, height: 640)
        .background(Theme.panel)
        .font(.system(size: 13))
        .foregroundStyle(Theme.ink)
        .id(model.language)
    }

    private enum StepState { case done, current, pending }

    private func step<Trailing: View>(_ number: Int, state: StepState, title: String, note: String,
                                      @ViewBuilder trailing: () -> Trailing) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return HStack(spacing: 16) {
            ZStack {
                switch state {
                case .done:
                    Circle().fill(Theme.ok)
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.panel)
                case .current:
                    Circle().fill(Theme.accent)
                    Text("\(number)").fontWeight(.bold).foregroundStyle(Theme.onAccent)
                case .pending:
                    Circle().strokeBorder(Theme.line)
                    Text("\(number)").fontWeight(.bold).foregroundStyle(Theme.muted)
                }
            }
            .frame(width: 28, height: 28)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).fontWeight(.semibold)
                Text(note).font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(state == .current ? Theme.soft : .clear, in: shape)
        .overlay(shape.strokeBorder(state == .current ? Theme.accent : Theme.line, lineWidth: state == .current ? 2 : 1))
    }
}
