import SwiftUI
import UIKit

struct ContentView: View {
    enum Mode: String, CaseIterable {
        case send = "Отправить"
        case receive = "Принять"
    }

    @StateObject private var sender = SenderManager()
    @StateObject private var receiver = ReceiverManager()

    @State private var mode: Mode = .send
    @State private var message: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
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
            .onDisappear {
                receiver.stop()
                sender.stopScan()
            }
        }
    }

    private func activate(_ newMode: Mode) {
        if newMode == .send {
            receiver.stop()
            sender.startScan()
        } else {
            sender.stopScan()
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
                    message = nil
                    sender.startScan()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(sender.isSending)
            }

            if sender.devices.isEmpty {
                if sender.isScanning {
                    ProgressView()
                }
                Text("Попросите получателя открыть режим «Принять»")
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
                            Image(systemName: "iphone")
                            Text(device.name)
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
            }

            if let message {
                Text(message)
                    .foregroundStyle(.red)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
            }

            Text(sender.status)
                .font(.subheadline)
                .multilineTextAlignment(.center)
        }
    }

    /// Выбор телефона открывает выбор файлов, после выбора файлы уходят на этот телефон
    private func pick(for device: NearbyDevice) {
        message = nil
        DocPicker.present { urls in
            guard !urls.isEmpty else { return }
            if let files = readFiles(urls) {
                sender.send(files: files, to: device)
            }
        }
    }

    private func readFiles(_ urls: [URL]) -> [(name: String, data: Data)]? {
        var result: [(name: String, data: Data)] = []
        for url in urls {
            do {
                let data = try Data(contentsOf: url)
                result.append((name: url.lastPathComponent, data: data))
            } catch {
                message = "Не удалось прочитать «\(url.lastPathComponent)»"
                return nil
            }
        }
        return result
    }

    // MARK: - Приём

    private var receivePanel: some View {
        VStack(spacing: 16) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 56))
                .foregroundStyle(.blue)

            Text(receiver.status)
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

// MARK: - Системный выбор файлов через UIKit

enum DocPicker {
    // Держим делегат, пока открыт пикер
    private static var delegate: Delegate?

    static func present(_ onPick: @escaping ([URL]) -> Void) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
              let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first,
              var top = window.rootViewController else { return }
        while let presented = top.presentedViewController {
            top = presented
        }

        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true

        let d = Delegate(onPick)
        delegate = d
        picker.delegate = d
        top.present(picker, animated: true)
    }

    private final class Delegate: NSObject, UIDocumentPickerDelegate {
        let handler: ([URL]) -> Void

        init(_ handler: @escaping ([URL]) -> Void) {
            self.handler = handler
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            handler(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            handler([])
        }
    }
}
