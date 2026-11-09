import UIKit

enum StylusPressureMode: String, Codable, CaseIterable {
    case automatic = "Automatisch", unavailable = "Ohne Drucksensor", available = "Mit Drucksensor"
}

enum StylusInputPolicy {
    static func drawingTouches(finger: Bool, pencilConnected: Bool) -> [UITouch.TouchType] {
        // Until a Pencil is known, everything writes, the Pencil included: compatible styluses and the
        // USB-C Apple Pencil may never report a pairing.
        if !pencilConnected { return [.pencil, .direct, .indirectPointer] }
        return finger ? [.pencil, .direct, .indirectPointer] : [.pencil]
    }
    static func force(type: UITouch.TouchType, value: CGFloat, maximum: CGFloat, mode: StylusPressureMode) -> CGFloat {
        guard mode != .unavailable, value.isFinite, maximum.isFinite, maximum > 0 else { return 0.5 }
        // USB-C/pressureless styluses report no usable force range. Keep a neutral width instead of treating a sentinel as full pressure.
        guard mode == .available || (type == .pencil && maximum > 1) else { return 0.5 }
        return min(1, max(0, value / maximum))
    }
}
