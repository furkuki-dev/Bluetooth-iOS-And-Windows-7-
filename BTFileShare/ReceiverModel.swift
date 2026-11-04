import Foundation
import UIKit

final class ReceiverModel: ObservableObject {
    @Published var status = "Выключено"
    @Published var progress: Double = 0
    @Published var isRunning = false
    @Published var received: [URL] = []

    private let server = TransferServer()
    private let beacon = BeaconSender(name: "iPhone-" + String(UUID().uuidString.prefix(4)))
    private var wantsRunning = false

    func start() {
        guard !isRunning, !wantsRunning else { return }
        wantsRunning = true
        received = []

        server.onStatus = { [weak self] text in self?.status = text }
        server.onProgress = { [weak self] value in self?.progress = value }
        server.onSaved = { [weak self] url in self?.received.append(url) }

        tryStart(attempt: 0)
    }

    func stop() {
        wantsRunning = false
        server.stop()
        beacon.stop()
        isRunning = false
        progress = 0
        status = "Выключено"
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func tryStart(attempt: Int) {
        guard wantsRunning, !isRunning else { return }
        do {
            try server.start()
        } catch {
            // Предыдущий сеанс мог ещё не освободить порт, поэтому пробуем несколько раз
            if attempt < 5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    self?.tryStart(attempt: attempt + 1)
                }
            } else {
                wantsRunning = false
                status = error.localizedDescription
            }
            return
        }
        beacon.start()
        isRunning = true
        status = "Ожидание отправителя…"
        UIApplication.shared.isIdleTimerDisabled = true
    }
}
