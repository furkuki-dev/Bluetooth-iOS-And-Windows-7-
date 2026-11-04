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
            // Импортер на корневом view, а не внутри условной ветки
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.data],
                allowsMultipleSelection: false
            ) { result in
                handleImport(result)
            }
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
                loadError = nil
                showImporter = true
            } label: {
                Label(pickedName ?? "Выбрать файл", systemImage: "doc")
                    .lineLimit(1)
            }
            .buttonStyle(.bordered)
            .disabled(sender.isBusy)

            if let loadError {
                Text(loadError)
                    .foregroundStyle(.red)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
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

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            loadError = "Выбор не выполнен: \(error.localizedDescription)"
        case .success(let urls):
            guard let url = urls.first else { return }
            readFile(at: url)
        }
    }

    private func readFile(at url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        var coordError: NSError?
        var data: Data?
        var readError: Error?

        // Координатор нужен для файлов iCloud Drive, которые могут быть не загружены локально
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { newURL in
            do {
                data = try Data(contentsOf: newURL)
            } catch {
                readError = error
            }
        }

        if let error = coordError ?? readError {
            loadError = "Не удалось прочитать файл: \(error.localizedDescription)"
            return
        }
        guard let data, !data.isEmpty else {
            loadError = "Файл пустой или недоступен"
            return
        }

        pickedData = data
        pickedName = url.lastPathComponent
        loadError = nil
    }
}
