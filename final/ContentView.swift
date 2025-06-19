import SwiftUI

struct ContentView: View {
    var body: some View {
        // 카메라 실시간 추론 뷰
        CameraView()
            .edgesIgnoringSafeArea(.all)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
