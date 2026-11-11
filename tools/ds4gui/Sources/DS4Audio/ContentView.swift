import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showLog = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 16) {
                    controllerCard
                    volumeCard
                    systemAudioCard
                    if let error = model.errorMessage {
                        errorBanner(error)
                    }
                    logCard
                }
                .padding(20)
            }
        }
        .frame(minWidth: 580, idealWidth: 620, minHeight: 640, idealHeight: 720)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $model.showSetup) {
            SetupView()
                .environmentObject(model)
        }
        .task {
            model.start()
        }
    }

    // MARK: - Шапка

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)

            VStack(alignment: .leading, spacing: 2) {
                Text("DualShock 4 Audio")
                    .font(.system(size: 22, weight: .semibold))
                Text("Системный звук в динамик геймпада по Bluetooth")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)
            statusPill
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var statusPill: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(model.statusTitle)
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(statusColor.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(statusColor.opacity(0.28)))
    }

    // MARK: - Контроллер

    private var controllerCard: some View {
        Card(title: "Контроллер", icon: "dot.radiowaves.left.and.right") {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.accentColor.opacity(0.10))
                        .frame(width: 54, height: 54)
                    Image(systemName: "gamecontroller")
                        .font(.system(size: 26))
                        .foregroundStyle(.tint)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(model.bluetoothDevice?.product ?? "DualShock 4")
                        .font(.body.weight(.semibold))
                    Text(model.controllerSubtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text(scanText)
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                }

                Spacer()

                if model.status == .searching || model.status == .waiting {
                    ProgressView()
                        .controlSize(.small)
                }

                Button {
                    model.checkNow()
                } label: {
                    Label("Проверить", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }

            if let usb = model.usbDevice, model.bluetoothDevice == nil {
                Label("Подключён по USB (\(usb.vidPID)). Звук в динамик работает только по Bluetooth.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(.top, 2)
            }
        }
    }

    private var scanText: String {
        guard let lastScan = model.lastScan else {
            return "Сканирую каждые 5 секунд"
        }
        return "Проверка \(lastScan.formatted(date: .omitted, time: .standard)) · каждые 5 с"
    }

    // MARK: - Громкость

    private var volumeCard: some View {
        Card(title: "Громкость динамика", icon: "speaker.wave.3.fill") {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(model.volumePercent)%")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .contentTransition(.numericText())
                Text(model.volumeHex)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("0x00…0x4F")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Slider(
                value: Binding(
                    get: { model.volume },
                    set: { model.setVolume($0) }
                ),
                in: 0 ... 1
            )

            HStack(spacing: 8) {
                ForEach([30, 60, 80, 100], id: \.self) { percent in
                    Button("\(percent)%") {
                        model.setVolume(Double(percent) / 100.0)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Spacer()
                Text(model.isStreaming ? "Применяется на лету" : "Применится при старте потока")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Системный звук

    private var systemAudioCard: some View {
        Card(title: "Системный звук", icon: "display") {
            Toggle(isOn: Binding(
                get: { model.systemAudioEnabled },
                set: { model.setSystemAudioEnabled($0) }
            )) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Вывод системы → DualShock 4")
                        .font(.body.weight(.medium))
                    Text("Системное аудиоустройство будет называться «DualShock 4».")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .disabled(!model.canEnableSystemAudio && !model.systemAudioEnabled)

            Divider()

            VStack(spacing: 8) {
                infoRow("Вывод системы", model.currentOutputName)
                infoRow("Устройство DS4", model.routerReady
                    ? "DualShock 4"
                    : (model.driverInstalled ? "не загружено" : "драйвер не установлен"))
                infoRow("Захват", model.captureDeviceName ?? "DualShock 4 (нет устройства)")
            }

            Button {
                model.openSetup()
            } label: {
                Label("Настройка…", systemImage: "gearshape")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)

            if !model.routerReady {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Аудиодрайвер «DualShock 4» не установлен",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                    Text("Драйвер создаёт виртуальное loopback-устройство, через которое системный звук попадает в динамик геймпада. Установка требуется один раз.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        model.installDriver()
                    } label: {
                        if model.isInstallingDriver {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Установка…")
                            }
                        } else {
                            Label("Установить драйвер…", systemImage: "arrow.down.circle")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(model.isInstallingDriver)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            if model.systemAudioEnabled {
                if model.isStreaming {
                    Label("Поток активен", systemImage: "waveform")
                        .font(.callout)
                        .foregroundStyle(.green)
                } else if model.waitingForController {
                    Label("Жду контроллер — поток запустится автоматически", systemImage: "hourglass")
                        .font(.callout)
                        .foregroundStyle(.orange)
                } else if model.restartSuspended {
                    Label("Автозапуск приостановлен после ошибок", systemImage: "pause.circle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }

            Text("Цепочка: приложения → «DualShock 4» (loopback) → SBC 16 кГц → Bluetooth → динамик.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Ошибка и журнал

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Повторить запуск") {
                    model.retryStream()
                }
                .buttonStyle(.link)
                .font(.callout)
            }
            Spacer(minLength: 8)
            Button {
                model.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Скрыть")
        }
        .padding(12)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.20)))
    }

    private var logCard: some View {
        Card(title: "Журнал", icon: "terminal") {
            HStack(spacing: 8) {
                Text(model.lastLogLine.isEmpty ? "Пока пусто" : model.lastLogLine)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Очистить") {
                    model.clearLog()
                }
                .buttonStyle(.link)
                .font(.caption)
            }

            DisclosureGroup(isExpanded: $showLog) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(model.logLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 10.5, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(8)
                }
                .frame(height: 170)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.55),
                            in: RoundedRectangle(cornerRadius: 8))
            } label: {
                Text("Подробный журнал (\(model.logLines.count))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.callout.weight(.medium))
                .multilineTextAlignment(.trailing)
        }
    }

    private var statusColor: Color {
        switch model.status {
        case .streaming: return .green
        case .connected: return .blue
        case .waiting: return .orange
        case .usbOnly: return .orange
        case .error: return .red
        case .searching: return .secondary
        }
    }
}

// MARK: - Карточка

private struct Card<Content: View>: View {
    let title: String
    let icon: String
    let content: Content

    init(title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.primary.opacity(0.07))
        )
    }
}
