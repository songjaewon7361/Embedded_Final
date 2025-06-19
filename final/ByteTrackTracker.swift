//
//  ByteTrackTracker.swift
//  capstone2
//
//  Created by You on 2025/06/XX.
//

import Foundation
import CoreGraphics
import Combine

// MARK: — TrackerConfig

/// 트래커 동작 파라미터
struct TrackerConfig {
    let highThresh: Float      // High‐confidence 임계값
    let lowThresh: Float       // Low‐confidence 임계값
    let iouThreshold: CGFloat  // IoU 매칭 임계값
    let trackBuffer: Int       // 유실 트랙 유지 프레임 수

    static let `default` = TrackerConfig(
        highThresh: 0.5,
        lowThresh: 0.1,
        iouThreshold: 0.8,
        trackBuffer: 30
    )
}


// MARK: — KalmanFilter

/// 칼만 필터 예측(predict) + 보정(correct)
class KalmanFilter {
    private var state = SIMD4<Double>(repeating: 0)  // [x, y, vx, vy]
    private var size = CGSize.zero

    init(initialRect: CGRect) {
        state.x = Double(initialRect.midX)
        state.y = Double(initialRect.midY)
        size = initialRect.size
    }

    func predict(dt: Double = 1.0/30.0) {
        state.x += state.z * dt
        state.y += state.w * dt
    }

    func correct(measurement: CGRect) {
        state.x = Double(measurement.midX)
        state.y = Double(measurement.midY)
        size = measurement.size
    }

    var predictedRect: CGRect {
        CGRect(
            x: CGFloat(state.x) - size.width/2,
            y: CGFloat(state.y) - size.height/2,
            width: size.width,
            height: size.height
        )
    }
}


// MARK: — TrackState

/// 트랙 상태 머신
enum TrackState {
    case tentative
    case confirmed
    case lost
}


// MARK: — Track 모델

struct Track: Identifiable {
    let id: Int
    var boundingBox: CGRect   // normalized 0~1
    var lostCount: Int = 0
    var age: Int = 1
    var state: TrackState = .tentative
    var kf: KalmanFilter

    init(id: Int, bbox: CGRect) {
        self.id = id
        self.boundingBox = bbox
        self.kf = KalmanFilter(initialRect: bbox)
    }

    /// 두 박스 간 IoU 계산
    static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        let ia = inter.width * inter.height
        let ua = a.width * a.height + b.width * b.height - ia
        return ua > 0 ? ia/ua : 0
    }
}


// MARK: — TrackMatcher 프로토콜

/// 트랙 ↔ 검출 결과 매칭 전략 추상화
protocol TrackMatcher {
    /// - Returns: (트랙 인덱스, 검출 인덱스) 매칭 쌍 배열
    func match(
        tracks: [Track],
        detections: [DetectedObject],
        config: TrackerConfig
    ) -> [(trackIndex: Int, detectionIndex: Int)]
}


// MARK: — HungarianSolver (Munkres 알고리즘)

fileprivate struct HungarianSolver {
    static func solve(costMatrix: [[CGFloat]]) -> [(Int, Int)] {
        let rowCount = costMatrix.count
        let colCount = costMatrix.first?.count ?? 0
        let n = max(rowCount, colCount)

        // 1) 정사각 패딩
        let maxVal = (costMatrix.flatMap { $0 }.max() ?? 0) + 1
        var matrix = Array(
            repeating: Array(repeating: maxVal, count: n),
            count: n
        )
        for i in 0..<rowCount {
            for j in 0..<colCount {
                matrix[i][j] = costMatrix[i][j]
            }
        }

        // 2) 행-열 최소값 빼기
        for i in 0..<n {
            let minRow = matrix[i].min() ?? 0
            for j in 0..<n { matrix[i][j] -= minRow }
        }
        for j in 0..<n {
            let minCol = (0..<n).map { matrix[$0][j] }.min() ?? 0
            for i in 0..<n { matrix[i][j] -= minCol }
        }

        // 3) 마스크와 커버
        var mask = Array(repeating: Array(repeating: 0, count: n), count: n)
        var rowCover = Array(repeating: false, count: n)
        var colCover = Array(repeating: false, count: n)

        // 4) Star 0s
        for i in 0..<n {
            for j in 0..<n {
                if matrix[i][j] == 0 && !rowCover[i] && !colCover[j] {
                    mask[i][j] = 1
                    rowCover[i] = true
                    colCover[j] = true
                }
            }
        }
        rowCover = Array(repeating: false, count: n)
        colCover = Array(repeating: false, count: n)

        func coverCount() -> Int {
            colCover.filter { $0 }.count
        }
        func findZero() -> (Int,Int)? {
            for i in 0..<n where !rowCover[i] {
                for j in 0..<n where !colCover[j] {
                    if matrix[i][j] == 0 {
                        return (i,j)
                    }
                }
            }
            return nil
        }
        func minUncovered() -> CGFloat {
            var m = CGFloat.greatestFiniteMagnitude
            for i in 0..<n where !rowCover[i] {
                for j in 0..<n where !colCover[j] {
                    m = min(m, matrix[i][j])
                }
            }
            return m
        }

        // 5) 알고리즘 반복
        while coverCount() < n {
            if let (r,c) = findZero() {
                mask[r][c] = 2  // prime
                if let starCol = mask[r].firstIndex(of: 1) {
                    rowCover[r] = true
                    colCover[starCol] = false
                } else {
                    // augmenting path
                    var path = [(r,c)]
                    while true {
                        let (pr, pc) = path.last!
                        // find star in this column
                        if let sr = mask.firstIndex(where: { $0[pc] == 1 }) {
                            path.append((sr,pc))
                        } else { break }
                        // find prime in this row
                        let (lr, _) = path.last!
                        if let pc2 = mask[lr].firstIndex(of: 2) {
                            path.append((lr,pc2))
                        } else { break }
                        if mask[path.last!.0][path.last!.1] == 2 { break }
                    }
                    // flip along path
                    for (rr, cc) in path {
                        mask[rr][cc] = (mask[rr][cc] == 1) ? 0 : 1
                    }
                    // clear covers and primes
                    rowCover = Array(repeating: false, count: n)
                    colCover = Array(repeating: false, count: n)
                    for i in 0..<n {
                        for j in 0..<n where mask[i][j] == 2 {
                            mask[i][j] = 0
                        }
                    }
                    // cover starred cols
                    for i in 0..<n {
                        for j in 0..<n where mask[i][j] == 1 {
                            colCover[j] = true
                        }
                    }
                }
            } else {
                // adjust matrix
                let m = minUncovered()
                for i in 0..<n {
                    for j in 0..<n {
                        if rowCover[i] { matrix[i][j] += m }
                        if !colCover[j] { matrix[i][j] -= m }
                    }
                }
            }
        }

        // 6) collect matches
        var results = [(Int,Int)]()
        for i in 0..<rowCount {
            for j in 0..<colCount where mask[i][j] == 1 {
                results.append((i,j))
            }
        }
        return results
    }
}


// MARK: — HungarianMatcher

/// 최적 matching 위해 헝가리안 사용
class HungarianMatcher: TrackMatcher {
    func match(
        tracks: [Track],
        detections: [DetectedObject],
        config: TrackerConfig
    ) -> [(trackIndex: Int, detectionIndex: Int)] {
        let n = tracks.count, m = detections.count
        guard n>0 && m>0 else { return [] }

        // cost = 1 - IoU
        let cost: [[CGFloat]] = tracks.map { tr in
            detections.map { dt in 1 - Track.iou(tr.boundingBox, dt.boundingBox) }
        }

        return HungarianSolver.solve(costMatrix: cost)
    }
}


// MARK: — ImprovedByteTrackTracker

/// 헝가리안+칼만+상태머신+버퍼 통합 트래커
class ImprovedByteTrackTracker: ObservableObject {
    @Published private(set) var tracksList: [Track] = []
    private var tracksMap = [Int: Track]()
    private var nextID = 0

    private let matcher: TrackMatcher
    private let config: TrackerConfig

    init(
        config: TrackerConfig = .default,
        matcher: TrackMatcher = HungarianMatcher()
    ) {
        self.config = config
        self.matcher = matcher
    }

    /// detections 입력 → tracksList 갱신
    func update(detections: [DetectedObject]) -> [Track] {
        // 1) predict
        for (id, var t) in tracksMap {
            t.kf.predict()
            t.boundingBox = t.kf.predictedRect
            tracksMap[id] = t
        }

        // 2) match
        let current = Array(tracksMap.values)
        let matches = matcher.match(
            tracks: current,
            detections: detections,
            config: config
        )
        var usedTracks = Set<Int>(), usedDets = Set<Int>()
        for (ti, di) in matches {
            let trackID = current[ti].id
            var t = tracksMap[trackID]!
            let bbox = detections[di].boundingBox
            t.kf.correct(measurement: bbox)
            t.boundingBox = bbox
            t.lostCount = 0
            t.age += 1
            if t.state == .tentative && t.age >= 3 {
                t.state = .confirmed
            }
            tracksMap[trackID] = t
            usedTracks.insert(trackID)
            usedDets.insert(di)
        }

        // 3) unmatched tracks → lostCount++, remove if lost
        for (id, var t) in tracksMap {
            if !usedTracks.contains(id) {
                t.lostCount += 1
                if t.lostCount >= config.trackBuffer {
                    t.state = .lost
                }
                tracksMap[id] = t
            }
        }
        tracksMap = tracksMap.filter { $0.value.state != .lost }

        // 4) create new for unmatched high‐conf detections
        for (i, det) in detections.enumerated() where det.confidence >= config.highThresh {
            if !usedDets.contains(i) {
                let t = Track(id: nextID, bbox: det.boundingBox)
                tracksMap[nextID] = t
                nextID += 1
            }
        }

        // 5) publish
        tracksList = Array(tracksMap.values)
        return tracksList
    }
}
