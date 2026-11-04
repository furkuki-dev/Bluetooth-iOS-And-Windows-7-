import SwiftUI

struct ContentView: View {
    enum Mode: String, CaseIterable {
        case send = "Отправить"
        case receive = "Принять"
    }

    @StateObject private var sender = SenderModel()
    @StateObject private var receiver = ReceiverModel()
    @Environment(\.scenePhase) private var scenePhase

    @State private var mode: Mode = .send

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Picker("Режим", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                if mode == .send {
                    sendPanel
                } else {
                    receivePanel
                }
            }
            .padding()
            .navigationTitle("BT Share")
            .onAppear { activate(mode) }
            .onChange(of: mode) { newMode in activate(newMode) }
            .onChange(of: scenePhase) { phase in
                if phase == .active {
                    activate(mode)
                } else {
                    sender.stopListening()
                    receiver.stop()
                }
            }
        }
    }

    private func activate(_ newMode: Mode) {
        if newMode == .send {
            receiver.stop()
            sender.startListening()
        } else {
            sender.stopListening()
            receiver.start()
        }
    }

    // MARK: - Отправка

    private var sendPanel: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Устройства рядом")
                    .font(.headline)
                Spacer()
                Button {
                    sender.clearDevices()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(sender.isSending)
            }

            if sender.devices.isEmpty {
                if sender.isListening {
                    ProgressView()
                }
                Text("Откройте «Принять» на другом устройстве. Обе стороны в одной Wi-Fi сети. Если устройства не видны: Настройки → BT Share → Локальная сеть, включите доступ.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
            } else {
                List(sender.devices) { device in
                    Button {
                        pick(for: device)
                    } label: {
                        HStack {
                            Image(systemName: "laptopcomputer.and.iphone")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name)
                                Text(device.ip)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(sender.isSending)
                }
                .listStyle(.plain)
            }

            if sender.isSending {
                ProgressView(value: sender.progress)
                Text(sender.speed)
                    .font(.caption)
            }

            Text(sender.status)
                .font(.subheadline)
                .multilineTextAlignment(.center)
        }
    }

    /// Выбор устройства открывает выбор файлов, после выбора файлы уходят на него
    private func pick(for device: NearbyDevice) {
        DocPicker.present { urls in
            sender.send(files: urls, to: device)
        }
    }

    // MARK: - Приём

    private var receivePanel: some View {
        VStack(spacing: 16) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 56))
                .foregroundStyle(.blue)

            Text(receiver.status)
                .multilineTextAlignment(.center)

            Text("Держите приложение открытым и экран включённым, пока идёт приём.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if receiver.progress > 0 && receiver.progress < 1 {
                ProgressView(value: receiver.progress)
            }

            ForEach(receiver.received, id: \.self) { url in
                ShareLink(item: url) {
                    Label(url.lastPathComponent, systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
            }

            Spacer()
        }
    }
}
