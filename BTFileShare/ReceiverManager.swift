import CoreBluetooth
import Foundation

final class ReceiverManager: NSObject, ObservableObject {
    @Published var status = "Выключено"
    @Published var progress: Double = 0
    @Published var receivedURL: URL?

    private var manager: CBPeripheralManager!
    private var wantsRunning = false
    private var buffer = Data()
    private var expectedSize = 0
    private var fileName = ""

    override init() {
        super.init()
        manager = CBPeripheralManager(delegate: self, queue: .main)
    }

    func start() {
        wantsRunning = true
        receivedURL = nil
        progress = 0
        status = "Ожидание…"
        if manager.state == .poweredOn { setupService() }
    }

    func stop() {
        wantsRunning = false
        manager.stopAdvertising()
        manager.removeAllServices()
        status = "Выключено"
        progress = 0
    }

    private func setupService() {
        manager.removeAllServices()
        let characteristic = CBMutableCharacteristic(
            type: BTConstants.transferUUID,
            properties: [.write],
            value: nil,
            permissions: [.writeable]
        )
        let service = CBMutableService(type: BTConstants.serviceUUID, primary: true)
        service.characteristics = [characteristic]
        manager.add(service)
    }

    /// Возвращает false, если пакет некорректный.
    private func handle(_ packet: Data) -> Bool {
        guard let typeByte = packet.first, let type = PacketType(rawValue: typeByte) else { return false }
        let body = packet.dropFirst()

        switch type {
        case .header:
            guard let header = try? JSONDecoder().decode(FileHeader.self, from: body) else { return false }
            fileName = header.name.isEmpty ? "file.bin" : (header.name as NSString).lastPathComponent
            expectedSize = header.size
            buffer = Data()
            buffer.reserveCapacity(header.size)
            progress = 0
            status = "Получение «\(fileName)»…"
            return true

        case .data:
            buffer.append(body)
            if expectedSize > 0 {
                progress = Double(buffer.count) / Double(expectedSize)
            }
            return true

        case .end:
            return saveFile()
        }
    }

    private func saveFile() -> Bool {
        defer { buffer = Data() }

        guard buffer.count == expectedSize else {
            progress = 0
            status = "Ошибка: размер файла не совпадает"
            return false
        }

        do {
            let docs = try FileManager.default.url(for: .documentDirectory,
                                                   in: .userDomainMask,
                                                   appropriateFor: nil,
                                                   create: true)
            let dir = docs.appendingPathComponent("Received", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            var url = dir.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: url.path) {
                url = dir.appendingPathComponent("\(Int(Date().timeIntervalSince1970))_\(fileName)")
            }
            try buffer.write(to: url)

            receivedURL = url
            progress = 1
            status = "Получен «\(fileName)»"
            return true
        } catch {
            status = "Ошибка сохранения: \(error.localizedDescription)"
            return false
        }
    }
}

// MARK: - CBPeripheralManagerDelegate

extension ReceiverManager: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            if wantsRunning { setupService() }
        case .poweredOff:
            status = "Включите Bluetooth"
        case .unauthorized:
            status = "Нет доступа к Bluetooth в настройках"
        default:
            break
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didAdd service: CBService,
                           error: Error?) {
        if let error = error {
            status = "Ошибка сервиса: \(error.localizedDescription)"
            return
        }
        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [BTConstants.serviceUUID],
            CBAdvertisementDataLocalNameKey: "BTShare"
        ])
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error = error {
            status = "Ошибка рекламы: \(error.localizedDescription)"
        } else {
            status = "Ожидание отправителя…"
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            guard let value = request.value, handle(value) else {
                peripheral.respond(to: request, withResult: .unlikelyError)
                continue
            }
            peripheral.respond(to: request, withResult: .success)
        }
    }
}
