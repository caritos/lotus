import SwiftUI
import __APP__Kit

struct ContentView: View {
    var body: some View {
        Text(Greeting.message(for: "__DISPLAY__"))
            .padding()
    }
}
