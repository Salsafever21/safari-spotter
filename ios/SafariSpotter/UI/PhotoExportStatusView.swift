import SwiftUI

struct PhotoExportStatusView: View {
    @ObservedObject var exporter: PhotoExportController
    @State private var confirmDiscard = false
    @State private var confirmSkip = false

    var body: some View {
        status.alert("Offenen Export beenden?", isPresented: $confirmDiscard) {
            Button("Exportauftrag beenden") { exporter.discardFailedJob() }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Die noch offenen Fotos werden nicht weiter gesichert. Alle Originalfotos bleiben in Safari Spotter. Bereits in Fotos gesicherte Kopien bleiben erhalten.")
        }
        .alert("Foto überspringen?", isPresented: $confirmSkip) {
            Button("Überspringen und fortsetzen") { exporter.skipFailedPhoto() }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Dieses Foto wird nicht in Fotos gesichert. Sein Original bleibt in Safari Spotter. Der Export fährt mit den anderen Fotos fort.")
        }
    }

    @ViewBuilder private var status: some View {
        if exporter.isRunning {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: Double(exporter.completed + exporter.skippedIDs.count), total: Double(max(1, exporter.total)))
                Text("\(exporter.completed) von \(exporter.total) Fotos gesichert")
                    .font(.caption).foregroundStyle(.secondary)
                if !exporter.skippedIDs.isEmpty {
                    Text("\(exporter.skippedIDs.count) übersprungen, nicht gesichert").font(.caption).foregroundStyle(.orange)
                }
            }
        } else if let message = exporter.lastError {
            VStack(alignment: .leading, spacing: 8) {
                Text(message).font(.caption).foregroundStyle(.orange).accessibilityIdentifier("photo-export-error")
                if exporter.canRetry {
                    Button("Restliche \(exporter.remainingCount) Fotos erneut versuchen") { exporter.retry() }
                        .buttonStyle(.bordered)
                }
                if exporter.canSkip {
                    Button("Dieses Foto überspringen") { confirmSkip = true }.buttonStyle(.bordered)
                        .accessibilityIdentifier("photo-export-skip")
                }
                if exporter.hasPendingJob {
                    Button("Offenen Export beenden") { confirmDiscard = true }.buttonStyle(.bordered)
                }
            }
        } else if exporter.total > 0 && exporter.completed + exporter.skippedIDs.count == exporter.total {
            VStack(alignment: .leading, spacing: 4) {
                Text("Letzter Export: \(exporter.completed) \(exporter.completed == 1 ? "Foto" : "Fotos") in der Mediathek gesichert.")
                    .font(.caption).foregroundStyle(.secondary)
                if !exporter.skippedIDs.isEmpty {
                    Text("\(exporter.skippedIDs.count) übersprungen, nicht gesichert. Originale bleiben in der App.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }.accessibilityElement(children: .combine).accessibilityIdentifier("photo-export-summary")
        }
    }
}
