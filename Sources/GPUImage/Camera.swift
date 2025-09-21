import AVFoundation
import Foundation
import Metal

public protocol CameraDelegate {
    func didCaptureBuffer(_ sampleBuffer: CMSampleBuffer)
}

public enum PhysicalCameraLocation {
    case backFacing
    case frontFacing

    func imageOrientation() -> ImageOrientation {
        switch self {
        case .backFacing: return .landscapeRight
        #if os(iOS)
            case .frontFacing: return .landscapeLeftMirrored
        #else
            case .frontFacing: return .portrait
        #endif
        }
    }

    func captureDevicePosition() -> AVCaptureDevice.Position {
        switch self {
        case .backFacing: return .back
        case .frontFacing: return .front
        }
    }

    func device() -> AVCaptureDevice? {
        let devices = AVCaptureDevice.devices(for: AVMediaType.video)
        for case let device in devices {
            if device.position == self.captureDevicePosition() {
                return device
            }
        }

        return AVCaptureDevice.default(for: AVMediaType.video)
    }

    func toggle() -> Self {
        return self == .backFacing ? .frontFacing : .backFacing
    }
}

public struct CameraError: Error {
}

let initialBenchmarkFramesToIgnore = 5

public class Camera: NSObject, ImageSource {

    public var runBenchmark: Bool = false
    public var logFPS: Bool = false
    
    public private(set) var location: PhysicalCameraLocation
    public let targets = TargetContainer()
    public var delegate: CameraDelegate?
    public let captureSession: AVCaptureSession
    public var orientation: ImageOrientation?
    public var inputCamera: AVCaptureDevice!
    public var audioEncodingTarget: AudioEncodingTarget?

    var videoInput: AVCaptureDeviceInput?
    var videoOutput: AVCaptureVideoDataOutput!
    var audioInput: AVCaptureDeviceInput?
    var audioOutput: AVCaptureAudioDataOutput?
    var videoTextureCache: CVMetalTextureCache?

    var supportsFullYUVRange: Bool = false
    let captureAsYUV: Bool
    var yuvConversionRenderPipelineState: MTLRenderPipelineState?
    var yuvLookupTable: [String: (Int, MTLStructMember)] = [:]
    var yuvBufferSize: Int = 0

    let frameRenderingSemaphore = DispatchSemaphore(value: 1)
    let cameraProcessingQueue = DispatchQueue.global()
    let cameraFrameProcessingQueue = DispatchQueue(
        label: "com.sunsetlakesoftware.GPUImage.cameraFrameProcessingQueue",
        attributes: [])
    let audioProcessingQueue = DispatchQueue(label: "com.linhnd99.audioProcessingQueue")

    let framesToIgnore = 5
    var numberOfFramesCaptured = 0
    var totalFrameTimeDuringCapture: Double = 0.0
    var framesSinceLastCheck = 0
    var lastCheckTime = CFAbsoluteTimeGetCurrent()

    private var capturePhotoOutputFake: AVCapturePhotoOutput!
    private var capturePhotoOutputFakeSetting: AVCapturePhotoSettings!

    public init(
        sessionPreset: AVCaptureSession.Preset, cameraDevice: AVCaptureDevice? = nil,
        location: PhysicalCameraLocation = .backFacing, orientation: ImageOrientation? = nil,
        captureAsYUV: Bool = true, supportAudio: Bool = false
    ) throws {
        self.location = location
        self.orientation = orientation

        self.captureSession = AVCaptureSession()
        self.captureSession.beginConfiguration()

        self.captureAsYUV = captureAsYUV

        super.init()
        try self.configDeviceInput(cameraDevice: cameraDevice)

        // Add the video frame output
        videoOutput = AVCaptureVideoDataOutput()
        videoOutput.alwaysDiscardsLateVideoFrames = false

        if captureAsYUV {
            supportsFullYUVRange = false
            let supportedPixelFormats = videoOutput.availableVideoPixelFormatTypes
            for currentPixelFormat in supportedPixelFormats {
                if (currentPixelFormat as NSNumber).int32Value == Int32(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
                    supportsFullYUVRange = true
                }
            }
            if supportsFullYUVRange {
                let (pipelineState, lookupTable, bufferSize) = generateRenderPipelineState(
                    device: sharedMetalRenderingDevice, vertexFunctionName: "twoInputVertex",
                    fragmentFunctionName: "yuvConversionFullRangeFragment",
                    operationName: "YUVToRGB")
                self.yuvConversionRenderPipelineState = pipelineState
                self.yuvLookupTable = lookupTable
                self.yuvBufferSize = bufferSize
                videoOutput.videoSettings = [
                    kCVPixelBufferMetalCompatibilityKey as String: true,
                    kCVPixelBufferPixelFormatTypeKey as String: NSNumber(
                        value: Int32(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)),
                ]
            } else {
                let (pipelineState, lookupTable, bufferSize) = generateRenderPipelineState(
                    device: sharedMetalRenderingDevice, vertexFunctionName: "twoInputVertex",
                    fragmentFunctionName: "yuvConversionVideoRangeFragment",
                    operationName: "YUVToRGB")
                self.yuvConversionRenderPipelineState = pipelineState
                self.yuvLookupTable = lookupTable
                self.yuvBufferSize = bufferSize
                videoOutput.videoSettings = [
                    kCVPixelBufferMetalCompatibilityKey as String: true,
                    kCVPixelBufferPixelFormatTypeKey as String: NSNumber(
                        value: Int32(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)),
                ]
            }
        } else {
            self.yuvConversionRenderPipelineState = nil
            videoOutput.videoSettings = [
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferPixelFormatTypeKey as String: NSNumber(
                    value: Int32(kCVPixelFormatType_32BGRA)),
            ]
        }

        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        }

        captureSession.sessionPreset = sessionPreset

        if supportAudio {
            self.configCaptureAudio()
        }

        capturePhotoOutputFake = AVCapturePhotoOutput()
        capturePhotoOutputFakeSetting = AVCapturePhotoSettings()
        captureSession.addOutput(capturePhotoOutputFake)

        captureSession.commitConfiguration()

        let _ = CVMetalTextureCacheCreate(
            kCFAllocatorDefault, nil, sharedMetalRenderingDevice.device, nil, &videoTextureCache)

        videoOutput.setSampleBufferDelegate(self, queue: cameraProcessingQueue)
    }

    private func configCaptureAudio() {
        if let audioDevice = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
           captureSession.canAddInput(audioInput) {
            captureSession.addInput(audioInput)
            self.audioInput = audioInput
        }

        let audioOutput = AVCaptureAudioDataOutput()
        audioOutput.setSampleBufferDelegate(self, queue: audioProcessingQueue)
        if captureSession.canAddOutput(audioOutput) {
            captureSession.addOutput(audioOutput)
            self.audioOutput = audioOutput
        }
    }

    private func configDeviceInput(cameraDevice: AVCaptureDevice? = nil, location: PhysicalCameraLocation? = nil) throws {
        if let cameraDevice = cameraDevice {
            self.inputCamera = cameraDevice
        } else {
            if let device = (location ?? self.location).device() {
                self.inputCamera = device
            } else {
                self.videoInput = nil
                if videoOutput != nil {
                    captureSession.removeOutput(videoOutput)
                    self.videoOutput = nil
                }

                self.inputCamera = nil
                self.yuvConversionRenderPipelineState = nil
                throw CameraError()
            }
        }

        do {
            self.videoInput = try AVCaptureDeviceInput(device: inputCamera)
        } catch {
            self.videoInput = nil
            if videoOutput != nil {
                captureSession.removeOutput(videoOutput)
                self.videoOutput = nil
            }

            self.yuvConversionRenderPipelineState = nil
            throw error
        }

        if let videoInput, captureSession.canAddInput(videoInput) {
            captureSession.addInput(videoInput)
        }
    }

    deinit {
        cameraFrameProcessingQueue.sync {
            self._stopCapture()
            self.videoOutput?.setSampleBufferDelegate(nil, queue: nil)
        }
    }

    public func startCapture() {
        cameraFrameProcessingQueue.async { [weak self] in
            guard let self else { return }
            let _ = self.frameRenderingSemaphore.wait(timeout: DispatchTime.distantFuture)
            self.numberOfFramesCaptured = 0
            self.totalFrameTimeDuringCapture = 0
            self.frameRenderingSemaphore.signal()

            if !self.captureSession.isRunning {
                self.captureSession.startRunning()
            }
        }
    }

    public func stopCapture() {
        cameraFrameProcessingQueue.async { [weak self] in
            guard let self else { return }
            self._stopCapture()
        }
    }

    private func _stopCapture() {
        if self.captureSession.isRunning {
            let _ = self.frameRenderingSemaphore.wait(timeout: DispatchTime.distantFuture)

            self.captureSession.stopRunning()
            self.frameRenderingSemaphore.signal()
        }
    }

    public func transmitPreviousImage(to target: ImageConsumer, atIndex: UInt) {
        // Not needed for camcera
    }

    // MARK: - Public setter
    public func setLocation(_ location: PhysicalCameraLocation) {
        cameraFrameProcessingQueue.async { [weak self] in
            guard let self else { return }
            captureSession.beginConfiguration()

            if videoInput != nil {
                if let videoInput {
                    captureSession.removeInput(videoInput)
                    self.videoInput = nil
                }

                inputCamera = nil
            }

            try? self.configDeviceInput(cameraDevice: nil, location: location)

            captureSession.commitConfiguration()
            self.location = location
        }
    }

    public func setTorch(isOn: Bool) {
        cameraFrameProcessingQueue.async { [weak self] in
            guard let device = self?.videoInput?.device,
                  device.hasTorch else {
                return
            }

            do {
                try device.lockForConfiguration()

                if isOn && device.isTorchModeSupported(.on) {
                    try device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
                } else {
                    device.torchMode = .off
                }

                device.unlockForConfiguration()
            } catch {
                print("Torch could not be used: \(error)")
            }
        }
    }

    public func setFlashMode(_ mode: AVCaptureDevice.FlashMode) {
        cameraFrameProcessingQueue.async { [weak self] in
            guard let self,
                  let device = self.videoInput?.device,
                  device.hasFlash else {
                return
            }

            self.capturePhotoOutputFakeSetting.flashMode = mode
        }
    }

    public func startFakeCapturePhoto() {
        capturePhotoOutputFake.capturePhoto(with: self.capturePhotoOutputFakeSetting, delegate: self)
    }
}

extension Camera: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output == videoOutput {
            self.videoCaptureDidOutput(sampleBuffer: sampleBuffer)
        } else if output == audioOutput {
            self.audioCaptureDidOutput(sampleBuffer: sampleBuffer)
        }
    }

    public func videoCaptureDidOutput(sampleBuffer: CMSampleBuffer) {
        guard frameRenderingSemaphore.wait(timeout: DispatchTime.now()) == DispatchTimeoutResult.success else { return }

        let startTime = CFAbsoluteTimeGetCurrent()
        let cameraFrame = CMSampleBufferGetImageBuffer(sampleBuffer)!
        let bufferWidth = CVPixelBufferGetWidth(cameraFrame)
        let bufferHeight = CVPixelBufferGetHeight(cameraFrame)
        let currentTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        CVPixelBufferLockBaseAddress(
            cameraFrame, CVPixelBufferLockFlags(rawValue: CVOptionFlags(0)))

        cameraFrameProcessingQueue.async { [weak self] in
            guard let self else { return }
            self.delegate?.didCaptureBuffer(sampleBuffer)
            CVPixelBufferUnlockBaseAddress(
                cameraFrame, CVPixelBufferLockFlags(rawValue: CVOptionFlags(0)))

            let texture: Texture?
            if self.captureAsYUV {
                var luminanceTextureRef: CVMetalTexture? = nil
                var chrominanceTextureRef: CVMetalTexture? = nil
                // Luminance plane
                let _ = CVMetalTextureCacheCreateTextureFromImage(
                    kCFAllocatorDefault, self.videoTextureCache!, cameraFrame, nil, .r8Unorm,
                    bufferWidth, bufferHeight, 0, &luminanceTextureRef)
                // Chrominance plane
                let _ = CVMetalTextureCacheCreateTextureFromImage(
                    kCFAllocatorDefault, self.videoTextureCache!, cameraFrame, nil, .rg8Unorm,
                    bufferWidth / 2, bufferHeight / 2, 1, &chrominanceTextureRef)

                if let concreteLuminanceTextureRef = luminanceTextureRef,
                    let concreteChrominanceTextureRef = chrominanceTextureRef,
                    let luminanceTexture = CVMetalTextureGetTexture(concreteLuminanceTextureRef),
                    let chrominanceTexture = CVMetalTextureGetTexture(concreteChrominanceTextureRef)
                {

                    let conversionMatrix: Matrix3x3
                    if self.supportsFullYUVRange {
                        conversionMatrix = colorConversionMatrix601FullRangeDefault
                    } else {
                        conversionMatrix = colorConversionMatrix601Default
                    }

                    let outputWidth: Int
                    let outputHeight: Int
                    if (self.orientation ?? self.location.imageOrientation()).rotationNeeded(
                        for: .portrait
                    ).flipsDimensions() {
                        outputWidth = bufferHeight
                        outputHeight = bufferWidth
                    } else {
                        outputWidth = bufferWidth
                        outputHeight = bufferHeight
                    }
                    let outputTexture = Texture(
                        device: sharedMetalRenderingDevice.device, orientation: .portrait,
                        width: outputWidth, height: outputHeight,
                        timingStyle: .videoFrame(timestamp: Timestamp(currentTime)))

                    convertYUVToRGB(
                        pipelineState: self.yuvConversionRenderPipelineState!,
                        lookupTable: self.yuvLookupTable, bufferSize: self.yuvBufferSize,
                        luminanceTexture: Texture(
                            orientation: self.orientation ?? self.location.imageOrientation(),
                            texture: luminanceTexture),
                        chrominanceTexture: Texture(
                            orientation: self.orientation ?? self.location.imageOrientation(),
                            texture: chrominanceTexture),
                        resultTexture: outputTexture, colorConversionMatrix: conversionMatrix)
                    texture = outputTexture
                } else {
                    texture = nil
                }
            } else {
                var textureRef: CVMetalTexture? = nil
                let _ = CVMetalTextureCacheCreateTextureFromImage(
                    kCFAllocatorDefault, self.videoTextureCache!, cameraFrame, nil, .bgra8Unorm,
                    bufferWidth, bufferHeight, 0, &textureRef)
                if let concreteTexture = textureRef,
                    let cameraTexture = CVMetalTextureGetTexture(concreteTexture)
                {
                    texture = Texture(
                        orientation: self.orientation ?? self.location.imageOrientation(),
                        texture: cameraTexture,
                        timingStyle: .videoFrame(timestamp: Timestamp(currentTime)))
                } else {
                    texture = nil
                }
            }

            if texture != nil {
                self.updateTargetsWithTexture(texture!)
            }

            if self.runBenchmark {
                self.numberOfFramesCaptured += 1
                if self.numberOfFramesCaptured > initialBenchmarkFramesToIgnore {
                    let currentFrameTime = (CFAbsoluteTimeGetCurrent() - startTime)
                    self.totalFrameTimeDuringCapture += currentFrameTime
                    print(
                        "Average frame time : \(1000.0 * self.totalFrameTimeDuringCapture / Double(self.numberOfFramesCaptured - initialBenchmarkFramesToIgnore)) ms"
                    )
                    print("Current frame time : \(1000.0 * currentFrameTime) ms")
                }
            }

            if self.logFPS {
                if (CFAbsoluteTimeGetCurrent() - self.lastCheckTime) > 1.0 {
                    self.lastCheckTime = CFAbsoluteTimeGetCurrent()
                    print("FPS: \(self.framesSinceLastCheck)")
                    self.framesSinceLastCheck = 0
                }

                self.framesSinceLastCheck += 1
            }

            self.frameRenderingSemaphore.signal()
        }
    }

    public func audioCaptureDidOutput(sampleBuffer: CMSampleBuffer) {
        audioEncodingTarget?.processAudioBuffer(sampleBuffer)
    }
}

// MARK: - AVCapturePhotoCaptureDelegate
extension Camera: AVCapturePhotoCaptureDelegate {

}
