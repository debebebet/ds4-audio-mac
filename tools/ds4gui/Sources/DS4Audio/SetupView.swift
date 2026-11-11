import SwiftUI

/// Мастер первоначальной настройки.
///
/// Показывается при первом запуске и по кнопке «Настройка…» в главном окне.
/// Проводит пользователя через три шага: что это за приложение, установка
/// HAL-драйвера «DualShock 4» и проверка геймпада.
struct SetupView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    enum Step: Int, CaseIterable {
        case welcome
        case driver
        case controller
        case done

        var title: String {
            switch self {
            case .welcome: return "Добро пожаловать"
            case .driver: return "Аудиодрайвер"
            case .controller: return "Контроллер"
            case .done: return "Готово"
            }
        }

        var symbol: String {
            switch self {
            case .welcome: return "gamecontroller.fill"
            case .driver: return "speaker.wave.3.fill"
            case .controller: return "dot.radiowaves.left.and.right"
            case .done: return "checkmark.circle.fill"
            }
        }
    }

    @State private var step: Step = .welcome
    @State private var installError: String?
    @State private var waitingForDevice = false

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch step {
                    case .welcome: welcomeStep
                    case .driver: driverStep
                    case .controller: controllerStep
                    case .done: doneStep
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            footer
        }
        .frame(width: 540, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.checkNow() }
        .onChange(of: model.routerReady) { ready in
            if ready { waitingForDevice = false }
        }
        .onChange(of: model.errorMessage) { message in
            if let message { installError = message }
        }
    }

    // MARK: - Шапка

    private var header: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: step.symbol)
                    .font(.system(size: 30))
                    .foregroundStyle(Color.accentColor)
                    .symbolRenderingMode(.hierarchical)

                VStack(alignment: .leading, spacing: 2) {
                    Text(step.title)
                        .font(.system(size: 20, weight: .semibold))
                    Text("DualShock 4 Audio")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.rawValue) { item in
                    Capsule()
                        .fill(item.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(height: 4)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    // MARK: - Шаг 1: приветствие

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Системный звук — в динамик геймпада")
                .font(.title3.weight(.semibold))

            Text("""
                DualShock 4 Audio переводит звук всех приложений macOS во \
                встроенный динамик DualShock 4 — по Bluetooth, без проводов.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                requirement(icon: "speaker.wave.3.fill",
                            title: "Аудиодрайвер",
                            detail: "Создаёт виртуальное устройство «DualShock 4». "
                                + "Устанавливается один раз и требует пароль администратора.")
                requirement(icon: "dot.radiowaves.left.and.right",
                            title: "Геймпад по Bluetooth",
                            detail: "По USB звук в динамик не идёт — нужен Bluetooth.")
                requirement(icon: "arrow.triangle.2.circlepath",
                            title: "Автоподхват",
                            detail: "Приложение ищет геймпад каждые 5 секунд и подхватывает "
                                + "его сам, как только тот подключится.")
            }

            Text("Требуется macOS 13 или новее.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func requirement(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Шаг 2: драйвер

    private var driverStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Виртуальное аудиоустройство")
                .font(.title3.weight(.semibold))

            Text("""
                macOS не умеет отправлять звук в динамик геймпада напрямую. \
                Нужен собственный HAL-драйвер: он создаёт устройство \
                «DualShock 4», которое принимает системный звук и отдаёт его \
                обратно как вход — его-то и читает стример.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            statusCard

            if let installError {
                Label(installError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.driverState == .current, !DriverInstaller.installedDriverSupportsAutoHide {
                Label("""
                    Установленная версия драйвера устарела: она не убирает \
                    устройство из системы после выхода приложения. Обновите драйвер.
                    """, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Установка копирует драйвер в /Library/Audio/Plug-Ins/HAL. "
                 + "macOS спросит пароль администратора.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusCard: some View {
        HStack(spacing: 12) {
            Image(systemName: driverStatusSymbol)
                .font(.system(size: 20))
                .foregroundStyle(driverStatusColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(driverStatusTitle)
                    .font(.callout.weight(.medium))
                Text(driverStatusDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(driverStatusColor.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 10))
    }

    private var driverStatusTitle: String {
        switch model.driverState {
        case .notInstalled: return "Драйвер не установлен"
        case .outdated: return "Требуется обновление драйвера"
        case .current: return model.routerReady
            ? "Драйвер установлен, устройство «DualShock 4» доступно"
            : "Драйвер установлен, ожидаем загрузку устройства"
        }
    }

    private var driverStatusDetail: String {
        switch model.driverState {
        case .notInstalled:
            return "Установить один раз — потребуется пароль администратора."
        case .outdated:
            return "В системе стоит другая версия, чем внутри приложения."
        case .current:
            return "Устройство появится через пару секунд после запуска."
        }
    }

    private var driverStatusSymbol: String {
        switch model.driverState {
        case .notInstalled: return "arrow.down.circle"
        case .outdated: return "arrow.triangle.2.circlepath"
        case .current: return model.routerReady ? "checkmark.circle.fill" : "clock"
        }
    }

    private var driverStatusColor: Color {
        switch model.driverState {
        case .notInstalled: return .orange
        case .outdated: return .orange
        case .current: return model.routerReady ? .green : .secondary
        }
    }

    // MARK: - Шаг 3: контроллер

    private var controllerStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Геймпад")
                .font(.title3.weight(.semibold))

            Text("""
                Включите DualShock 4 кнопкой питания. Приложение ищет его \
                каждые 5 секунд, так что подключать нужно до включения — или \
                позже, когда удобно.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Image(systemName: model.bluetoothDevice == nil
                      ? "gamecontroller" : "gamecontroller.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(model.bluetoothDevice == nil
                                     ? Color.secondary : Color.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.bluetoothDevice?.product ?? "Геймпад не найден")
                        .font(.callout.weight(.medium))
                    Text(model.bluetoothDevice.map { "\($0.transport) · \($0.vidPID)" }
                         ?? "Ожидание подключения по Bluetooth…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

            Text("""
                Если геймпад уже сопряжён с этим Mac, но здесь не виден — \
                проверьте, что он включён и что в «Системных настройках → \
                Bluetooth» он подключён.
                """)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Шаг 4: готово

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Настройка завершена", systemImage: "checkmark.circle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 10) {
                summaryRow("Аудиодрайвер",
                           ok: model.driverState == .current && model.routerReady)
                summaryRow("Геймпад по Bluetooth",
                           ok: model.bluetoothDevice != nil)
                summaryRow("Системный звук", ok: model.routerReady)
            }

            Text("""
                Геймпад можно подключить и позже — приложение подхватит его \
                само в течение 5 секунд после подключения.
                """)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func summaryRow(_ title: String, ok: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ok ? .green : .secondary)
            Text(title)
                .font(.callout)
            Spacer()
            Text(ok ? "готово" : "пропущено")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Низ

    private var footer: some View {
        HStack(spacing: 12) {
            if step == .welcome {
                Button("Пропустить") {
                    model.finishSetup()
                    dismiss()
                }
                .buttonStyle(.link)
            } else if step != .done {
                Button("Назад") {
                    step = Step(rawValue: step.rawValue - 1) ?? .welcome
                }
                .buttonStyle(.link)
            }

            Spacer()

            switch step {
            case .welcome:
                Button("Далее") { step = .driver }
                    .buttonStyle(.borderedProminent)

            case .driver:
                if model.driverState == .current {
                    Button("Далее") { step = .controller }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button {
                        installDriver()
                    } label: {
                        if model.isInstallingDriver {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Установка…")
                            }
                        } else {
                            Text(model.driverState == .outdated
                                 ? "Обновить драйвер…" : "Установить драйвер…")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isInstallingDriver)
                }

            case .controller:
                Button("Далее") { step = .done }
                    .buttonStyle(.borderedProminent)

            case .done:
                Button("Готово") {
                    model.finishSetup()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    // MARK: - Установка драйвера

    private func installDriver() {
        installError = nil
        waitingForDevice = true
        model.installDriver(enableSystemAudio: false)
    }
}
