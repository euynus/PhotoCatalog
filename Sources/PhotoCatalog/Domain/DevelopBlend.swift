// ============================================================
//  Develop blend — a preset's Amount, as in Lightroom
// ============================================================
import Foundation

extension DevelopSettings {
    /// `base` moved `amount` of the way to `target`: 0 is `base`, 1 is `target`, 2 goes twice as
    /// far. Sliders scale and stay inside their ranges; the tone curve, the color mixer, color
    /// grading and each mask's own adjustments scale too. What can't be partly applied (crop,
    /// turns, spots, mask shapes, grading hues) is `target`'s once `amount` is above zero.
    /// `whiteBalanceOrigin` is where an unset white balance stands: the as-shot values for a RAW
    /// file (nil when not known yet), zero for other files.
    static func blend(_ base: DevelopSettings, _ target: DevelopSettings, amount: Double,
                      isRaw: Bool, whiteBalanceOrigin: (temperature: Double, tint: Double)?) -> DevelopSettings {
        if amount == 0 { return base }
        if amount == 1 { return target }
        var result = amount > 0 ? target : base
        func mix(_ b: Double, _ t: Double, _ range: ClosedRange<Double>, step: Double) -> Double {
            let value = min(range.upperBound, max(range.lowerBound, b + (t - b) * amount))
            return (value / step).rounded() * step
        }
        for control in blendedControls where base[keyPath: control.id] != target[keyPath: control.id] {
            result[keyPath: control.id] = mix(base[keyPath: control.id], target[keyPath: control.id], control.range,
                                              step: control.step)
        }

        // a profile the photo didn't have grows from nothing; one the preset takes away fades out
        if base.profile != target.profile, amount > 0 {
            if let profile = target.profile {
                result.profile = profile
                result.profileAmount = mix(0, target.profileAmount, 0...200, step: 1)
            } else {
                result.profileAmount = mix(base.profileAmount, 0, 0...200, step: 1)
                result.profile = result.profileAmount > 0 ? base.profile : nil
                if result.profile == nil { result.profileAmount = 100 }
            }
        }

        // so does lens blur: from no blur, not from the amount an unused one keeps
        if base.hasLensBlur != target.hasLensBlur, amount > 0 {
            let on = base.hasLensBlur ? base.lensBlur : target.lensBlur
            result.lensBlur = on
            result.lensBlur.amount = mix(base.hasLensBlur ? on.amount : 0, target.hasLensBlur ? on.amount : 0, 0...100, step: 1)
            result.lensBlur.enabled = result.lensBlur.amount > 0
        }

        // white balance: an unset value counts from where it stands, as shot or zero
        let temperatureRange: ClosedRange<Double> = isRaw ? 2000...12000 : -100...100
        let tintRange: ClosedRange<Double> = isRaw ? -150...150 : -100...100
        if base.temperature != target.temperature || base.tint != target.tint {
            if let origin = whiteBalanceOrigin {
                result.temperature = mix(base.temperature ?? origin.temperature, target.temperature ?? origin.temperature,
                                         temperatureRange, step: 1)
                result.tint = mix(base.tint ?? origin.tint, target.tint ?? origin.tint, tintRange, step: 1)
            }
        }

        // curves: both through every point either has, the output moved `amount` of the way
        for channel in ToneCurve.Channel.allCases {
            let b = base.curve.editablePoints(for: channel), t = target.curve.editablePoints(for: channel)
            guard b != t else { continue }
            let xs = Set((b + t).map(\.x)).sorted()
            let points = xs.map { x in
                let from = ToneCurve.evaluate(b, at: x), to = ToneCurve.evaluate(t, at: x)
                return CurvePoint(x: x, y: min(1, max(0, from + (to - from) * amount)))
            }
            result.curve.setPoints(points, for: channel)
        }

        // masks keep the preset's shapes; their adjustments scale from the photo's own mask of
        // the same id, or from nothing
        if amount > 0 {
            result.masks = target.masks.map { mask in
                var scaled = mask
                let from = base.masks.first { $0.id == mask.id }
                for (keyPath, range) in localAdjustments {
                    let b = from?[keyPath: keyPath] ?? 0
                    scaled[keyPath: keyPath] = mix(b, mask[keyPath: keyPath], range, step: 0.01)
                }
                return scaled
            }
        }
        return result
    }

    /// The sliders a blend scales: every global one but the grading hues, which turn rather
    /// than grow.
    private static let blendedControls: [DevelopControl] = {
        let regions = ColorGrading.Region.allCases.flatMap { DevelopControl.grading($0).dropFirst() }
        let mixer = ColorMixer.Property.allCases.flatMap { DevelopControl.mixer($0) }
        return DevelopControl.tone + DevelopControl.presence + Array(regions) + DevelopControl.gradingShape + mixer
            + DevelopControl.grayMixer + DevelopControl.calibration + [DevelopControl.lensBlur[0]]
            + DevelopControl.detail + DevelopControl.lens + DevelopControl.defringe + DevelopControl.effects
            + DevelopControl.transform
            + [DevelopControl.lutAmount, DevelopControl.profileAmount]
    }()

    /// A mask's adjustments with their ranges: exposure in EV, the others -100…100.
    private static let localAdjustments: [(WritableKeyPath<LocalAdjustment, Double>, ClosedRange<Double>)] =
        LocalAdjustment.adjustments.map { ($0, $0 == \LocalAdjustment.exposure ? -4...4 : -100...100) }
}
