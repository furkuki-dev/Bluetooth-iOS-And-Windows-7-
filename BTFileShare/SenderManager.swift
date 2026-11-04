import CoreBluetooth
import Foundation

struct NearbyDevice: Identifiable {
    let id: UUID
    let name: String
    let peripheral: CBPeripheral
}

final class SenderManager: NSObject, ObservableObject {
    @Published var status = "Ожидание Bluetooth…"
    @Published var devices: [NearbyDevice] = []
    @Published var isScanning = false
    @Published var isSending = false
    @Published var progress: Double = 0

    private var central: CBCentralManager!
    private var wantsScan = false

    private var target: CBPeripheral?
    private var characteristic: CBCharacteristic?
    private var attemptID: UUID?

    private var queue: [(name: String, data: Data)] = []
    private var fileIndex = 0
    private var offset = 0
    private var phase: Phase = .header
    private var totalBytes = 0
    private var sentBytes = 0
    private var chunkSize = 100

    private enum Phase { case header, data }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - Публичный API

    func startScan() {
        wantsScan = true
        guard central.state == .poweredOn else {
            status = "Включите Bluetooth"
            return
        }
        if !isSending { status = "Поиск устройств…" }
        beginScan()
    }

    func stopScan() {
        wantsScan = false
        central.stopScan()
        isScanning = false
    }

    func send(files: [(name: String, data: Data)], to device: NearbyDevice) {
        guard !isSending else { return }
        guard central.state == .poweredOn else { status = "Включите Bluetooth"; return }

        let nonEmpty = files.filter { !$0.data.isEmpty }
        guard !nonEmpty.isEmpty else { status = "Файлы пустые"; return }

        // Во время передачи поиск не нужен
        central.stopScan()
        isScanning = false

        queue = nonEmpty
        totalBytes = nonEmpty.reduce(0) { $0 + $1.data.count }
        sentBytes = 0
        fileIndex = 0
        offset = 0
        phase = .header
        progress = 0
        isSending = true
        target = device.peripheral
        characteristic = nil
        device.peripheral.delegate = self
        status = "Подключение к \(device.name)…"
        central.connect(device.peripheral, options: nil)

        // Если устройство не ответило за 20 секунд, сдаёмся
        let attempt = UUID()
        attemptID = attempt
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.isSending, self.attemptID == attempt, self.characteristic == nil else { return }
            self.fail("Устройство не ответило. Проверьте, что на нём открыт режим «Принять»")
        }
    }

    // MARK: - Внутреннее

    private func beginScan() {
        guard central.state == .poweredOn, !isSending else { return }
        central.stopScan()
        devices.removeAll()
        central.scanForPeripherals(withServices: [BTConstants.serviceUUID], options: nil)
        isScanning = true
    }

    private func resetSession() {
        target = nil
        characteristic = nil
        queue = []
        attemptID = nil
        isSending = false
    }

    private func fail(_ message: String) {
        let p = target
        resetSession()
        progress = 0
        status = message
        if let p { central.cancelPeripheralConnection(p) }
        if wantsScan { beginScan() }
    }

    private func finishSuccess() {
        let count = queue.count
        let p = target
        resetSession()
        progress = 1
        status = "Отправлено файлов: \(count)"
        if let p { central.cancelPeripheralConnection(p) }
        if wantsScan { beginScan() }
    }

    /// Отправляет следующий пакет. Вызывается из didWriteValueFor,
    /// поэтому запись идёт строго по одному пакету (write with response).
    private func sendNext() {
        guard let p = target, let ch = characteristic else { return }
        guard fileIndex < queue.count else { finishSuccess(); return }

        let file = queue[fileIndex]
        let packet: Data

        switch phase {
        case .header:
            guard let json = try? JSONEncoder().encode(FileHeader(name: file.name, size: file.data.count)) else {
                fail("Ошибка заголовка")
                return
            }
            packet = makePacket(.header, json)
            phase = .data
            offset = 0
            status = "Отправка «\(file.name)» (\(fileIndex + 1) из \(queue.count))"

        case .data:
            if offset < file.data.count {
                let end = min(offset + chunkSize, file.data.count)
                packet = makePacket(.data, file.data[offset..<end])
                sentBytes += end - offset
                offset = end
                progress = Double(sentBytes) / Double(totalBytes)
            } else {
                packet = makePacket(.end)
                fileIndex += 1
                phase = .header
            }
        }

        p.writeValue(packet, for: ch, type: .withResponse)
    }
}

// MARK: - CBCentralManagerDelegate

extension SenderManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if wantsScan { beginScan() }
        case .poweredOff:
            isScanning = false
            devices.removeAll()
            status = "Включите Bluetooth"
            if isSending { fail("Bluetooth выключен") }
        case .unauthorized:
            status = "Нет доступа к Bluetooth в настройках"
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        guard !devices.contains(where: { $0.id == peripheral.identifier }) else { return }
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name
            ?? "Устройство"
        devices.append(NearbyDevice(id: peripheral.identifier, name: name, peripheral: peripheral))
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        status = "Поиск сервиса…"
        peripheral.discoverServices([BTConstants.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        if isSending { fail("Не удалось подключиться") }
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        if isSending { fail("Соединение разорвано") }
    }
}

// MARK: - CBPeripheralDelegate

extension SenderManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil,
              let service = peripheral.services?.first(where: { $0.uuid == BTConstants.serviceUUID }) else {
            fail("Сервис не найден")
            return
        }
        peripheral.discoverCharacteristics([BTConstants.transferUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard error == nil,
              let ch = service.characteristics?.first(where: { $0.uuid == BTConstants.transferUUID }) else {
            fail("Характеристика не найдена")
            return
        }
        characteristic = ch
        chunkSize = max(20, peripheral.maximumWriteValueLength(for: .withResponse) - 1)
        status = "Отправка…"
        sendNext()
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            fail("Ошибка записи: \(error.localizedDescription)")
            return
        }
        sendNext()
    }
}
