// Every number marked (P) in photone-feature-spec-v3.md lives here, and only here.
// They are guesses until the T0.0 spike confirms or replaces them.
// Calibration constants (kBase, fLight) are NOT here: see Calibration.swift.

public enum Provisional {
    // T0.0 — go/no-go: neither method within this of Photone → stop and reassess.
    public static let spikeNoGoMaxError = 0.15

    // T0.1 — capture pipeline
    /// Fraction of width/height dropped on each side before averaging.
    public static let frameBorderFraction = 0.10
    /// Not a divisor of 100 or 120, so frames don't lock to mains flicker phase.
    public static let frameRate = 27.0
    /// Second frame rate for the flicker comparison test (also not a divisor of 100/120).
    public static let alternateFrameRate = 23.0
    /// Frames averaged into one reading.
    public static let framesPerReading = 10
    /// Method A exposure ladder spacing, in stops.
    public static let exposureStepStops = 1.0
    /// Device tests: maximum drift over 60 s under steady light.
    public static let maxDrift60s = 0.02
    /// Device tests: max difference between two frame rates under a mains lamp.
    public static let maxFrameRateDifference = 0.02
    /// Device tests: max difference in S between two adjacent exposure steps.
    public static let maxAdjacentStepDifference = 0.02

    // T1.1 — tilt warning threshold, degrees from measuring orientation.
    public static let tiltWarningDegrees = 10.0

    // T2.2 — user calibration stability window.
    public static let calibrationStabilityMaxVariation = 0.02
    public static let calibrationStabilityWindowSeconds = 2.0

    // T7.1 — agreement target.
    public static let agreementMedianMaxError = 0.05
    public static let agreementSingleMaxError = 0.10

    // T7.2 — first reading latency, seconds.
    public static let firstReadingMaxSeconds = 2.0

    // Spike-only knobs (not in the spec; set by T0.0 and then frozen).
    /// Method A: step darker when mean linear signal exceeds this.
    public static let ladderStepDownAbove = 0.60
    /// Method A: step brighter when mean linear signal falls below this.
    /// Must be < stepDownAbove / 2^(2*stepStops) / ... — see ExposureLadder hysteresis check.
    public static let ladderStepUpBelow = 0.10
    /// Fraction of clipped pixels above which a frame counts as saturated.
    public static let saturatedPixelFractionLimit = 0.01
    /// Relative tolerance between requested and reported exposure/ISO.
    public static let exposureMetadataTolerance = 0.10
    /// Method B: AE counts as settled when |target offset| is below this, EV.
    public static let autoExposureSettledOffsetEV = 0.3
    /// Method B: "too dark" when at maximum exposure and AE still wants this much more, EV.
    public static let autoExposureTooDarkOffsetEV = -1.0
    /// Fixed white-balance gains (R, G, B). 1.0 = neutral placeholder until T0.0.
    public static let whiteBalanceGains = (red: 1.0, green: 1.0, blue: 1.0)
}
