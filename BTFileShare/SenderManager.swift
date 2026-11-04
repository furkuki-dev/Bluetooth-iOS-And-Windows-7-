import CoreBluetooth
import Foundation

final class SenderManager: NSObject, ObservableObject {
    @Published var status = "Выберите файл"
    @Published var progress: Double = 0
    @Published var isBusy = false

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var characteristic: CBCharacteristic?

    private var fileData = Data()
    private var fileName = ""
    private var offset = 0
    private var chunkSize = 100
    private var headerSent = false
    private var endSent = false

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func send(data: Data, name: String) {
        guard !isBusy else { return }
        guard !data.isEmpty else { status = "Файл пустой"; return }
        guard central.state == .poweredOn else { status = "Включите Bluetooth"; return }

        fileData = data
        fileName = name
        offset = 0
        headerSent = false
        endSent = false
        progress = 0
        isBusy = true
        status = "Поиск получателя…"

        central.scanForPeripherals(withServices: [BTConstants.serviceUUID], options: nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self = self, self.isBusy, self.peripheral == nil else { return }
            self.fail("Получатель не найден")
        }
    }

    private func fail(_ message: String) {
        central.stopScan()
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        characteristic = nil
        isBusy = false
        status = message
    }

    private func finishSuccess() {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        characteristic = nil
        isBusy = false
        progress = 1
        status = "Файл «\(fileName)» отправлен"
    }

    /// Отправляет следующий пакет. Вызывается из didWriteValueFor,
    /// поэтому запись идёт строго по одному пакету (write with response).
    private func sendNext() {
        guard let p = peripheral, let ch = characteristic else { return }

        let packet: Data
        if !headerSent {
            guard let json = try? JSONEncoder().encode(FileHeader(name: fileName, size: fileData.count)) else {
                fail("Ошибка заголовка")
                return
            }
            packet = makePacket(.header, json)
            headerSent = true
        } else if offset < fileData.count {
            let end = min(offset + chunkSize, fileData.count)
            packet = makePacket(.data, fileData[offset..<end])
            offset = end
            progress = Double(offset) / Double(fileData.count)
        } else if !endSent {
            packet = makePacket(.end)
            endSent = true
        } else {
            finishSuccess()
            return
        }

        p.writeValue(packet, for: ch, type: .withResponse)
    }
}

// MARK: - CBCentralManagerDelegate

extension SenderManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn && isBusy {
            fail("Bluetooth выключен")
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        status = "Подключение…"
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        status = "Поиск сервиса…"
        peripheral.discoverServices([BTConstants.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        fail("Не удалось подключиться")
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        if isBusy { fail("Соединение разорвано") }
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
        // Один байт уходит на тип пакета
        chunkSize = max(20, peripheral.maximumWriteValueLength(for: .withResponse) - 1)
        status = "Отправка…"
        sendNext()
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error = error {
            fail("Ошибка записи: \(error.localizedDescription)")
            return
        }
        sendNext()
    }
}
