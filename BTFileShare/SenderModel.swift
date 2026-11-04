import Foundation
import UIKit

struct NearbyDevice: Identifiable, Hashable {
    var id: String { ip }
    let name: String
    let ip: String
}

final class SenderModel: ObservableObject {
    @Published var devices: [NearbyDevice] = []
    @Published var status = "Выключено"
    @Published var isListening = false
    @Published var isSending = false
    @Published var progress: Double = 0
    @Published var speed = ""

    private let listener = BeaconListener()
    private var seen: [String: (name: String, date: Date)] = [:]
    private var timer: Timer?

    func startListening() {
        guard !isListening else { return }

        listener.onFound = { [weak self] ip, name in
            DispatchQueue.main.async { self?.register(ip: ip, name: name) }
        }

        do {
            try listener.start()
        } catch {
            status = error.localizedDescription
            return
        }

        isListening = true
        status = "Поиск устройств…"
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.pruneDevices()
        }
    }

    func stopListening() {
        listener.stop()
        timer?.invalidate()
        timer = nil
        seen = [:]
        devices = []
        isListening = false
        status = "Выключено"
    }

    func clearDevices() {
        seen = [:]
        devices = []
    }

    func send(files: [URL], to device: NearbyDevice) {
        guard !isSending, !files.isEmpty else { return }
        isSending = true
        progress = 0
        speed = ""
        status = "Отправка на \(device.name)…"
        UIApplication.shared.isIdleTimerDisabled = true

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try TransferClient.send(files: files, toIP: device.ip) { fraction, mbps in
                    DispatchQueue.main.async {
                        self.progress = fraction
                        self.speed = String(format: "%.1f МБ/с", mbps)
                    }
                }
                DispatchQueue.main.async {
                    self.isSending = false
                    self.progress = 1
                    self.speed = ""
                    self.status = "Отправлено файлов: \(files.count)"
                    UIApplication.shared.isIdleTimerDisabled = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.isSending = false
                    self.progress = 0
                    self.speed = ""
                    self.status = error.localizedDescription
                    UIApplication.shared.isIdleTimerDisabled = false
                }
            }
        }
    }

    private func register(ip: String, name: String) {
        seen[ip] = (name: name, date: Date())
        pruneDevices()
    }

    private func pruneDevices() {
        let now = Date()
        seen = seen.filter { now.timeIntervalSince($0.value.date) < 3 }
        devices = seen
            .map { NearbyDevice(name: $0.value.name, ip: $0.key) }
            .sorted { $0.name < $1.name }
    }
}
