//
//  ContentView.swift
//  iSchwung
//

import SwiftUI

struct ContentView: View {
    @State private var engine = SchwungEngine()

    var body: some View {
        MoveSurfaceView(engine: engine)
            .onAppear { engine.start() }
    }
}

#Preview {
    ContentView()
}
