import Foundation

/// Version 1 of the newline-delimited BLE protocol. Distances are centimetres.
struct Telemetry: Codable, Equatable {
    let v: Int
    let seq: UInt32
    let cm: Double?
    let closing: Double?
    let eta: Double?
    let warning: Bool
    let mpu: Bool
    let ax: Int?
    let ay: Int?
    let az: Int?
    let walk: Bool?

    var isValid: Bool {
        guard v == 1 else { return false }
        if let cm, !cm.isFinite || !(2...600).contains(cm) { return false }
        if let closing, !closing.isFinite || abs(closing) > 10_000 { return false }
        if let eta, !eta.isFinite || eta < 0 || eta > 3600 { return false }
        if cm == nil && (warning || closing != nil || eta != nil) { return false }
        if eta != nil && closing == nil { return false }
        let axes = [ax, ay, az]
        if mpu && axes.contains(where: { $0 == nil }) { return false }
        return axes.compactMap { $0 }.allSatisfy { (-32768...32767).contains($0) }
    }

    /// Raw accelerometer magnitude; not a fall or gait classification.
    var accelerationG: Double? {
        guard mpu, let ax, let ay, let az else { return nil }
        // Current firmware configures the MPU6050 at +/-8 g (4096 LSB/g).
        let x = Double(ax) / 4096
        let y = Double(ay) / 4096
        let z = Double(az) / 4096
        return sqrt(x * x + y * y + z * z)
    }

    static func decode(_ data: Data) -> Telemetry? {
        guard let value = try? JSONDecoder().decode(Telemetry.self, from: data), value.isValid else {
            return nil
        }
        return value
    }
}

/// Firmware-originated ML summaries. These are experimental cues, not diagnoses.
struct FirmwareEvent: Decodable {
    let event: String
    let steps_ahead: Int?
    let confidence: Double?
    let expected_mm: Int?
    let predicted: Bool?
    let eta_s: Double?
    let stride_s: Double?
    let landmarks: Int?
    let z: Double?
}

enum LearningVoiceCue: Equatable {
    case route, gait
}

/// BLE can split a JSON line at any byte. Never decode individual notifications.
struct LineBuffer {
    private var bytes = Data()
    private var discarding = false
    let limit = 1024

    mutating func append(_ fragment: Data) -> [Data] {
        var lines: [Data] = []
        for byte in fragment {
            if byte == 10 {
                if !discarding && !bytes.isEmpty { lines.append(bytes) }
                bytes.removeAll(keepingCapacity: true)
                discarding = false
            } else if !discarding {
                if bytes.count >= limit {
                    bytes.removeAll(keepingCapacity: true)
                    discarding = true
                } else if byte != 13 {
                    bytes.append(byte)
                }
            }
        }
        return lines
    }

    mutating func reset() {
        bytes.removeAll(keepingCapacity: true)
        discarding = false
    }
}

enum DemoScenario: String, CaseIterable, Identifiable {
    case open = "Distant object"
    case approaching = "Approaching"
    case near = "Close obstacle"
    case noEcho = "No echo"

    var id: String { rawValue }

    func sample(sequence: UInt32, tick: Double) -> Telemetry {
        let distance: Double?
        let speed: Double?
        let eta: Double?
        let warning: Bool
        switch self {
        case .open:
            distance = 210 + 4 * sin(tick)
            speed = 0
            eta = nil
            warning = false
        case .approaching:
            distance = 115 + 6 * sin(tick)
            speed = 45
            eta = (distance! - 55) / 45
            warning = true
        case .near:
            distance = 28 + 2 * sin(tick)
            speed = 0
            eta = nil
            warning = true
        case .noEcho:
            distance = nil
            speed = nil
            eta = nil
            warning = false
        }
        return Telemetry(v: 1, seq: sequence, cm: distance, closing: speed, eta: eta,
                         warning: warning, mpu: true, ax: Int(250 * sin(tick)),
                         ay: Int(180 * cos(tick)), az: 4096, walk: false)
    }
}

struct DistancePoint: Identifiable {
    let id = UUID()
    let timestamp: Date
    let cm: Double?
    let warning: Bool
    let segment: Int
}

struct SessionEvent: Identifiable {
    let id = UUID()
    let timestamp = Date()
    let message: String
}

enum AlertState: Equatable {
    case idle, waiting, normal, obstacle, unavailable, stale
}
