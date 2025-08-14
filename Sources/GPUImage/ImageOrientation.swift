public enum ImageOrientation {
    case portrait
    case portraitUpsideDown
    case landscapeLeft
    case landscapeRight
    case portraitMirrored
    case portraitUpsideDownMirrored
    case landscapeLeftMirrored
    case landscapeRightMirrored

    // func rotationNeeded(for targetOrientation: ImageOrientation) -> Rotation {
    //     if (self == targetOrientation) {
    //         return .noRotation
    //     }

    //     switch (self, targetOrientation) {
    //     case (.portrait, .portraitUpsideDown): return .rotate180
    //     case (.portraitUpsideDown, .portrait): return .rotate180
    //     case (.portrait, .landscapeLeft): return .rotateCounterclockwise
    //     case (.landscapeLeft, .portrait): return .rotateClockwise
    //     case (.portrait, .landscapeRight): return .rotateClockwise
    //     case (.landscapeRight, .portrait): return .rotateCounterclockwise
    //     case (.landscapeLeft, .landscapeRight): return .rotate180
    //     case (.landscapeRight, .landscapeLeft): return .rotate180
    //     case (.portraitUpsideDown, .landscapeLeft): return .rotateClockwise
    //     case (.landscapeLeft, .portraitUpsideDown): return .rotateCounterclockwise
    //     case (.portraitUpsideDown, .landscapeRight): return .rotateCounterclockwise
    //     case (.landscapeRight, .portraitUpsideDown): return .rotateClockwise

    //     default:
    //         return .noRotation
    //     }
    // }

    func rotationNeeded(for targetOrientation: ImageOrientation) -> Rotation {
        if self == targetOrientation {
            return .noRotation
        }

        switch (self, targetOrientation) {
 
        case (.portrait, .portraitUpsideDown): return .rotate180
        case (.portraitUpsideDown, .portrait): return .rotate180
        case (.portrait, .landscapeLeft): return .rotateCounterclockwise
        case (.landscapeLeft, .portrait): return .rotateClockwise
        case (.portrait, .landscapeRight): return .rotateClockwise
        case (.landscapeRight, .portrait): return .rotateCounterclockwise
        case (.landscapeLeft, .landscapeRight): return .rotate180
        case (.landscapeRight, .landscapeLeft): return .rotate180
        case (.portraitUpsideDown, .landscapeLeft): return .rotateClockwise
        case (.landscapeLeft, .portraitUpsideDown): return .rotateCounterclockwise
        case (.portraitUpsideDown, .landscapeRight): return .rotateCounterclockwise
        case (.landscapeRight, .portraitUpsideDown): return .rotateClockwise

        case (.portraitMirrored, .portraitUpsideDownMirrored): return .rotate180
        case (.portraitUpsideDownMirrored, .portraitMirrored): return .rotate180
        case (.portraitMirrored, .landscapeLeftMirrored): return .rotateCounterclockwise
        case (.landscapeLeftMirrored, .portraitMirrored): return .rotateClockwise
        case (.portraitMirrored, .landscapeRightMirrored): return .rotateClockwise
        case (.landscapeRightMirrored, .portraitMirrored): return .rotateCounterclockwise
        case (.landscapeLeftMirrored, .landscapeRightMirrored): return .rotate180
        case (.landscapeRightMirrored, .landscapeLeftMirrored): return .rotate180
        case (.portraitUpsideDownMirrored, .landscapeLeftMirrored): return .rotateClockwise
        case (.landscapeLeftMirrored, .portraitUpsideDownMirrored): return .rotateCounterclockwise
        case (.portraitUpsideDownMirrored, .landscapeRightMirrored): return .rotateCounterclockwise
        case (.landscapeRightMirrored, .portraitUpsideDownMirrored): return .rotateClockwise

        case (.portrait, .portraitMirrored): return .flipHorizontally
        case (.portraitMirrored, .portrait): return .flipHorizontally
        case (.portraitUpsideDown, .portraitUpsideDownMirrored): return .flipHorizontally
        case (.portraitUpsideDownMirrored, .portraitUpsideDown): return .flipHorizontally
        case (.landscapeLeft, .landscapeLeftMirrored): return .flipVertically
        case (.landscapeLeftMirrored, .landscapeLeft): return .flipVertically
        case (.landscapeRight, .landscapeRightMirrored): return .flipVertically
        case (.landscapeRightMirrored, .landscapeRight): return .flipVertically

        case (.portrait, .landscapeLeftMirrored): return .rotateClockwiseAndFlipHorizontally
        case (.landscapeLeftMirrored, .portrait): return .rotateClockwiseAndFlipVertically
        case (.portrait, .landscapeRightMirrored): return .rotateClockwiseAndFlipVertically
        case (.landscapeRightMirrored, .portrait): return .rotateClockwiseAndFlipHorizontally
        case (.portraitUpsideDown, .landscapeLeftMirrored): return .rotateClockwiseAndFlipVertically
        case (.landscapeLeftMirrored, .portraitUpsideDown): return .rotateClockwiseAndFlipVertically
        case (.portraitUpsideDown, .landscapeRightMirrored): return .rotateClockwiseAndFlipHorizontally
        case (.landscapeRightMirrored, .portraitUpsideDown): return .rotateClockwiseAndFlipHorizontally

        case (.portraitMirrored, .landscapeLeft): return .rotateClockwiseAndFlipHorizontally
        case (.landscapeLeft, .portraitMirrored): return .rotateClockwiseAndFlipHorizontally
        case (.portraitMirrored, .landscapeRight): return .rotateClockwiseAndFlipVertically
        case (.landscapeRight, .portraitMirrored): return .rotateClockwiseAndFlipVertically
        case (.portraitUpsideDownMirrored, .landscapeLeft): return .rotateClockwiseAndFlipVertically
        case (.landscapeLeft, .portraitUpsideDownMirrored): return .rotateClockwiseAndFlipVertically
        case (.portraitUpsideDownMirrored, .landscapeRight): return .rotateClockwiseAndFlipHorizontally
        case (.landscapeRight, .portraitUpsideDownMirrored): return .rotateClockwiseAndFlipHorizontally

        default:
            return .noRotation
        }
    }
}

public enum Rotation {
    case noRotation
    case rotateCounterclockwise
    case rotateClockwise
    case rotate180
    case flipHorizontally
    case flipVertically
    case rotateClockwiseAndFlipVertically
    case rotateClockwiseAndFlipHorizontally

    func flipsDimensions() -> Bool {
        switch self {
        case .noRotation, .rotate180, .flipHorizontally, .flipVertically: return false
        case .rotateCounterclockwise, .rotateClockwise, .rotateClockwiseAndFlipVertically,
            .rotateClockwiseAndFlipHorizontally:
            return true
        }
    }
}
