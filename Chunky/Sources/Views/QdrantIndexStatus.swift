import SwiftUI

struct QdrantIndexStatus: View {
    @ObservedObject var service: QdrantService

    var body: some View {
        if let error = service.indexError {
            PreferenceMessage(context: "Database indexes need attention", message: error)
            Text("Search may still work. Index setup will be retried when needed; check your database permissions or connection.")
                .font(.body).foregroundStyle(.secondary)
        }
    }
}
