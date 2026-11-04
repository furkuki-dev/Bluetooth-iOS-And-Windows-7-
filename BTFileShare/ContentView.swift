import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    enum Mode: String, CaseIterable {
        case send = "Отправить"
        case receive = "Принять"
    }

    @StateObject private var sender = SenderManager()
    @StateObject private var receiver = ReceiverManager()

    @State private var mode: Mode = .send
    @State private var showImporter = false
    @State private var pickedName: String?
    @State private var pickedData: Data?
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Picker("Режим", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                if mode == .send {
                    sendPanel
                } else {
                    receivePanel
                }

                Spacer()
            }
            .padding()
            .navigationTitle("BT Share")
            .onChange(of: mode) { newMode in
                if newMode == .receive {
                    receiver.start()
                } else {
                    receiver.stop()
                }
            }
            .onDisappear { receiver.stop() }
        }
    }

    private var sendPanel: some View {
        VStack(spacing: 16) {
            Button {
                showImporter = true
            } label: {
                Label(pickedName ?? "Выбрать файл", systemImage: "doc")
            }
            .buttonStyle(.bordered)
            .disabled(sender.isBusy)

            if let loadError {
                Text(loadError)
                    .foregroundStyle(.red)
                    .font(.footnote)
            }

            Button("Отправить") {
                if let data = pickedData, let name = pickedName {
                    sender.send(data: data, name: name)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(pickedData == nil || sender.isBusy)

            if sender.isBusy {
                ProgressView(value: sender.progress)
            }

            Text(sender.status)
                .font(.subheadline)
                .multilineTextAlignment(.center)
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item]) { result in
            loadFile(result)
        }
    }

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

            if let url = receiver.receivedURL {
                ShareLink(item: url) {
                    Label(url.lastPathComponent, systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func loadFile(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }

            pickedData = try Data(contentsOf: url)
            pickedName = url.lastPathComponent
            loadError = nil
        } catch {
            loadError = "Не удалось прочитать файл"
        }
    }
}
