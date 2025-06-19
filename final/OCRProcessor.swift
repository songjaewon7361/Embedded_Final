//
//  OCRProcessor.swift
//  final
//
//  Created by ky on 6/9/25.
//

// 파일경로: capstone2/capstone2/OCRProcessor.swift

import UIKit
import Vision

/// OCRProcessor: VNRecognizeTextRequest를 이용해 이미지에서 텍스트 유무만 판단
final class OCRProcessor {
    static let shared = OCRProcessor()
    private init() {}

    /// 이미지 내 텍스트가 한 글자라도 있으면 true, 없으면 false
    func hasText(in cgImage: CGImage, completion: @escaping (Bool) -> Void) {
        let request = VNRecognizeTextRequest { request, error in
            guard error == nil,
                  let observations = request.results as? [VNRecognizedTextObservation] else {
                completion(false)
                return
            }
            // 텍스트 인식 결과가 하나라도 있으면 true
            completion(!observations.isEmpty)
        }
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try handler.perform([request])
            } catch {
                print("OCR 수행 중 오류:", error)
                completion(false)
            }
        }
    }
}
