//
//  ModelLoader.swift
//  finalApp
//
//  Created by Chaeyeong Park on 2025/06/08.
//

import Foundation
import CoreML
import Vision

/// Core ML 모델(.mlmodelc)을 로드해서 VNCoreMLModel을 반환합니다.
class ModelLoader {
    /// CameraSessionManager에서 사용할 Vision 모델 로더
    static func loadVisionModel() -> VNCoreMLModel? {
        // 번들에 컴파일된 모델 디렉터리(.mlmodelc)가 포함되어 있습니다.
        guard let url = Bundle.main.url(
            forResource: "best_plastic",    // 확장자 제외한 모델 이름
            withExtension: "mlmodelc"       // 컴파일된 디렉터리 확장자
        ) else {
            print("❌ 번들에서 best_plastic.mlmodelc를 찾을 수 없습니다.")
            return nil
        }

        do {
            // 1) MLModel 로드
            let mlModel = try MLModel(contentsOf: url)
            // 2) VNCoreMLModel 생성
            let visionModel = try VNCoreMLModel(for: mlModel)
            return visionModel
        } catch {
            print("❌ MLModel 또는 VNCoreMLModel 생성 중 오류:", error)
            return nil
        }
    }
}
