import Foundation

/// T2.1 light type. The list lives in `calibration.json` and must match the Photone
/// inventory (T-1) exactly. Never add a guessed factor.
public struct LightType: Hashable, Sendable, Codable, Identifiable {
    public enum Origin: Hashable, Sendable, Codable {
        /// Fitted from a capture under a lamp Dad owns: fLight = reference PPFD / lux.
        case measured(captureDate: String)
        /// Ratio of reference PPFD between light types, same under two test lights.
        case ratioDerived(note: String)
        /// From a cited conversion table.
        case published(citation: String)
    }

    public var id: String
    public var name: String
    public var group: String
    /// µmol·m⁻²·s⁻¹ per lux. nil until a real value exists → PPFD "not calibrated".
    public var fLight: Double?
    public var origin: Origin?
    /// Reef/aquarium list (T2.3) rather than plant list.
    public var reef: Bool

    public init(
        id: String, name: String, group: String, fLight: Double?, origin: Origin?, reef: Bool = false
    ) {
        self.id = id
        self.name = name
        self.group = group
        self.fLight = fLight
        self.origin = origin
        self.reef = reef
    }

    /// Anything not measured on a real lamp shows an "unverified" tag.
    public var isUnverified: Bool {
        if case .measured = origin { return false }
        return true
    }
}
