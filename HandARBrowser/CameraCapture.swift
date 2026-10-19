import ARKit
import AVFoundation
import CoreMotion
import UIKit
import simd

struct CaptureCamera {
    let transform: simd_float4x4
    let intrinsics: simd_float3x3
    let imageResolution: CGSize
    let arCamera: ARCamera?

    func viewMatrix(for orientation: UIInterfaceOrientation) -> simd_float4x4 {
        if let arCamera { return arCamera.viewMatrix(for:orientation) }
        let angle: Float
        switch orientation {
        case .landscapeLeft: angle = .pi
        case .portrait: angle = -.pi/2
        case .portraitUpsideDown: angle = .pi/2
        default: angle = 0
        }
        return (transform * simd_float4x4(simd_quatf(angle:angle,axis:SIMD3(0,0,1)))).inverse
    }
}

struct CameraFrame {
    let capturedImage: CVPixelBuffer
    let camera: CaptureCamera
    let mode: CameraMode
    let timestamp: Double
    private let arFrame: ARFrame?

    init(_ frame: ARFrame) {
        capturedImage=frame.capturedImage; mode = .worldTracking; timestamp=frame.timestamp; arFrame=frame
        camera=CaptureCamera(transform:frame.camera.transform,intrinsics:frame.camera.intrinsics,
                             imageResolution:frame.camera.imageResolution,arCamera:frame.camera)
    }
    init(image: CVPixelBuffer, intrinsics: simd_float3x3, transform: simd_float4x4, timestamp: Double) {
        capturedImage=image; mode = .ultraWide; self.timestamp=timestamp; arFrame=nil
        camera=CaptureCamera(transform:transform,intrinsics:intrinsics,
            imageResolution:CGSize(width:CVPixelBufferGetWidth(image),height:CVPixelBufferGetHeight(image)),arCamera:nil)
    }
    var projection: CameraProjection? {
        CameraProjection(width:Double(camera.imageResolution.width),height:Double(camera.imageResolution.height),
            fx:Double(camera.intrinsics[0][0]),fy:Double(camera.intrinsics[1][1]),
            cx:Double(camera.intrinsics[2][0]),cy:Double(camera.intrinsics[2][1]),rayScale:mode.rayScale)
    }
    func displayTransform(for orientation: UIInterfaceOrientation, viewportSize: CGSize) -> CGAffineTransform {
        if let arFrame { return arFrame.displayTransform(for:orientation,viewportSize:viewportSize) }
        // Input here is an oriented Vision point (bottom-left origin).
        let portrait = orientation == .portrait || orientation == .portraitUpsideDown
        let w = portrait ? camera.imageResolution.height : camera.imageResolution.width
        let h = portrait ? camera.imageResolution.width : camera.imageResolution.height
        guard viewportSize.width > 0, viewportSize.height > 0 else { return .identity }
        let fill = max(viewportSize.width/w,viewportSize.height/h)
        let sx=w*fill/viewportSize.width, sy=h*fill/viewportSize.height
        return CGAffineTransform(a:sx,b:0,c:0,d:-sy,tx:(1-sx)*0.5,ty:(1+sy)*0.5)
    }
}

/// Real 0.5x camera, no concurrent ARSession. Video never configures the audio
/// session, so entering the hall cannot steal or stop its soundtrack.
final class UltraWideCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    static var isAvailable: Bool {
        AVCaptureDevice.default(.builtInUltraWideCamera,for:.video,position:.back) != nil
            && CMMotionManager().isDeviceMotionAvailable
    }
    var onFrame: ((CameraFrame) -> Void)?
    private var failureHandler: ((String) -> Void)?
    private let capture = AVCaptureSession()
    private let queue = DispatchQueue(label:"handar.ultrawide",qos:.userInitiated)
    private let motion = CMMotionManager()
    private let motionQueue: OperationQueue = {
        let q=OperationQueue();q.name="handar.camera.motion";q.maxConcurrentOperationCount=1;return q
    }()
    private let lock = NSLock()
    private var generation = UUID()
    private var running = false
    private var receivedFrame = false
    private var lastFrameAt = 0.0
    private var watchdog: DispatchSourceTimer?
    private var poses: [(Double,simd_quatf)] = []
    private var heading: simd_quatf?
    private var output: AVCaptureVideoDataOutput?
    private var fallbackFOV: Float = 110
    private var errorObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?

    func start(onFailure: @escaping (String) -> Void) {
        lock.lock();generation=UUID();let token=generation;running=true;receivedFrame=false;lastFrameAt=0;poses=[];heading=nil;failureHandler=onFailure;lock.unlock()
        queue.async { [weak self] in
            guard let self, self.isCurrent(token) else { return }
            do {
                try self.configure()
                guard self.isCurrent(token) else { return }
                self.motion.deviceMotionUpdateInterval=1.0/100
                self.motion.startDeviceMotionUpdates(using:.xArbitraryZVertical,to:self.motionQueue) { [weak self] data,error in
                    guard let self, self.isCurrent(token) else { return }
                    guard let data else { if error != nil { self.fail("Не удалось получить повороты головы. Выбери AR 1×.",token:token) };return }
                    let r=data.attitude.rotationMatrix
                    guard let basis=CameraOrientationMath.rawCameraBasis(referenceToDevice:[
                        SIMD3(r.m11,r.m12,r.m13),SIMD3(r.m21,r.m22,r.m23),SIMD3(r.m31,r.m32,r.m33)]) else { return }
                    let columns=basis.map { SIMD3<Float>(Float($0.x),Float($0.y),Float($0.z)) }
                    let orientation=simd_quatf(simd_float3x3(columns: (columns[0],columns[1],columns[2])))
                    self.lock.lock()
                    if self.running && self.generation == token {
                        if self.heading == nil {
                            self.heading=simd_quatf(angle:Float(CameraOrientationMath.initialHeading(basis:basis)),axis:SIMD3(0,1,0))
                        }
                        if let heading=self.heading { self.poses.append((data.timestamp,heading*orientation)) }
                        if self.poses.count > 80 { self.poses.removeFirst(self.poses.count-80) }
                    }
                    self.lock.unlock()
                }
                self.errorObserver=NotificationCenter.default.addObserver(forName:AVCaptureSession.runtimeErrorNotification,object:self.capture,queue:nil) { [weak self] _ in
                    self?.fail("Камера 0,5× остановилась. Открой пространство заново или выбери AR 1×.",token:token)
                }
                self.interruptionObserver=NotificationCenter.default.addObserver(forName:AVCaptureSession.wasInterruptedNotification,object:self.capture,queue:nil) { [weak self] _ in
                    self?.fail("Камера 0,5× занята или недоступна. Выбери AR 1× либо повтори запуск.",token:token)
                }
                self.capture.startRunning()
                let startedAt=CACurrentMediaTime()
                let watchdog=DispatchSource.makeTimerSource(queue:self.queue)
                watchdog.schedule(deadline:.now()+1,repeating:1)
                watchdog.setEventHandler { [weak self] in
                    guard let self, self.isCurrent(token) else { return }
                    self.lock.lock();let received=self.receivedFrame;let last=self.lastFrameAt;self.lock.unlock()
                    let now=CACurrentMediaTime()
                    if (!received && now-startedAt>6) || (received && now-last>1.5) {
                        self.fail("Нет свежих кадров камеры 0,5× или данных движения. Выбери AR 1× либо повтори вход.",token:token)
                    }
                }
                self.watchdog=watchdog;watchdog.resume()
            } catch { self.fail(error.localizedDescription,token:token) }
        }
    }

    func stop(completion: (() -> Void)? = nil) {
        lock.lock();running=false;generation=UUID();poses=[];heading=nil;lock.unlock()
        queue.async { [self] in
            shutdown()
            if let completion { DispatchQueue.main.async(execute:completion) }
        }
    }
    // Hardware operations stay on the session queue. Failure cleanup must not
    // invalidate a newer run that was requested while an old callback was pending.
    private func shutdown() {
        watchdog?.cancel();watchdog=nil
        motion.stopDeviceMotionUpdates()
        if capture.isRunning { capture.stopRunning() }
        if let errorObserver { NotificationCenter.default.removeObserver(errorObserver) };errorObserver=nil
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) };interruptionObserver=nil
        output?.setSampleBufferDelegate(nil,queue:nil)
        output=nil
        capture.beginConfiguration()
        for input in capture.inputs { capture.removeInput(input) }
        for output in capture.outputs { capture.removeOutput(output) }
        capture.commitConfiguration()
    }
    private func isCurrent(_ token: UUID) -> Bool {
        lock.lock();defer{lock.unlock()};return running && generation == token
    }
    private func fail(_ message: String, token: UUID) {
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard self.running && self.generation == token else { self.lock.unlock();return }
            self.running=false;let handler=self.failureHandler;self.lock.unlock()
            self.shutdown()
            handler?(message)
        }
    }
    private func configure() throws {
        // Camera is video-only. Leave the movie playback audio session alone.
        capture.automaticallyConfiguresApplicationAudioSession = false
        guard let device=AVCaptureDevice.default(.builtInUltraWideCamera,for:.video,position:.back),motion.isDeviceMotionAvailable else {
            throw captureError("Камера 0,5× недоступна на этом iPhone. Выбери AR 1×.")
        }
        capture.beginConfiguration();var configuring=true;defer{if configuring { capture.commitConfiguration() }}
        capture.automaticallyConfiguresApplicationAudioSession=false
        for old in capture.inputs { capture.removeInput(old) }
        for old in capture.outputs { capture.removeOutput(old) }
        if capture.canSetSessionPreset(.hd1280x720) { capture.sessionPreset = .hd1280x720 }
        let input=try AVCaptureDeviceInput(device:device)
        guard capture.canAddInput(input) else { throw captureError("Не удалось открыть камеру 0,5×.") }
        capture.addInput(input)
        let next=AVCaptureVideoDataOutput()
        guard capture.canAddOutput(next) else { throw captureError("Не удалось подключить видео 0,5×.") }
        capture.addOutput(next)
        guard next.availableVideoPixelFormatTypes.contains(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) else {
            throw captureError("Формат камеры 0,5× не поддерживается. Выбери AR 1×.")
        }
        next.videoSettings=[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        next.alwaysDiscardsLateVideoFrames=true
        next.setSampleBufferDelegate(self,queue:queue);output=next
        if let connection=next.connection(with:.video) {
            if connection.isVideoRotationAngleSupported(0) { connection.videoRotationAngle=0 }
            if connection.isVideoMirroringSupported { connection.automaticallyAdjustsVideoMirroring=false;connection.isVideoMirrored=false }
            if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .off }
            if connection.isCameraIntrinsicMatrixDeliverySupported { connection.isCameraIntrinsicMatrixDeliveryEnabled=true }
        }
        capture.commitConfiguration();configuring=false
        try device.lockForConfiguration();defer{device.unlockForConfiguration()}
        guard device.minAvailableVideoZoomFactor<=1,device.maxAvailableVideoZoomFactor>=1 else {
            throw captureError("Полный угол камеры 0,5× недоступен. Выбери AR 1×.")
        }
        device.videoZoomFactor=1
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        if device.isGeometricDistortionCorrectionSupported { device.isGeometricDistortionCorrectionEnabled=true }
        if device.activeFormat.videoSupportedFrameRateRanges.contains(where:{$0.minFrameRate<=30 && $0.maxFrameRate>=30}) {
            device.activeVideoMinFrameDuration=CMTime(value:1,timescale:30)
            device.activeVideoMaxFrameDuration=CMTime(value:1,timescale:30)
        }
        fallbackFOV=device.isGeometricDistortionCorrectionEnabled ? device.activeFormat.geometricDistortionCorrectedVideoFieldOfView : device.activeFormat.videoFieldOfView
    }
    private func captureError(_ message: String) -> NSError {
        NSError(domain:"HandARCamera",code:1,userInfo:[NSLocalizedDescriptionKey:message])
    }
    private func orientation(at time: Double) -> simd_quatf? {
        lock.lock();let history=poses;lock.unlock()
        guard let closest=history.min(by:{abs($0.0-time)<abs($1.0-time)}),abs(closest.0-time)<=0.15 else { return nil }
        if let before=history.last(where:{$0.0<=time}),let after=history.first(where:{$0.0>time}),after.0-before.0>0 {
            return simd_slerp(before.1,after.1,Float((time-before.0)/(after.0-before.0)))
        }
        return closest.1
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        lock.lock();let token=generation;let active=running;lock.unlock()
        guard active, output === self.output, let image=CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time=CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        guard time.isFinite, let orientation=orientation(at:time) else { return }
        var intrinsics: simd_float3x3?
        if let data=CMGetAttachment(sampleBuffer,key:kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,attachmentModeOut:nil) as? Data,
           data.count>=MemoryLayout<simd_float3x3>.size {
            intrinsics=data.withUnsafeBytes{$0.loadUnaligned(as:simd_float3x3.self)}
        }
        if intrinsics == nil {
            let w=Float(CVPixelBufferGetWidth(image)),h=Float(CVPixelBufferGetHeight(image))
            guard fallbackFOV>0,fallbackFOV<179 else { return }
            let focal=w/(2*tan(fallbackFOV * .pi/360))
            intrinsics=simd_float3x3(columns:(SIMD3(focal,0,0),SIMD3(0,focal,0),SIMD3(w*0.5,h*0.5,1)))
        }
        guard let intrinsics, intrinsics[0][0]>0, intrinsics[1][1]>0, isCurrent(token) else { return }
        let frame=CameraFrame(image:image,intrinsics:intrinsics,transform:simd_float4x4(orientation),timestamp:time)
        guard frame.projection != nil else { return }
        lock.lock()
        guard running && generation == token else { lock.unlock();return }
        receivedFrame=true;lastFrameAt=CACurrentMediaTime();lock.unlock()
        onFrame?(frame)
    }
}
