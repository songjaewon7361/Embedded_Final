// 생략된 import는 그대로 유지
import SwiftUI
import Vision
import AVFoundation
import CoreImage

struct CameraView: View {
    // MARK: - 의존 객체
    @StateObject private var sessionManager = CameraSessionManager()
    @StateObject private var tracker        = ImprovedByteTrackTracker()
    @StateObject private var speechSynthObj = SpeechSynthWrapper()

    // MARK: - 상태 값
    @State private var currentTracks: [Track] = []
    @State private var ocrTexts:     [Int: String] = [:]
    @State private var ocrAttempts:  [Int: Int]    = [:]
    @State private var debounce:     [Int: Int]    = [:]
    @State private var spokenTracks: Set<Int>      = []
    @State private var appearedFrames: [Int: Int]  = [:]
    @State private var frameCount = 0

    private let maxOCRAttempts  = 3
    private let retryInterval   = 15
    private let ciContext = CIContext(options: [.priorityRequestLow: true])

    init() {
        configureAudioSession()
    }

    // MARK: - 바디
    var body: some View {
        GeometryReader { geo in
            ZStack {
                // 실시간 카메라 프리뷰
                CameraPreview(session: sessionManager.getSession())
                    .ignoresSafeArea()

                // 바운딩박스 및 라벨 오버레이
                ForEach(currentTracks, id: \.id) { track in
                    overlay(for: track, in: geo)
                }
            }
            // Vision 탐지 결과 수신
            .onReceive(sessionManager.$detections) { detections in
                handleDetections(detections)
            }
        }
    }
}

// MARK: - 오디오 세션
private extension CameraView {
    func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback,
                                    mode: .spokenAudio,
                                    options: [.duckOthers, .mixWithOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("🛑 AudioSession 설정 실패:", error)
        }
    }
}

// MARK: - 오버레이 UI
private extension CameraView {
    @ViewBuilder
    func overlay(for track: Track, in geo: GeometryProxy) -> some View {
        // Vision → 화면 좌표 변환
        let rect = VNImageRectForNormalizedRect(track.boundingBox,
                                                Int(geo.size.width),
                                                Int(geo.size.height))

        // 바운딩 박스
        Rectangle()
            .stroke(.green, lineWidth: 2)
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)

        // 트랙 ID
        Text("ID \(track.id)")
            .font(.caption2).bold()
            .foregroundColor(.green)
            .padding(4)
            .background(Color.black.opacity(0.6))
            .position(x: rect.minX + 40, y: rect.minY + 12)

        // 객체 분류 라벨 (Vision 탐지 결과)
        if let det = detection(for: track) {
            Text("\(det.label) \(String(format: "%.2f", det.confidence))")
                .font(.caption2)
                .foregroundColor(.white)
                .padding(4)
                .background(Color.black.opacity(0.6))
                .position(x: rect.midX, y: rect.minY - 12)
        }

        // OCR 결과 / 라벨 없음 표시
        let tries = ocrAttempts[track.id] ?? 0
        if tries > 0 {
            let raw = ocrTexts[track.id] ?? ""
            let display = raw.isEmpty && tries >= maxOCRAttempts ? "라벨 없음" : raw
            let color: Color = raw.isEmpty ? .blue : .yellow

            Text(display)
                .font(.caption2)
                .foregroundColor(color)
                .padding(4)
                .background(Color.black.opacity(0.6))
                .position(x: rect.midX, y: rect.maxY + 12)
        }
    }

    /// Vision 탐지 결과와 ByteTrack 트랙을 매칭
    func detection(for track: Track) -> DetectedObject? {
        sessionManager.detections.first {
            abs($0.boundingBox.midX - track.boundingBox.midX) < 0.01 &&
            abs($0.boundingBox.midY - track.boundingBox.midY) < 0.01
        }
    }
}

// MARK: - 탐지 처리 & OCR / TTS
private extension CameraView {
    func handleDetections(_ detections: [DetectedObject]) {
        guard let buffer = sessionManager.currentBuffer else { return }

        frameCount += 1
        currentTracks = tracker.update(detections: detections)

        for track in currentTracks {
            let id        = track.id
            let lifetime  = frameCount - appearedFrames[id, default: frameCount]
            let hasText   = !(ocrTexts[id] ?? "").isEmpty
            let attempts  = ocrAttempts[id] ?? 0

            // 최초 등장 프레임 기록
            appearedFrames[id] = appearedFrames[id] ?? frameCount

            // 📸 OCR 시도 (maxOCRAttempts 회까지, retryInterval 프레임마다)
            if !hasText,
               attempts < maxOCRAttempts,
               frameCount % retryInterval == 0 {

                ocrAttempts[id] = attempts + 1

                performOCR(on: buffer, in: track.boundingBox) { text in
                    DispatchQueue.main.async {
                        let prev = ocrTexts[id] ?? ""
                        ocrTexts[id] = text
                        debounce[id] = (text == prev && !text.isEmpty)
                                       ? debounce[id, default: 0] + 1 : 1

                        // OCR 직후 TTS (라벨 유/무 둘 다 가능)
                        if !spokenTracks.contains(id), lifetime >= 60,
                           let msg = speakMessage(for: track, hasLabel: !text.isEmpty) {

                            print("🗣️ OCR 직후 TTS: \(msg)")
                            speechSynthObj.speak(msg)
                            spokenTracks.insert(id)
                        }
                    }
                }
            }

            // ✅ 라벨이 이미 인식된 경우 → TTS(중복 방지)
            if hasText,
               !spokenTracks.contains(id),
               lifetime >= 30,
               let msg = speakMessage(for: track, hasLabel: true) {

                print("🗣️ OCR 성공 후 TTS 실행: \(msg)")
                speechSynthObj.speak(msg)
                spokenTracks.insert(id)
            }

            // ✨ **OCR 최종 실패 fallback** --------------------------
            // OCR을 maxOCRAttempts 번 시도했지만 여전히 텍스트가 없을 때,
            // TTS가 한 번도 나오지 않았다면 라벨 없음 메시지를 출력
            if !hasText,
               attempts >= maxOCRAttempts,
               !spokenTracks.contains(id),
               lifetime >= 30,
               let msg = speakMessage(for: track, hasLabel: false) {

                print("🗣️ OCR 실패 후 fallback TTS: \(msg)")
                speechSynthObj.speak(msg)
                spokenTracks.insert(id)
            }
            // ----------------------------------------------------
        }

        // 메모리 정리: 사라진 트랙 정보 제거
        let live = Set(currentTracks.map(\.id))
        ocrTexts.keep(keys: live)
        ocrAttempts.keep(keys: live)
        debounce.keep(keys: live)
        spokenTracks = spokenTracks.intersection(live)
        appearedFrames = appearedFrames.filter { live.contains($0.key) }
    }
}

// MARK: - OCR
private extension CameraView {
    func performOCR(on buffer: CVPixelBuffer,
                    in normBox: CGRect,
                    completion: @escaping (String) -> Void) {

        let ciSrc = CIImage(cvPixelBuffer: buffer)
        let w = CGFloat(CVPixelBufferGetWidth(buffer))
        let h = CGFloat(CVPixelBufferGetHeight(buffer))

        // PixelBuffer 좌표계 → crop 영역
        var crop = CGRect(x: normBox.minX * w,
                          y: normBox.minY * h,
                          width: normBox.width * w,
                          height: normBox.height * h).integral
        crop = crop.intersection(CGRect(origin: .zero, size: CGSize(width: w, height: h)))
        guard !crop.isEmpty else { completion(""); return }

        // 대비 살짝 조정
        let ciCrop = ciSrc.cropped(to: crop)
        let filt = CIFilter(name: "CIColorControls")!
        filt.setValue(ciCrop, forKey: kCIInputImageKey)
        filt.setValue(1.1, forKey: kCIInputContrastKey)
        let ciFinal = filt.outputImage ?? ciCrop

        guard let cg = ciContext.createCGImage(ciFinal, from: ciFinal.extent)
        else { completion(""); return }

        // 텍스트 인식 요청
        let req = VNRecognizeTextRequest { req, _ in
            let obs = (req.results as? [VNRecognizedTextObservation]) ?? []
            let txt = obs.first?.topCandidates(1).first?.string ?? ""
            completion(txt)
        }
        req.recognitionLevel       = .accurate
        req.usesLanguageCorrection = true
        req.recognitionLanguages   = ["ko-KR", "en-US"]

        DispatchQueue.global(qos: .userInitiated).async {
            try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
        }
    }
}

// MARK: - TTS 메시지 생성
private extension CameraView {
    /// `hasLabel` – OCR로 라벨(텍스트)이 검출되었는지 여부
    func speakMessage(for track: Track, hasLabel: Bool) -> String? {
        guard let det = detection(for: track) else { return nil }

        if det.label == "투명_pet" {
            return hasLabel
                ? "투명 페트병입니다. 라벨이 감지되었습니다. 라벨을 제거한 후, 투명 페트병 전용 수거함에 분리해 주세요."
                : "투명 페트병입니다. 투명 페트병 전용 수거함에 분리수거해 주세요."
        } else {
            return hasLabel
                ? "유색 플라스틱입니다. 라벨이 감지되었습니다. 라벨을 제거한 후, 일반 플라스틱 전용 수거함에 분리해 주세요."
                : "유색 플라스틱입니다. 일반 플라스틱 수거함에 분리수거해 주세요."
        }
    }
}

// MARK: - TTS 래퍼
final class SpeechSynthWrapper: ObservableObject {
    private let synthesizer = AVSpeechSynthesizer()

    /// 중복 발화 방지를 위해 `isSpeaking` 검사를 포함
    func speak(_ msg: String) {
        DispatchQueue.main.async {
            if self.synthesizer.isSpeaking {
                print("⛔️ 중복 발화 방지: 이미 TTS 진행 중")
                return
            }
            print("🔊 음성 출력: \(msg)")
            let utt = AVSpeechUtterance(string: msg)
            utt.voice = AVSpeechSynthesisVoice(language: "ko-KR")
            self.synthesizer.speak(utt)
        }
    }
}

// MARK: - Dictionary 확장
private extension Dictionary where Key == Int {
    /// 주어진 키 집합만 남기고 나머지 제거
    mutating func keep(keys: Set<Int>) {
        self = self.filter { keys.contains($0.key) }
    }
}
