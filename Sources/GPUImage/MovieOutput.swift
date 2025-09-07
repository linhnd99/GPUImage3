import AVFoundation

public protocol AudioEncodingTarget {
    func activateAudioTrack()
    func processAudioBuffer(_ sampleBuffer: CMSampleBuffer)
}

public class MovieOutput: ImageConsumer, AudioEncodingTarget {
    public let sources = SourceContainer()
    public let maximumInputs: UInt = 1

    let assetWriter: AVAssetWriter
    let assetWriterVideoInput: AVAssetWriterInput
    var assetWriterAudioInput: AVAssetWriterInput?

    let assetWriterPixelBufferInput: AVAssetWriterInputPixelBufferAdaptor
    let size: Size
    public private(set) var isRecording = false
    private var videoEncodingIsFinished = false
    private var audioEncodingIsFinished = false
    private var startTime: CMTime?
    private var previousFrameTime = CMTime.negativeInfinity
    private var previousAudioTime = CMTime.negativeInfinity
    private var encodingLiveVideo: Bool
    private var assetWriterQueue = DispatchQueue(label: "com.linhnd99.assetWriterQueue")
    var pixelBuffer: CVPixelBuffer? = nil

    var renderPipelineState: MTLRenderPipelineState!

    var transform: CGAffineTransform {
        get {
            return assetWriterVideoInput.transform
        }
        set {
            assetWriterVideoInput.transform = newValue
        }
    }

    public init(
        URL: Foundation.URL, size: Size, fileType: AVFileType = AVFileType.mov,
        liveVideo: Bool = false, settings: [String: AnyObject]? = nil
    ) throws {
        self.size = size
        assetWriter = try AVAssetWriter(url: URL, fileType: fileType)
        // Set this to make sure that a functional movie is produced, even if the recording is cut off mid-stream. Only the last second should be lost in that case.
        assetWriter.movieFragmentInterval = CMTimeMakeWithSeconds(1.0, preferredTimescale: 1000)

        var localSettings: [String: AnyObject]
        if let settings = settings {
            localSettings = settings
        } else {
            localSettings = [String: AnyObject]()
        }

        localSettings[AVVideoWidthKey] =
            localSettings[AVVideoWidthKey] ?? NSNumber(value: size.width)
        localSettings[AVVideoHeightKey] =
            localSettings[AVVideoHeightKey] ?? NSNumber(value: size.height)
        localSettings[AVVideoCodecKey] =
            localSettings[AVVideoCodecKey] ?? AVVideoCodecH264 as NSString

        assetWriterVideoInput = AVAssetWriterInput(
            mediaType: AVMediaType.video, outputSettings: localSettings)
        assetWriterVideoInput.expectsMediaDataInRealTime = liveVideo
        encodingLiveVideo = liveVideo

        let sourcePixelBufferAttributesDictionary: [String: AnyObject] = [
            kCVPixelBufferPixelFormatTypeKey as String: NSNumber(
                value: Int32(kCVPixelFormatType_32BGRA)),
            kCVPixelBufferWidthKey as String: NSNumber(value: size.width),
            kCVPixelBufferHeightKey as String: NSNumber(value: size.height),
        ]

        assetWriterPixelBufferInput = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: assetWriterVideoInput,
            sourcePixelBufferAttributes: sourcePixelBufferAttributesDictionary)
        assetWriter.add(assetWriterVideoInput)

        let (pipelineState, _, _) = generateRenderPipelineState(
            device: sharedMetalRenderingDevice, vertexFunctionName: "oneInputVertex",
            fragmentFunctionName: "passthroughFragment", operationName: "RenderView")
        self.renderPipelineState = pipelineState
    }

    public func startRecording(transform: CGAffineTransform? = nil) {
        if let transform = transform {
            assetWriterVideoInput.transform = transform
        }

        assetWriterQueue.async { [weak self] in
            guard let self else { return }
            self.startTime = nil
            self.isRecording = self.assetWriter.startWriting()
        }
    }

    public func finishRecording(_ completionCallback: (() -> Void)? = nil) {
        self.isRecording = false

        if self.assetWriter.status == .completed || self.assetWriter.status == .cancelled
            || self.assetWriter.status == .unknown
        {
            DispatchQueue.global().async {
                completionCallback?()
            }
            return
        }

        assetWriterQueue.async {
            if (self.assetWriter.status == .writing) && (!self.videoEncodingIsFinished) {
                self.videoEncodingIsFinished = true
                self.assetWriterVideoInput.markAsFinished()
            }
            if (self.assetWriter.status == .writing) && (!self.audioEncodingIsFinished) {
                self.audioEncodingIsFinished = true
                self.assetWriterAudioInput?.markAsFinished()
            }

            self.assetWriter.finishWriting { completionCallback?() }
        }
    }

    public func newTextureAvailable(_ texture: Texture, fromSourceIndex: UInt) {
        guard isRecording else { return }
        // Ignore still images and other non-video updates (do I still need this?)
        guard let frameTime = texture.timingStyle.timestamp?.asCMTime else { return }
        // If two consecutive times with the same value are added to the movie, it aborts recording, so I bail on that case
        guard frameTime != previousFrameTime else { return }

        assetWriterQueue.sync {
            if self.startTime == nil {
                if self.assetWriter.status != .writing {
                    self.assetWriter.startWriting()
                }

                self.assetWriter.startSession(atSourceTime: frameTime)
                self.startTime = frameTime
            }
        }

        // TODO: Run the following on an internal movie recording dispatch queue, context
        guard assetWriterVideoInput.isReadyForMoreMediaData || (!encodingLiveVideo) else {
            debugPrint("Had to drop a frame at time \(frameTime)")
            return
        }

        guard let pixelBufferPool = assetWriterPixelBufferInput.pixelBufferPool else {
            debugPrint("No pool from pixel buffer input \(frameTime)")
            return
        }

        var pixelBufferFromPool: CVPixelBuffer? = nil

        let pixelBufferStatus = CVPixelBufferPoolCreatePixelBuffer(
            nil, pixelBufferPool, &pixelBufferFromPool)
        guard let pixelBuffer = pixelBufferFromPool, pixelBufferStatus == kCVReturnSuccess else {
            return
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        renderIntoPixelBuffer(pixelBuffer, texture: texture) { [weak self] in
            defer {
                CVPixelBufferUnlockBaseAddress(
                    pixelBuffer, CVPixelBufferLockFlags(rawValue: CVOptionFlags(0)))
            }

            guard let self else { return }
            if !self.assetWriterPixelBufferInput.append(pixelBuffer, withPresentationTime: frameTime) {
                print("Problem appending pixel buffer at time: \(frameTime)")
            }
        }
    }

    func renderIntoPixelBuffer(_ pixelBuffer: CVPixelBuffer, texture: Texture, completion: (() -> Void)?) {
        guard let pixelBufferBytes = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            print("Could not get buffer bytes")
            return
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        var outputTexture: Texture?
        let callback = {
            guard let outputTexture else {
                completion?()
                return 
            }

            let region = MTLRegionMake2D(0, 0, outputTexture.texture.width, outputTexture.texture.height)
            outputTexture.texture.getBytes(pixelBufferBytes, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)
            completion?()
        }

        if (Int(round(self.size.width)) != texture.texture.width) && (Int(round(self.size.height)) != texture.texture.height) {
            let commandBuffer = sharedMetalRenderingDevice.commandQueue.makeCommandBuffer()

            outputTexture = Texture(
                device: sharedMetalRenderingDevice.device, orientation: .portrait,
                width: Int(round(self.size.width)), height: Int(round(self.size.height)),
                timingStyle: texture.timingStyle)

            commandBuffer?.renderQuad(
                pipelineState: renderPipelineState, inputTextures: [0: texture],
                outputTexture: outputTexture!)
            commandBuffer?.addCompletedHandler({ _ in
                callback()
            })
            commandBuffer?.commit()
        } else {
            let commandBuffer = sharedMetalRenderingDevice.commandQueue.makeCommandBuffer()
            let blitEncoder = commandBuffer?.makeBlitCommandEncoder()
            blitEncoder?.optimizeContentsForCPUAccess(texture: texture.texture)
            blitEncoder?.endEncoding()
            commandBuffer?.addCompletedHandler({ _ in
                callback()
            })
            commandBuffer?.commit()
            outputTexture = texture
        }
    }

    // MARK: -
    // MARK: Audio support

    public func activateAudioTrack() {
        let audioOutputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 44100,
            AVEncoderBitRateKey: 64000
        ]
        assetWriterAudioInput = AVAssetWriterInput(
            mediaType: AVMediaType.audio, outputSettings: audioOutputSettings)
        assetWriterAudioInput?.expectsMediaDataInRealTime = true
        assetWriter.add(assetWriterAudioInput!)
        assetWriterAudioInput?.expectsMediaDataInRealTime = encodingLiveVideo
    }

    public func processAudioBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let assetWriterAudioInput = assetWriterAudioInput, isRecording else { return }

        let currentSampleTime = CMSampleBufferGetOutputPresentationTimeStamp(sampleBuffer)
        assetWriterQueue.sync {
            if self.startTime == nil {
                if self.assetWriter.status != .writing {
                    self.assetWriter.startWriting()
                }

                self.assetWriter.startSession(atSourceTime: currentSampleTime)
                self.startTime = currentSampleTime
            }
        }

        guard assetWriterAudioInput.isReadyForMoreMediaData || (!self.encodingLiveVideo) else {
            return
        }

        if !assetWriterAudioInput.append(sampleBuffer) {
            print("Trouble appending audio sample buffer")
        }
    }
}
