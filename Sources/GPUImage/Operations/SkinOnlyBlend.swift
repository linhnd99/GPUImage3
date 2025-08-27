import GPUImage

/// Blends a blurred image over the original, but only on skin regions detected from the original.
/// Inputs:
///   - input 0: original
///   - input 1: blurred (e.g., from BilateralBlur or GaussianBlur)
public final class SkinOnlyBlend: BasicOperation {

    // Overall smoothing strength applied where mask=1
    public var smoothMix: Float = 0.65 { didSet { uniformSettings["smoothMix"] = smoothMix } }

    // Skin detection params (HSV + luma gates)
    public var skinHueCenter: Float = 0.30 { didSet { uniformSettings["skinHueCenter"] = skinHueCenter } } // radians (≈0.30 ~ light orange)
    public var skinHueWidth:  Float = 0.35 { didSet { uniformSettings["skinHueWidth"]  = skinHueWidth  } } // radians half-width
    public var skinSatMin:    Float = 0.15 { didSet { uniformSettings["skinSatMin"]    = skinSatMin    } }
    public var skinSatMax:    Float = 0.75 { didSet { uniformSettings["skinSatMax"]    = skinSatMax    } }
    public var skinYMin:      Float = 0.20 { didSet { uniformSettings["skinYMin"]      = skinYMin      } }
    public var skinYMax:      Float = 0.90 { didSet { uniformSettings["skinYMax"]      = skinYMax      } }

    /// Softness applied to the mask edges (0=hard, 1=soft). Internally used as an extra smoothstep band.
    public var feather:       Float = 0.20 { didSet { uniformSettings["feather"]       = feather       } }

    public init() {
        super.init(fragmentFunctionName: "skinOnlyBlendFragment", numberOfInputs: 2)
        ({ smoothMix = 0.65 })()

        ({ skinHueCenter = 0.30 })()
        ({ skinHueWidth  = 0.35 })()
        ({ skinSatMin    = 0.15 })()
        ({ skinSatMax    = 0.75 })()
        ({ skinYMin      = 0.20 })()
        ({ skinYMax      = 0.90 })()
        ({ feather       = 0.20 })()
    }
}