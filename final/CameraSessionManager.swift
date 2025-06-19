//
//  CameraSessionManager.swift
//  finalApp
//
//  Created by Chaeyeong Park on 2025/06/08.
//

import Foundation
import AVFoundation
import Vision
import Combine            // ← ObservableObject 프로토콜 사용을 위해 추가

/// AVCaptureSession을 세팅하고, 들어오는 각 프레임마다
/// Core ML 모델로 추론을 수행하여 결과를 @Published detections 배열에 담아줍니다.
class CameraSessionManager: NSObject, ObservableObject {
    // MARK: - 퍼블리시할 탐지 결과
    @Published var detections: [DetectedObject] = []
    
    /// 최신 프레임을 CameraView에서 OCR 용으로 꺼내 쓸 수 있도록 저장
    var currentBuffer: CVPixelBuffer?
    
    // MARK: - 내부 세션 & 출력
    private let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    
    // VNCoreMLModel 래퍼
    private var visionModel: VNCoreMLModel?
    
    override init() {
        super.init()
        // 1) Core ML 모델 로드
        visionModel = ModelLoader.loadVisionModel()
        // 2) 카메라 권한 요청 → 승인 시에만 setupSession() 호출
        requestCameraPermission()
    }
    
    /// 사용자에게 카메라 권한을 요청하고, 허용되면 세션을 시작합니다.
    private func requestCameraPermission() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard granted else {
                print("❌ 카메라 권한 거부됨")
                return
            }
            DispatchQueue.main.async {
                self?.setupSession()
            }
        }
    }
    
    /// AVCaptureSession 구성 및 시작
    private func setupSession() {
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .high
        
        // 입력: 후면 카메라
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                   for: .video,
                                                   position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              captureSession.canAddInput(input) else {
            print("❌ 카메라 입력 설정 실패")
            return
        }
        captureSession.addInput(input)
        
        // 출력: 프레임 델리게이트
        videoOutput.setSampleBufferDelegate(self,
                                            queue: DispatchQueue(label: "camera.queue"))
        videoOutput.alwaysDiscardsLateVideoFrames = true
        guard captureSession.canAddOutput(videoOutput) else {
            print("❌ 비디오 출력 추가 실패")
            return
        }
        captureSession.addOutput(videoOutput)
        
        captureSession.commitConfiguration()
        captureSession.startRunning()
    }
    
    /// SwiftUI에서 PreviewLayer에 연결하기 위해 세션 반환
    func getSession() -> AVCaptureSession {
        captureSession
    }
}

/// 화면에 보여줄 단일 탐지 결과 모델
struct DetectedObject: Identifiable {
    let id = UUID()
    let label: String
    let confidence: Float
    let boundingBox: CGRect    // 0~1로 정규화된 박스
}

extension CameraSessionManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // 1) PixelBuffer 추출
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let model = visionModel else { return }
        
        // 최신 프레임 저장 (CameraView에서 OCR 용도로 사용)
        currentBuffer = pixelBuffer
        
        // 2) Vision 요청 생성
        let request = VNCoreMLRequest(model: model) { [weak self] request, error in
            if let error = error {
                print("🛑 VNCoreMLRequest 에러:", error)
                return
            }
            guard let results = request.results as? [VNRecognizedObjectObservation] else { return }
            
            // 3) 필터링: 신뢰도 & 면적
            let minConf: VNConfidence = 0.9
            let minArea: CGFloat = 0.01  // 정규화 면적 기준 (1%)
            
            let filtered = results.compactMap { obs -> DetectedObject? in
                guard
                    let top = obs.labels.first,
                    top.confidence >= minConf,
                    obs.boundingBox.width * obs.boundingBox.height >= minArea
                else {
                    return nil
                }
                
                return DetectedObject(
                    label: top.identifier,
                    confidence: top.confidence,
                    boundingBox: obs.boundingBox
                )
            }
            
            // 4) 퍼블리시
            DispatchQueue.main.async {
                self?.detections = filtered
            }
        }
        request.imageCropAndScaleOption = .scaleFill
        
        // 5) 핸들러 수행 (.up 방향)
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: .up,
            options: [:]
        )
        do {
            try handler.perform([request])
        } catch {
            print("🛑 Vision perform 에러:", error)
        }
    }
}
