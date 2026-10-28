import Foundation
import Combine
import CoreBluetooth

/// All callbacks run on the main queue. This prototype is intentionally foreground-only.
final class BluetoothManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    struct Device: Identifiable {
        let peripheral: CBPeripheral
        var rssi: Int
        var id: UUID { peripheral.identifier }
        var name: String { peripheral.name ?? "PathAhead device" }
    }

    static let serviceID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    static let writeID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    static let notifyID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")

    @Published private(set) var devices: [Device] = []
    @Published private(set) var status = "Ready to connect"
    @Published private(set) var isScanning = false
    @Published private(set) var isConnected = false
    @Published private(set) var isConnecting = false
    @Published private(set) var isDemo = false
    @Published private(set) var telemetry: Telemetry?
    @Published private(set) var isWalkActive = false
    @Published private(set) var gaitStatus = "Start a supervised walk to begin learning"
    @Published private(set) var learnedLandmarks = 0
    @Published private(set) var latestLearningMessage: String?
    @Published private(set) var learningVoiceCue: LearningVoiceCue?
    @Published private(set) var supportsWalkControls = false
    @Published private(set) var walkControlStatus = "Connect the ESP32 to enable learning controls"
    @Published private(set) var lastReceived: Date?
    @Published private(set) var alert: AlertState = .idle
    @Published private(set) var history: [DistancePoint] = []
    @Published private(set) var events: [SessionEvent] = []
    @Published var demoScenario: DemoScenario = .open

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var lineBuffer = LineBuffer()
    private var tickTimer: Timer?
    private var operationTimeout: DispatchWorkItem?
    private var shouldScan = false
    private var lastSequence: UInt32?
    private var connectedAt: Date?
    private var noEchoSince: Date?
    private var segment = 0
    private var demoSequence: UInt32 = 0
    private var demoTick = 0.0

    override init() {
        super.init()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    deinit {
        tickTimer?.invalidate()
        operationTimeout?.cancel()
    }

    func scan() {
        disconnect(log: false)
        devices = []
        #if targetEnvironment(simulator)
        status = "Use Demo on Simulator. Connect the ESP32 using your iPhone."
        return
        #else
        shouldScan = true
        status = "Checking Bluetooth…"
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
        } else {
            beginScanIfReady()
        }
        #endif
    }

    private func beginScanIfReady() {
        guard shouldScan, let central else { return }
        guard central.state == .poweredOn else {
            updateBluetoothStatus(central.state)
            return
        }
        isScanning = true
        status = "Searching for your cane…"
        central.scanForPeripherals(withServices: [Self.serviceID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        setTimeout(seconds: 12) { [weak self] in
            guard let self else { return }
            self.stopScanning()
            self.status = self.devices.isEmpty
                ? "No cane found. Power the ESP32 and upload the BLE sketch."
                : "Choose your cane below."
        }
    }

    func stopScanning() {
        shouldScan = false
        central?.stopScan()
        isScanning = false
        operationTimeout?.cancel()
    }

    func connect(_ device: Device) {
        stopScanning()
        guard let central, central.state == .poweredOn else { return }
        clearReadings()
        peripheral = device.peripheral
        peripheral?.delegate = self
        isConnecting = true
        status = "Connecting to \(device.name)…"
        alert = .waiting
        central.connect(device.peripheral, options: nil)
        setTimeout(seconds: 15) { [weak self] in
            self?.failConnection("Connection timed out. Move closer and try again.")
        }
    }

    func disconnect(log: Bool = true) {
        stopScanning()
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral?.delegate = nil
        peripheral = nil
        writeCharacteristic = nil
        let wasActive = isConnected || isDemo || isConnecting
        isConnected = false
        isConnecting = false
        isDemo = false
        clearReadings()
        status = "Ready to connect"
        if log && wasActive { addEvent("Session ended") }
    }

    func startDemo() {
        disconnect(log: false)
        events = []
        demoSequence = 0
        demoTick = 0
        demoScenario = .open
        isDemo = true
        status = "Demo · simulated readings"
        addEvent("Demo started — no hardware connected")
        tick()
    }

    func startWalk() { sendCommand("START") }
    func endWalk() { sendCommand("END") }
    func resetGaitBaseline() { sendCommand("RESET") }

    private func sendCommand(_ command: String) {
        guard isConnected, let peripheral else {
            walkControlStatus = "Connect the ESP32 to enable learning controls"
            return
        }
        guard supportsWalkControls, let writeCharacteristic,
              writeCharacteristic.properties.contains(.write) else {
            walkControlStatus = "Firmware update needed: upload the new PathAheadBLE sketch to enable this button."
            return
        }
        peripheral.writeValue(Data((command + "\n").utf8), for: writeCharacteristic, type: .withResponse)
        walkControlStatus = command == "START" ? "Starting learning walk…" : command == "END" ? "Saving walk…" : "Resetting rhythm baseline…"
    }

    func pauseForBackground() {
        if isConnected || isConnecting || isScanning || isDemo {
            disconnect(log: false)
            status = "Paused. Reconnect while this app stays open."
            addEvent("Monitoring paused when app left the foreground")
        }
    }

    private func tick() {
        if isDemo {
            demoSequence &+= 1
            demoTick += 0.25
            accept(demoScenario.sample(sequence: demoSequence, tick: demoTick))
        } else if isConnected {
            let reference = lastReceived ?? connectedAt ?? Date()
            if Date().timeIntervalSince(reference) > 2 && alert != .stale {
                telemetry = nil
                segment += 1
                setAlert(.stale)
                status = "Connected, but readings have stopped"
            }
        }
    }

    private func accept(_ value: Telemetry) {
        guard value.isValid, value.seq != lastSequence else { return }
        lastSequence = value.seq
        telemetry = value
        if let walkActive = value.walk {
            isWalkActive = walkActive
            if walkActive { walkControlStatus = "Walk active · keep using your usual cane technique" }
            else if supportsWalkControls { walkControlStatus = "ESP32 controls ready" }
        }
        lastReceived = Date()
        if isConnected { status = "Cane connected · live readings" }
        if value.cm == nil {
            if noEchoSince == nil { noEchoSince = Date(); segment += 1 }
            // Initial median fill can take a few readings. Do not announce a fault for that.
            setAlert(Date().timeIntervalSince(noEchoSince!) > 0.8 ? .unavailable : .waiting)
        } else {
            noEchoSince = nil
            setAlert(value.warning ? .obstacle : .normal)
        }
        history.append(DistancePoint(timestamp: Date(), cm: value.cm, warning: value.warning, segment: segment))
        if history.count > 80 { history.removeFirst(history.count - 80) }
    }

    private func clearReadings() {
        writeCharacteristic = nil
        telemetry = nil
        lastReceived = nil
        connectedAt = nil
        noEchoSince = nil
        lastSequence = nil
        lineBuffer.reset()
        history = []
        segment = 0
        alert = .idle
        isWalkActive = false
        gaitStatus = "Start a supervised walk to begin learning"
        learnedLandmarks = 0
        latestLearningMessage = nil
        learningVoiceCue = nil
        supportsWalkControls = false
        walkControlStatus = "Connect the ESP32 to enable learning controls"
    }

    private func setAlert(_ next: AlertState) {
        guard alert != next else { return }
        alert = next
        switch next {
        case .obstacle: addEvent("Obstacle warning")
        case .unavailable: addEvent("No valid distance reading")
        case .stale: addEvent("Readings stopped — connection may be interrupted")
        case .normal: addEvent("Distance readings available · no threshold alert")
        default: break
        }
    }

    private func addEvent(_ message: String) {
        events.insert(SessionEvent(message: message), at: 0)
        if events.count > 30 { events.removeLast(events.count - 30) }
    }

    private func setTimeout(seconds: Double, action: @escaping () -> Void) {
        operationTimeout?.cancel()
        let work = DispatchWorkItem(block: action)
        operationTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func failConnection(_ message: String) {
        disconnect(log: false)
        status = message
        addEvent(message)
    }

    private func updateBluetoothStatus(_ state: CBManagerState) {
        switch state {
        case .poweredOn: break
        case .poweredOff: status = "Bluetooth is off. Turn it on in iPhone Settings."
        case .unauthorized: status = "Allow Bluetooth for PathAhead in iPhone Settings."
        case .unsupported: status = "Bluetooth is unavailable here. Use Demo or a physical iPhone."
        case .resetting: status = "Bluetooth is restarting. Try again shortly."
        default: status = "Waiting for Bluetooth…"
        }
    }

    // MARK: Core Bluetooth (callbacks delivered on .main)

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            beginScanIfReady()
        } else {
            let wantedScan = shouldScan
            disconnect(log: false)
            shouldScan = wantedScan && central.state == .unknown
            updateBluetoothStatus(central.state)
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard isScanning else { return }
        if let index = devices.firstIndex(where: { $0.id == peripheral.identifier }) {
            devices[index].rssi = RSSI.intValue
        } else {
            devices.append(Device(peripheral: peripheral, rssi: RSSI.intValue))
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral.identifier == self.peripheral?.identifier, isConnecting else { return }
        status = "Reading cane services…"
        peripheral.discoverServices([Self.serviceID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        failConnection("Could not connect. Check the ESP32 and try again.")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        failConnection("Cane disconnected. Tap Connect cane to reconnect.")
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.serviceID }) else {
            failConnection("PathAhead service not found. Check the firmware.")
            return
        }
        peripheral.discoverCharacteristics([Self.notifyID, Self.writeID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        guard error == nil, let characteristic = service.characteristics?.first(where: { $0.uuid == Self.notifyID }),
              characteristic.properties.contains(.notify) else {
            failConnection("Cane notifications unavailable. Check the firmware.")
            return
        }
        writeCharacteristic = service.characteristics?.first(where: { $0.uuid == Self.writeID })
        supportsWalkControls = writeCharacteristic?.properties.contains(.write) == true
        if !supportsWalkControls {
            walkControlStatus = "Firmware update needed: upload the new PathAheadBLE sketch to enable this button."
        } else {
            walkControlStatus = "ESP32 controls ready"
        }
        peripheral.setNotifyValue(true, for: characteristic)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral.identifier == self.peripheral?.identifier, characteristic.uuid == Self.notifyID else { return }
        guard error == nil, characteristic.isNotifying else {
            failConnection("Could not start sensor readings. Try reconnecting.")
            return
        }
        operationTimeout?.cancel()
        isConnecting = false
        isConnected = true
        connectedAt = Date()
        status = "Connected · waiting for first reading"
        alert = .waiting
        addEvent("ESP32 connected over Bluetooth")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard isConnected, peripheral.identifier == self.peripheral?.identifier,
              characteristic.uuid == Self.notifyID, error == nil, let bytes = characteristic.value else { return }
        for line in lineBuffer.append(bytes) {
            if let reading = Telemetry.decode(line) {
                accept(reading)
            } else if let message = try? JSONDecoder().decode(FirmwareEvent.self, from: line) {
                accept(message)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral.identifier == self.peripheral?.identifier, characteristic.uuid == Self.writeID else { return }
        if error != nil {
            walkControlStatus = "Command did not reach the ESP32. Reconnect and try again."
        } else {
            walkControlStatus = "Command sent · waiting for ESP32 confirmation"
        }
    }

    private func accept(_ message: FirmwareEvent) {
        switch message.event {
        case "walk_start":
            isWalkActive = true
            gaitStatus = "Learning your walking rhythm · keep a steady pace"
            walkControlStatus = "Walk active · keep using your usual cane technique"
            addEvent("Learning walk started")
        case "walk_end":
            isWalkActive = false
            if let landmarks = message.landmarks { learnedLandmarks = landmarks }
            gaitStatus = "Walk saved · \(learnedLandmarks) route cues remembered"
            walkControlStatus = "Walk saved"
            addEvent("Walk saved · route learning updated")
        case "baseline_ready":
            gaitStatus = "Personal rhythm baseline ready"
            addEvent("Personal walking rhythm learned")
        case "baseline_reset":
            gaitStatus = "Baseline cleared · start walking to learn again"
            walkControlStatus = "Rhythm baseline reset"
            addEvent("Walking baseline reset")
        case "gait_drift":
            latestLearningMessage = "Your walking rhythm differs from your learned baseline. Pause if needed."
            learningVoiceCue = .gait
            addEvent("Walking rhythm changed · experimental cue")
        case "stumble_risk":
            latestLearningMessage = "An unusual cane-tap interval was detected. This is not a fall detector."
            learningVoiceCue = .gait
            addEvent("Unusual cane-tap timing · experimental cue")
        case "route_hazard":
            let steps = message.steps_ahead.map { " about \($0) taps ahead" } ?? " ahead"
            latestLearningMessage = "A previously learned route obstacle may be\(steps)."
            learningVoiceCue = .route
            addEvent("Learned route obstacle may be\(steps)")
        case "route_changed":
            latestLearningMessage = "A familiar route cue appears to have changed."
            addEvent("Familiar route cue changed")
        case "route_confirmed":
            latestLearningMessage = "A familiar route cue was seen again."
            addEvent("Familiar route cue confirmed")
        case "new_obstacle":
            addEvent("New route obstacle observed for learning")
        case "obstacle_eta":
            latestLearningMessage = "Obstacle closing quickly · use your usual mobility technique."
            addEvent("Approaching obstacle cue · experimental estimate")
        default:
            break
        }
    }
}
