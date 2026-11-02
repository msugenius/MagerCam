import AVFoundation
import Foundation
import VideoToolbox

struct CameraInfo: Identifiable {
    let id: String
    let name: String
}

struct CaptureFormat {
    let width: Int
    let height: Int
    let fps: Int

    var bitrateKbps: Int {
        let pixels = Double(max(0, width)) * Double(max(0, height))
        if pixels >= 1920 * 1080 { return 16_000 }
        if pixels >= 1280 * 720 { return 8_000 }
        return 4_000
    }
}

private struct CameraFrameRateRange {
    let minimum: Double
    let maximum: Double
}

private struct CameraFormatCandidate {
    let width: Int
    let height: Int
    let rates: [CameraFrameRateRange]
}

private struct CameraFormatSelection {
    let formatIndex: Int
    let rangeIndex: Int
    let frameRate: Double
}

private enum CameraQualityPolicy {
    static func supportedDimensions(width: Int, height: Int) -> Bool {
        width > 0 && height > 0 && width.isMultiple(of: 2) && height.isMultiple(of: 2)
            && max(width, height) <= 1920 && min(width, height) <= 1080
    }

    /// Prefer a native 30 fps class mode (including 29.97), then the largest image within Full HD.
    /// If no mode supports 30 fps, retain the best supported rate at the chosen size.
    static func select(_ candidates: [CameraFormatCandidate]) -> CameraFormatSelection? {
        var best: CameraFormatSelection?
        var bestPixels = 0
        for (formatIndex, candidate) in candidates.enumerated() {
            guard supportedDimensions(width: candidate.width, height: candidate.height) else { continue }
            for (rangeIndex, range) in candidate.rates.enumerated() {
                guard range.minimum.isFinite, range.maximum.isFinite,
                      range.minimum > 0, range.minimum <= range.maximum, range.minimum <= 30 else { continue }
                let frameRate = min(30, range.maximum)
                guard frameRate >= 1, frameRate >= range.minimum else { continue }
                let pixels = candidate.width * candidate.height
                let preferred: Bool
                if let best {
                    if (frameRate >= 29.9) != (best.frameRate >= 29.9) {
                        preferred = frameRate >= 29.9
                    } else {
                        preferred = pixels > bestPixels || (pixels == bestPixels && frameRate > best.frameRate)
                    }
                } else {
                    preferred = true
                }
                if preferred {
                    best = CameraFormatSelection(formatIndex: formatIndex, rangeIndex: rangeIndex, frameRate: frameRate)
                    bestPixels = pixels
                }
            }
        }
        return best
    }
}

struct EncodedVideo {
    /// H.264 SPS and PPS with Annex-B start codes, included on keyframes.
    let configuration: Data?
    /// One complete H.264 access unit with Annex-B start codes.
    let data: Data
    let pts: Int64
    let keyframe: Bool
}

private enum CameraError: LocalizedError {
    case message(String)
    case videoToolbox(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        case .videoToolbox(let operation, let status):
            return "\(operation) failed (VideoToolbox \(status))."
        }
    }
}

/// Capture configuration, frame delivery and encoder lifetime share one serial queue.
/// Video callbacks run on VideoToolbox's callback thread; consumers must serialize their work.
final class CameraSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()

    private let queue = DispatchQueue(label: "com.magercam.sender.camera", qos: .userInitiated)
    private let onVideo: (EncodedVideo) -> Void
    private let onError: (String) -> Void
    private var output: AVCaptureVideoDataOutput?
    private var encoder: H264Encoder?
    private var started = false
    private var forceKeyframe = true
    private var firstTimestamp: CMTime?
    private var previousPTS: Int64 = -1
    private var runtimeObserver: NSObjectProtocol?
    private var disconnectObserver: NSObjectProtocol?
    private var testPatternTimer: DispatchSourceTimer?
    private var testPatternPool: CVPixelBufferPool?
    private var testPatternStart: UInt64 = 0
    private var testPatternFrame: Int = 0
    private var pendingStart: ((Result<CaptureFormat, Error>) -> Void)?
    private var startupTimeout: DispatchWorkItem?
    private var startupFPS = 30
    private var encoderFrameRate = 30.0
    private var lockedDevice: AVCaptureDevice?
    private var generation: UInt64 = 0

    init(onVideo: @escaping (EncodedVideo) -> Void, onError: @escaping (String) -> Void) {
        self.onVideo = onVideo
        self.onError = onError
        super.init()
    }

    static func availableCameras() -> [CameraInfo] {
        discoverDevices().map { CameraInfo(id: $0.uniqueID, name: $0.localizedName) }
    }

    private static func discoverDevices() -> [AVCaptureDevice] {
        let types: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            types = [.builtInWideAngleCamera, .external, .continuityCamera]
        } else {
            types = [.builtInWideAngleCamera, .externalUnknown]
        }
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: types, mediaType: .video, position: .unspecified
        ).devices
    }

    func start(cameraID: String?, completion: @escaping (Result<CaptureFormat, Error>) -> Void) {
        queue.async { [self] in
            stopOnQueue()
            pendingStart = completion
            do {
                guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
                    throw CameraError.message("Allow camera access in System Settings → Privacy & Security → Camera.")
                }
                let devices = Self.discoverDevices()
                let device: AVCaptureDevice?
                if let cameraID, !cameraID.isEmpty {
                    device = devices.first { $0.uniqueID == cameraID }
                } else {
                    device = devices.first
                }
                guard let device else { throw CameraError.message("The selected camera is unavailable.") }
                let input = try AVCaptureDeviceInput(device: device)
                let nativeFormats = device.formats
                let candidates = nativeFormats.map { format -> CameraFormatCandidate in
                    let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                    return CameraFormatCandidate(width: Int(dimensions.width), height: Int(dimensions.height),
                                                 rates: format.videoSupportedFrameRateRanges.map {
                        CameraFrameRateRange(minimum: $0.minFrameRate, maximum: $0.maxFrameRate)
                    })
                }
                guard let selection = CameraQualityPolicy.select(candidates) else {
                    throw CameraError.message("The camera has no supported format up to 1920×1080 at 30 fps or less.")
                }
                let selectedFormat = nativeFormats[selection.formatIndex]
                let selectedRange = selectedFormat.videoSupportedFrameRateRanges[selection.rangeIndex]
                let duration = selection.frameRate == 30
                    ? CMTime(value: 1, timescale: 30) : selectedRange.minFrameDuration
                let videoOutput = AVCaptureVideoDataOutput()
                videoOutput.alwaysDiscardsLateVideoFrames = true
                videoOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                ]
                videoOutput.setSampleBufferDelegate(self, queue: queue)

                do {
                    session.beginConfiguration()
                    defer { session.commitConfiguration() }
                    for oldInput in session.inputs { session.removeInput(oldInput) }
                    for oldOutput in session.outputs { session.removeOutput(oldOutput) }
                    if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
                    guard session.canAddInput(input) else {
                        throw CameraError.message("The camera could not be added to the capture session.")
                    }
                    session.addInput(input)
                    guard session.canAddOutput(videoOutput) else {
                        throw CameraError.message("The camera does not support video frame capture.")
                    }
                    session.addOutput(videoOutput)
                    try device.lockForConfiguration()
                    lockedDevice = device
                    // inputPriority is unavailable on native macOS. Keep the configuration lock
                    // while capturing so the session cannot replace this explicitly selected format.
                    device.activeFormat = selectedFormat
                    device.activeVideoMinFrameDuration = duration
                    device.activeVideoMaxFrameDuration = duration
                }
                encoderFrameRate = selection.frameRate
                startupFPS = max(1, min(30, Int(selection.frameRate.rounded())))

                output = videoOutput
                firstTimestamp = nil
                previousPTS = -1
                forceKeyframe = true
                started = true
                installObservers(device: device)
                session.startRunning()
                guard session.isRunning else { throw CameraError.message("The camera did not start.") }
                // Readiness and dimensions come from the first successfully submitted actual buffer.
                // A session can report isRunning even when a disconnected/busy camera delivers no frames.
                let currentGeneration = generation
                let timeout = DispatchWorkItem { [weak self] in
                    guard let self, self.generation == currentGeneration, self.pendingStart != nil else { return }
                    self.failOnQueue(CameraError.message("The camera did not deliver an encodable frame within 8 seconds."))
                }
                startupTimeout = timeout
                queue.asyncAfter(deadline: .now() + 8, execute: timeout)
            } catch {
                failOnQueue(error)
            }
        }
    }

    func stop() {
        queue.async { [self] in stopOnQueue() }
    }

    /// A real encoded stream for integration tests on hosts without camera permission.
    func startTestPattern(format: CaptureFormat = CaptureFormat(width: 1280, height: 720, fps: 30),
                          completion: @escaping (Result<CaptureFormat, Error>) -> Void) {
        queue.async { [self] in
            stopOnQueue()
            do {
                guard CameraQualityPolicy.supportedDimensions(width: format.width, height: format.height),
                      (1...30).contains(format.fps) else {
                    throw CameraError.message("Test patterns require even dimensions up to 1920×1080 and 1–30 fps.")
                }
                encoderFrameRate = Double(format.fps)
                encoder = try makeEncoder(width: format.width, height: format.height)
                let attributes: [String: Any] = [
                    kCVPixelBufferWidthKey as String: format.width,
                    kCVPixelBufferHeightKey as String: format.height,
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:]
                ]
                let poolStatus = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil,
                                                        attributes as CFDictionary, &testPatternPool)
                guard poolStatus == kCVReturnSuccess else {
                    throw CameraError.message("Could not allocate the test pattern buffers (\(poolStatus)).")
                }
                testPatternStart = DispatchTime.now().uptimeNanoseconds
                testPatternFrame = 0
                forceKeyframe = true
                started = true
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / format.fps),
                               leeway: .milliseconds(2))
                timer.setEventHandler { [weak self] in self?.emitTestPattern() }
                testPatternTimer = timer
                timer.resume()
                completion(.success(format))
            } catch {
                stopOnQueue()
                completion(.failure(error))
            }
        }
    }

    private func emitTestPattern() {
        guard started, let testPatternPool else { return }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, testPatternPool, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            onError("Could not allocate a test pattern frame (\(status)).")
            stopOnQueue()
            return
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
            let width = CVPixelBufferGetWidth(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let side = max(1, min(120, min(width, height) / 3))
            let squareX = (testPatternFrame * 8) % (width - side + 1)
            let squareY = (testPatternFrame * 3) % (height - side + 1)
            for row in 0..<height {
                memset(luma.advanced(by: row * stride), Int32(32 + (row * 6 / height) * 30), stride)
                if row >= squareY && row < squareY + side {
                    memset(luma.advanced(by: row * stride + squareX), 235, side)
                }
            }
        }
        if let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
            memset(chroma, 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
                   * CVPixelBufferGetHeightOfPlane(buffer, 1))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let pts = Int64((DispatchTime.now().uptimeNanoseconds - testPatternStart) / 1000)
        do {
            try encoder?.encode(buffer, pts: pts, forceKeyframe: forceKeyframe)
            forceKeyframe = false
            testPatternFrame += 1
        } catch {
            onError(error.localizedDescription)
            stopOnQueue()
        }
    }

    func requestKeyframe() {
        queue.async { [self] in forceKeyframe = true }
    }

    private func stopOnQueue() {
        started = false
        generation &+= 1
        completeStart(.failure(CameraError.message("Camera startup was stopped.")))
        testPatternTimer?.cancel()
        testPatternTimer = nil
        if session.isRunning { session.stopRunning() }
        output?.setSampleBufferDelegate(nil, queue: nil)
        output = nil
        encoder?.finish()
        encoder = nil
        testPatternPool = nil
        firstTimestamp = nil
        previousPTS = -1
        for observer in [runtimeObserver, disconnectObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
        runtimeObserver = nil
        disconnectObserver = nil
        session.beginConfiguration()
        for oldOutput in session.outputs { session.removeOutput(oldOutput) }
        for oldInput in session.inputs { session.removeInput(oldInput) }
        session.commitConfiguration()
        lockedDevice?.unlockForConfiguration()
        lockedDevice = nil
    }

    private func installObservers(device: AVCaptureDevice) {
        let currentGeneration = generation
        runtimeObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
        ) { [weak self] notification in
            let message = (notification.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription
                ?? "Camera capture stopped unexpectedly."
            self?.queue.async { [weak self] in
                guard let self, self.generation == currentGeneration else { return }
                self.failOnQueue(CameraError.message(message))
            }
        }
        disconnectObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil
        ) { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self, self.generation == currentGeneration else { return }
                self.failOnQueue(CameraError.message("The selected camera was disconnected."))
            }
        }
    }

    private func makeEncoder(width: Int, height: Int) throws -> H264Encoder {
        let currentGeneration = generation
        return try H264Encoder(width: width, height: height, frameRate: encoderFrameRate, onVideo: onVideo) { [weak self] message in
            self?.queue.async { [weak self] in
                guard let self, self.generation == currentGeneration,
                      self.started || self.pendingStart != nil else { return }
                self.failOnQueue(CameraError.message(message))
            }
        }
    }

    private func completeStart(_ result: Result<CaptureFormat, Error>) {
        startupTimeout?.cancel()
        startupTimeout = nil
        let completion = pendingStart
        pendingStart = nil
        completion?(result)
    }

    private func failOnQueue(_ error: Error) {
        let wasStarting = pendingStart != nil
        completeStart(.failure(error))
        stopOnQueue()
        // Startup errors use the completion; later failures use the runtime error callback.
        if !wasStarting { onError(error.localizedDescription) }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard started, output === self.output,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard timestamp.isNumeric else { return }
        if firstTimestamp == nil { firstTimestamp = timestamp }
        let delta = CMTimeSubtract(timestamp, firstTimestamp!)
        let pts = max(previousPTS + 1, CMTimeConvertScale(delta, timescale: 1_000_000, method: .default).value)
        // Bound output to 30 fps even when the camera cannot be configured to that exact rate.
        guard previousPTS < 0 || pts - previousPTS >= 30_000 else { return }
        do {
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            guard CameraQualityPolicy.supportedDimensions(width: width, height: height) else {
                throw CameraError.message("The camera delivered unsupported dimensions; even sizes up to 1920×1080 are required.")
            }
            if encoder == nil || encoder?.width != width || encoder?.height != height {
                encoder?.finish()
                encoder = try makeEncoder(width: width, height: height)
                forceKeyframe = true
            }
            try encoder?.encode(pixelBuffer, pts: pts, forceKeyframe: forceKeyframe)
            previousPTS = pts
            forceKeyframe = false
            completeStart(.success(CaptureFormat(width: width, height: height, fps: startupFPS)))
        } catch {
            failOnQueue(error)
        }
    }

    /// Validates native-format ranking and bitrate limits without opening a camera or encoder.
    static func qualitySelfTest() throws {
        func candidate(_ width: Int, _ height: Int, _ minimum: Double, _ maximum: Double) -> CameraFormatCandidate {
            CameraFormatCandidate(width: width, height: height,
                                  rates: [CameraFrameRateRange(minimum: minimum, maximum: maximum)])
        }
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CameraError.message("Capture quality self-test: " + message) }
        }
        let fullHD = CameraQualityPolicy.select([
            candidate(1280, 720, 15, 30), candidate(1920, 1080, 15, 30),
            candidate(2560, 1440, 15, 30), candidate(3840, 2160, 15, 30)
        ])
        try require(fullHD?.formatIndex == 1 && fullHD?.frameRate == 30,
                    "Full HD at 30 fps must beat 720p; larger formats must be excluded.")
        let ntsc = CameraQualityPolicy.select([
            candidate(1280, 720, 15, 30), candidate(1920, 1080, 29.97, 29.97)
        ])
        try require(ntsc?.formatIndex == 1 && ntsc?.frameRate == 29.97,
                    "Native 1080p at 29.97 fps must beat 720p at 30 fps and retain its actual rate.")
        let smooth = CameraQualityPolicy.select([
            candidate(1920, 1080, 15, 15), candidate(1280, 720, 15, 30)
        ])
        try require(smooth?.formatIndex == 1 && smooth?.frameRate == 30,
                    "A native 30 fps mode must beat a slower, larger mode.")
        let fallback = CameraQualityPolicy.select([
            candidate(3840, 2160, 15, 30), candidate(1280, 720, 5, 25)
        ])
        try require(fallback?.formatIndex == 1 && fallback?.frameRate == 25,
                    "A 25 fps camera must retain its supported rate within the Full HD limit.")
        let highRate = CameraQualityPolicy.select([
            candidate(1920, 1080, 60, 60), candidate(1280, 720, 15, 30)
        ])
        try require(highRate?.formatIndex == 1,
                    "A 60-fps-only mode cannot satisfy the 30 fps cap.")
        try require(CameraQualityPolicy.select([candidate(1920, 1080, 15, 60)])?.frameRate == 30,
                    "A mode that supports 15–60 fps must be configured at 30 fps.")
        try require(CameraQualityPolicy.select([candidate(1080, 1920, 30, 30)]) != nil,
                    "The Full HD bounds must also accept native portrait dimensions.")
        try require(CameraQualityPolicy.select([
            candidate(2560, 1440, 30, 30), candidate(3840, 2160, 30, 30),
            candidate(1920, 1082, 30, 30), candidate(1279, 720, 30, 30),
            candidate(0, 0, 30, 30), candidate(1280, 720, 0, 0),
            candidate(1280, 720, .nan, 30), candidate(1280, 720, 1, .infinity)
        ]) == nil, "Invalid rates, odd dimensions and formats beyond Full HD must be rejected.")
        for (width, height, bitrate) in [
            (640, 480, 4_000), (1280, 720, 8_000), (1920, 1080, 16_000),
            (1080, 1920, 16_000), (3840, 2160, 16_000)
        ] {
            try require(CaptureFormat(width: width, height: height, fps: 30).bitrateKbps == bitrate,
                        "Unexpected bitrate for \(width)×\(height).")
        }
    }

    /// Verifies packet conversion and malformed-input rejection without camera or encoder services.
    static func annexBSelfTest() throws {
        let units: [[UInt8]] = [[0x65, 0x88, 0x00, 0x03, 0x01], [0x06, 0x05, 0xFF]]
        let expected = Data([0, 0, 0, 1] + units[0] + [0, 0, 0, 1] + units[1])
        for lengthSize in 1...4 {
            var avcc = Data()
            for unit in units {
                for shift in (0..<lengthSize).reversed() {
                    avcc.append(UInt8((unit.count >> (shift * 8)) & 0xFF))
                }
                avcc.append(contentsOf: unit)
            }
            // Data slices can have a nonzero startIndex; conversion must handle those too.
            let sliced = (Data([0xFF]) + avcc).dropFirst()
            guard try h264AnnexB(from: sliced, lengthSize: lengthSize) == expected else {
                throw CameraError.message("H.264 Annex-B conversion self-test failed for \(lengthSize)-byte lengths.")
            }
        }
        let invalid: [(Data, Int)] = [
            (Data(), 4), (Data([0, 0, 0, 5, 0x65]), 4),
            (Data([0, 0, 0, 0]), 4), (Data([0, 0]), 4),
            (Data([0, 0, 0, 1, 0x65, 0xFF]), 4), (Data([1, 0x65]), 0), (Data([1, 0x65]), 5)
        ]
        for (data, lengthSize) in invalid {
            var rejected = false
            do { _ = try h264AnnexB(from: data, lengthSize: lengthSize) } catch { rejected = true }
            guard rejected else { throw CameraError.message("H.264 self-test accepted a malformed access unit.") }
        }
    }

    /// Exercises the actual H.264 encoder and Annex-B conversion without touching a camera.
    static func selfTest() throws {
        let collector = EncodingTestCollector()
        let encoder = try H264Encoder(width: 320, height: 240,
                                      onVideo: { collector.append($0) },
                                      onError: { collector.fail($0) })
        for index in 0..<4 {
            var buffer: CVPixelBuffer?
            let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
            let status = CVPixelBufferCreate(kCFAllocatorDefault, 320, 240,
                                            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                            attributes as CFDictionary, &buffer)
            guard status == kCVReturnSuccess, let buffer else {
                throw CameraError.message("Could not allocate a synthetic camera frame (\(status)).")
            }
            CVPixelBufferLockBaseAddress(buffer, [])
            for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
                if let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) {
                    let bytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                        * CVPixelBufferGetHeightOfPlane(buffer, plane)
                    memset(base, plane == 0 ? Int32(32 + index * 24) : 128, bytes)
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            try encoder.encode(buffer, pts: Int64(index) * 33_333, forceKeyframe: index == 0 || index == 3)
        }
        encoder.finish()
        let (frames, errors) = collector.snapshot()
        guard errors.isEmpty else { throw CameraError.message(errors.joined(separator: "; ")) }
        guard frames.count == 4 else {
            throw CameraError.message("H.264 self-test produced \(frames.count) frames instead of 4.")
        }
        guard frames.first?.keyframe == true, frames.last?.keyframe == true else {
            throw CameraError.message("H.264 self-test did not honor keyframe requests.")
        }
        for (index, frame) in frames.enumerated() {
            guard frame.pts == Int64(index) * 33_333,
                  frame.data.starts(with: [0, 0, 0, 1]), frame.data.count > 5 else {
                throw CameraError.message("H.264 self-test found an invalid timestamp or Annex-B frame.")
            }
            if frame.keyframe {
                guard let config = frame.configuration,
                      config.starts(with: [0, 0, 0, 1]), config.count > 10,
                      config[4] & 0x1f == 7 else {
                    throw CameraError.message("H.264 self-test did not produce an Annex-B SPS/PPS configuration.")
                }
            }
        }
    }
}

private final class EncodingTestCollector {
    private let lock = NSLock()
    private var frames: [EncodedVideo] = []
    private var errors: [String] = []

    func append(_ frame: EncodedVideo) { lock.lock(); defer { lock.unlock() }; frames.append(frame) }
    func fail(_ error: String) { lock.lock(); defer { lock.unlock() }; errors.append(error) }
    func snapshot() -> ([EncodedVideo], [String]) { lock.lock(); defer { lock.unlock() }; return (frames, errors) }
}

private final class H264OutputContext {
    let onVideo: (EncodedVideo) -> Void
    let onError: (String) -> Void

    init(onVideo: @escaping (EncodedVideo) -> Void, onError: @escaping (String) -> Void) {
        self.onVideo = onVideo
        self.onError = onError
    }

    func receive(status: OSStatus, flags: VTEncodeInfoFlags, sample: CMSampleBuffer?) {
        guard status == noErr else {
            onError(CameraError.videoToolbox("H.264 encoding", status).localizedDescription)
            return
        }
        guard !flags.contains(.frameDropped), let sample, CMSampleBufferDataIsReady(sample),
              let format = CMSampleBufferGetFormatDescription(sample),
              let block = CMSampleBufferGetDataBuffer(sample) else { return }
        do {
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[CFString: Any]]
            let keyframe = (attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) != true
            var parameterCount = 0
            var headerLength: Int32 = 0
            try check(CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &parameterCount, nalUnitHeaderLengthOut: &headerLength
            ), "Reading H.264 configuration")
            guard (1...4).contains(headerLength) else { throw CameraError.message("Invalid H.264 NAL length field.") }
            var configuration: Data?
            if keyframe {
                var config = Data()
                for index in 0..<parameterCount {
                    var pointer: UnsafePointer<UInt8>?
                    var size = 0
                    try check(CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                        format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                        parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
                    ), "Reading H.264 parameter set")
                    if let pointer, size > 0 {
                        config.append(contentsOf: [0, 0, 0, 1])
                        config.append(pointer, count: size)
                    }
                }
                configuration = config
            }

            let length = CMBlockBufferGetDataLength(block)
            guard length > 0 else { throw CameraError.message("Empty H.264 access unit.") }
            var avcc = Data(count: length)
            let copyStatus = avcc.withUnsafeMutableBytes { buffer in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length,
                                           destination: buffer.baseAddress!)
            }
            try check(copyStatus, "Reading H.264 access unit")
            let annexB = try h264AnnexB(from: avcc, lengthSize: Int(headerLength))
            let pts = CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(sample),
                                        timescale: 1_000_000, method: .default).value
            onVideo(EncodedVideo(configuration: configuration, data: annexB, pts: pts, keyframe: keyframe))
        } catch {
            onError(error.localizedDescription)
        }
    }
}

/// VideoToolbox returns AVCC length-prefixed NAL units; MagerCam transports Annex-B access units.
private func h264AnnexB(from avcc: Data, lengthSize: Int) throws -> Data {
    guard (1...4).contains(lengthSize) else { throw CameraError.message("Invalid H.264 NAL length field.") }
    var annexB = Data()
    var offset = avcc.startIndex
    while offset + lengthSize <= avcc.endIndex {
        var nalLength = 0
        for byte in avcc[offset..<(offset + lengthSize)] { nalLength = (nalLength << 8) | Int(byte) }
        offset += lengthSize
        guard nalLength > 0, nalLength <= avcc.endIndex - offset else {
            throw CameraError.message("Truncated H.264 access unit.")
        }
        annexB.append(contentsOf: [0, 0, 0, 1])
        annexB.append(avcc[offset..<(offset + nalLength)])
        offset += nalLength
    }
    guard offset == avcc.endIndex, !annexB.isEmpty else {
        throw CameraError.message("Invalid H.264 access unit length.")
    }
    return annexB
}

private func check(_ status: OSStatus, _ operation: String) throws {
    if status != noErr { throw CameraError.videoToolbox(operation, status) }
}

private final class H264Encoder {
    let width: Int
    let height: Int
    private let frameRate: Double
    private var session: VTCompressionSession?
    private var retainedContext: UnsafeMutableRawPointer?

    init(width: Int, height: Int, frameRate: Double = 30, onVideo: @escaping (EncodedVideo) -> Void,
         onError: @escaping (String) -> Void) throws {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        guard CameraQualityPolicy.supportedDimensions(width: width, height: height),
              frameRate.isFinite, frameRate >= 1, frameRate <= 30 else {
            throw CameraError.message("H.264 encoding is limited to 1920×1080 and 1–30 fps.")
        }
        let bitrate = CaptureFormat(width: width, height: height, fps: Int(frameRate.rounded())).bitrateKbps * 1000
        let context = H264OutputContext(onVideo: onVideo, onError: onError)
        let opaque = Unmanaged.passRetained(context).toOpaque()
        retainedContext = opaque
        // Prefer Apple's low-latency hardware mode, fall back to normal hardware/software encoders.
        let specifications: [(properties: [CFString: Any], profile: CFString)] = [
            ([kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
              kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true],
             kVTProfileLevel_H264_ConstrainedHigh_AutoLevel),
            ([kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true],
             kVTProfileLevel_H264_High_AutoLevel),
            ([kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: false],
             kVTProfileLevel_H264_High_AutoLevel)
        ]
        var lastStatus: OSStatus = -1
        var lastOperation = "Creating an H.264 encoder"
        for specification in specifications {
            var candidate: VTCompressionSession?
            lastOperation = "Creating an H.264 encoder"
            lastStatus = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
                codecType: kCMVideoCodecType_H264, encoderSpecification: specification.properties as CFDictionary,
                imageBufferAttributes: nil, compressedDataAllocator: nil,
                outputCallback: { refcon, _, status, flags, sample in
                    guard let refcon else { return }
                    Unmanaged<H264OutputContext>.fromOpaque(refcon).takeUnretainedValue()
                        .receive(status: status, flags: flags, sample: sample)
                }, refcon: opaque, compressionSessionOut: &candidate
            )
            guard lastStatus == noErr, let candidate else {
                if let candidate { VTCompressionSessionInvalidate(candidate) }
                continue
            }
            let properties: [CFString: Any] = [
                kVTCompressionPropertyKey_RealTime: true,
                kVTCompressionPropertyKey_AllowFrameReordering: false,
                kVTCompressionPropertyKey_ProfileLevel: specification.profile,
                kVTCompressionPropertyKey_AverageBitRate: bitrate,
                kVTCompressionPropertyKey_ExpectedFrameRate: frameRate,
                kVTCompressionPropertyKey_MaxKeyFrameInterval: max(1, Int(frameRate.rounded(.up))),
                kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 1
            ]
            lastOperation = "Configuring the H.264 encoder"
            lastStatus = VTSessionSetProperties(candidate, propertyDictionary: properties as CFDictionary)
            if lastStatus == noErr {
                lastOperation = "Preparing the H.264 encoder"
                lastStatus = VTCompressionSessionPrepareToEncodeFrames(candidate)
            }
            if lastStatus == noErr {
                session = candidate
                return
            }
            // An encoder can be created yet reject this profile or configuration.
            // Try the next complete create/configure/prepare path before giving up.
            VTCompressionSessionInvalidate(candidate)
        }
        Unmanaged<H264OutputContext>.fromOpaque(opaque).release()
        retainedContext = nil
        throw CameraError.videoToolbox(lastOperation, lastStatus)
    }

    func encode(_ pixelBuffer: CVPixelBuffer, pts: Int64, forceKeyframe: Bool) throws {
        guard let session else { throw CameraError.message("The H.264 encoder is stopped.") }
        let properties: CFDictionary? = forceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        try check(VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: CMTime(value: pts, timescale: 1_000_000),
            duration: CMTime(seconds: 1 / frameRate, preferredTimescale: 1_000_000), frameProperties: properties,
            sourceFrameRefcon: nil, infoFlagsOut: nil
        ), "Submitting a camera frame")
    }

    func finish() {
        guard let session else { return }
        // CompleteFrames waits for all output callbacks before we release the callback context.
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
        if let retainedContext {
            Unmanaged<H264OutputContext>.fromOpaque(retainedContext).release()
            self.retainedContext = nil
        }
    }

    deinit { finish() }
}
