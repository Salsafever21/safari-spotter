import SwiftUI

struct PhotoExportStatusView: View {
    @ObservedObject var exporter: PhotoExportController
    @State private var confirmDiscard = false

    var body: some View {
        status.alert("Offenen Export beenden?", isPresented: $confirmDiscard) {
            Button("Exportauftrag beenden") { exporter.discardFailedJob() }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Die noch offenen Fotos werden nicht weiter gesichert. Alle Originalfotos bleiben in Safari Spotter. Bereits in Fotos gesicherte Kopien bleiben erhalten.")
        }
    }

    @ViewBuilder private var status: some View {
        if exporter.isRunning {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: Double(exporter.completed), total: Double(max(1, exporter.total)))
                Text("\(exporter.completed) von \(exporter.total) Fotos gesichert")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else if let message = exporter.lastError {
            VStack(alignment: .leading, spacing: 8) {
                Text(message).font(.caption).foregroundStyle(.orange)
                if exporter.canRetry {
                    Button("Restliche \(exporter.remainingCount) Fotos erneut versuchen") { exporter.retry() }
                        .buttonStyle(.bordered)
                }
                if exporter.hasPendingJob {
                    Button("Offenen Export beenden") { confirmDiscard = true }.buttonStyle(.bordered)
                }
            }
        } else if exporter.total > 0 && exporter.completed == exporter.total {
            Text("Letzter Export: \(exporter.completed) \(exporter.completed == 1 ? "Foto" : "Fotos") in der Mediathek gesichert.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
