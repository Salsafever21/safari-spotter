import SwiftUI

struct PhotoExportStatusView: View {
    @ObservedObject var exporter: PhotoExportController

    var body: some View {
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
            }
        } else if exporter.total > 0 && exporter.completed == exporter.total {
            Text("\(exporter.completed) Fotos in der Mediathek gesichert.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
