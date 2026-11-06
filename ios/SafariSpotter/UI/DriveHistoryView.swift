import SwiftUI
import MapKit
import UIKit

/// Gesamtkarte und Einstieg in jede gespeicherte Fahrt. Einzelne Routen stehen in der jeweiligen Fahrt.
struct DriveHistoryView: View {
    let sightings: [Sighting]
    let photos: [PhotoItem]
    let drives: [Drive]
    @EnvironmentObject private var drive: DriveRecorder
    @EnvironmentObject private var settings: AppSettings
    @State private var showLive = false
    @State private var showMap = false

    var body: some View {
        List {
            if drive.active {
                Section {
                    Button { showLive = true } label: {
                        Label("Laufenden Game Drive öffnen", systemImage: "location.fill")
                    }
                }
            }
            Section("Alle Aufnahmen") {
                SightingRouteMap(points: [], sightings: sightings, photos: photos, viewer: .constant(nil),
                                 currentCoordinate: settings.gps ? drive.lastFix?.coordinate : nil)
                    .frame(height: 320)
                    .allowsHitTesting(false).accessibilityHidden(true)
                Button("Karte öffnen") { showMap = true }
                Text("Alle Tage · \(sightings.reduce(0) { $0 + $1.n }) Tiere · \(photos.count) Fotos")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Wähle einen Game Drive für seine Route, Stopps und Aufnahmen. Nashorn-Standorte erscheinen als 10-km-Kreis.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Gespeicherte Game Drives") {
                if drives.isEmpty {
                    Text("Noch keine abgeschlossene Fahrt. Starte einen Game Drive im Kamerabildschirm.")
                        .foregroundStyle(.secondary)
                }
                ForEach(drives) { saved in
                    NavigationLink {
                        SavedDriveView(saved: saved, allSightings: sightings, allPhotos: photos)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(fmtDate(saved.startedAt)) · \(fmtTime(saved.startedAt))–\(fmtTime(saved.endedAt))")
                                .font(.headline)
                            Text("\(fmtKm(saved.dist)) km · \(fmtClock(max(0, saved.endedAt.timeIntervalSince(saved.startedAt))))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("saved-drive-\(saved.id.uuidString)")
                }
            }
        }
        .sheet(isPresented: $showMap) {
            RouteMapSheet(title: "Alle Aufnahmen", points: [], sightings: sightings, photos: photos,
                          currentCoordinate: settings.gps ? drive.lastFix?.coordinate : nil)
        }
        .sheet(isPresented: $showLive) { DriveLiveView(sightings: sightings) }
    }
}

struct SavedDriveView: View {
    let saved: Drive
    let allSightings: [Sighting]
    let allPhotos: [PhotoItem]
    @EnvironmentObject private var catalog: SpeciesCatalog
    @State private var route: [TrackPoint]?
    @State private var routeError: String?
    @State private var actionError: String?
    @State private var viewer: PhotoItem?
    @State private var share: DriveShare?
    @State private var showMap = false

    private var window: DriveWindow? { try? DriveWindow(start: saved.startedAt, end: saved.endedAt) }
    private var sightings: [Sighting] { window?.sightings(from: allSightings) ?? [] }
    private var photos: [PhotoItem] { window?.photos(from: allPhotos) ?? [] }
    private var stats: DriveStats? {
        guard let route, !route.isEmpty else { return nil }
        return DriveStats.compute(points: route, startedAt: saved.startedAt, endedAt: saved.endedAt,
                                  dist: saved.dist, sightings: sightings)
    }

    var body: some View {
        List {
            Section {
                Text("\(fmtDate(saved.startedAt)) · \(fmtTime(saved.startedAt)) bis \(fmtDate(saved.endedAt)) · \(fmtTime(saved.endedAt))")
                    .font(.subheadline)
                HStack {
                    tile(fmtKm(saved.dist), "km")
                    tile(fmtClock(max(0, saved.endedAt.timeIntervalSince(saved.startedAt))), "Dauer")
                    tile("\(sightings.reduce(0) { $0 + $1.n })", "Tiere")
                }
                let speciesCount = Set(sightings.map(\.name)).count
                Text("\(speciesCount) \(speciesCount == 1 ? "Art" : "Arten") · \(photos.count) \(photos.count == 1 ? "Foto" : "Fotos") aus diesem Zeitraum")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Route und Aufnahmen dieser Fahrt") {
                if let routeError {
                    Text(routeError).foregroundStyle(.orange)
                    Button("Route erneut laden", action: loadRoute)
                } else if let route {
                    SightingRouteMap(points: route, sightings: sightings, photos: photos, viewer: .constant(nil))
                        .frame(height: 320)
                        .allowsHitTesting(false).accessibilityHidden(true)
                    Button("Karte öffnen") { showMap = true }
                    if route.isEmpty { Text("Für diese Fahrt sind keine GPS-Punkte gespeichert.").font(.caption).foregroundStyle(.secondary) }
                } else { ProgressView("Route laden …") }
                Text("Sichtungen und Fotos sind nach Aufnahmezeit zugeordnet. Nashorn-Standorte werden nur als 10-km-Kreis gezeigt.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let stats {
                Section("Fahrtstatistik") {
                    HStack { tile(fmtDur(stats.moving), "in Fahrt"); tile(fmtDur(stats.standing), "Standzeit"); tile("\(stats.stops.count)", "Stopps") }
                    HStack { tile("\(Int(stats.avgMoving * 3.6))", "km/h in Fahrt"); tile("\(Int(stats.maxSpeed * 3.6))", "km/h max"); tile("\(Int(stats.elev))", "Höhenmeter") }
                }
                if !stats.stops.isEmpty {
                    Section("Stopps mit Sichtungen") {
                        ForEach(Array(stats.stops.enumerated()), id: \.offset) { index, stop in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Stopp \(index + 1) · \(fmtTime(stop.t0)) · \(fmtDur(stop.dur)) h")
                                Text(stop.sightings.isEmpty ? "keine Sichtung" : stop.sightings.map { "\($0.name) \($0.n)×" }.joined(separator: ", "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if !stats.splits.isEmpty {
                    Section("Kilometer-Splits") {
                        ForEach(Array(stats.splits.enumerated()), id: \.offset) { _, split in
                            HStack { Text("km \(split.km) · \(fmtTime(split.at))"); Spacer(); Text(fmtClock(split.time)).monospacedDigit() }
                        }
                    }
                }
            }
            Section("Sichtungen dieser Fahrt") {
                if sightings.isEmpty { Text("Keine Sichtungen in diesem Zeitraum.").foregroundStyle(.secondary) }
                ForEach(sightings) { sighting in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(sighting.name).font(.headline)
                            Text(sighting.coarse ? "Standort ±10 km (Artenschutz)" : fmtTime(sighting.t))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(sighting.n)×").monospacedDigit()
                    }
                }
            }
            if !photos.isEmpty {
                Section("Fotos dieser Fahrt") {
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 8) {
                            ForEach(photos) { photo in
                                Button { viewer = photo } label: {
                                    VStack {
                                        if let image = UIImage(data: photo.thumb ?? photo.image) {
                                            Image(uiImage: image).resizable().scaledToFill().frame(width: 88, height: 88).clipped()
                                        }
                                        Text(photo.species.first ?? "Foto").font(.caption).lineLimit(1)
                                    }.frame(width: 88)
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            Section("Diese Fahrt exportieren") {
                Button { export(gpx: true) } label: { Label("GPX dieser Fahrt teilen", systemImage: "map") }
                    .disabled(route == nil || routeError != nil)
                Button { export(gpx: false) } label: { Label("Sichtungen dieser Fahrt als CSV teilen", systemImage: "tablecells") }
                    .disabled(window == nil)
                Text("Die GPX-Datei enthält nur diese Fahrt. Spurpunkte in der Nähe von Nashorn-Sichtungen werden ausgelassen; Nashorn-Zeiten und Standorte bleiben gerundet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Game Drive")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: saved.id) { loadRoute() }
        .sheet(item: $viewer) { photo in PhotoViewer(photo: photo, photos: photos) }
        .sheet(isPresented: $showMap) {
            RouteMapSheet(title: "Fahrtkarte", points: route ?? [], sightings: sightings, photos: photos)
        }
        .sheet(item: $share) { item in
            FileShareSheet(url: item.url) {
                try? FileManager.default.removeItem(at: item.url)
                share = nil
            }.interactiveDismissDisabled()
        }
        .alert("Export fehlgeschlagen", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK") {}
        } message: { Text(actionError ?? "") }
    }

    private func loadRoute() {
        do {
            let window = try DriveWindow(start: saved.startedAt, end: saved.endedAt)
            route = window.points(from: try saved.decodedPoints())
            routeError = nil
        } catch {
            route = nil
            routeError = "Die gespeicherte Route kann nicht gelesen werden: \(error.localizedDescription). Die Originaldaten bleiben erhalten."
        }
    }

    private func export(gpx: Bool) {
        do {
            try DriveHistoryExport.removeStale()
            let content: String
            if gpx { content = try DriveHistoryExport.gpx(drive: saved, sightings: allSightings, catalog: catalog) }
            else { content = try DriveHistoryExport.csv(drive: saved, sightings: allSightings, catalog: catalog) }
            share = DriveShare(url: try DriveHistoryExport.createFile(content, extension: gpx ? "gpx" : "csv"))
        } catch { actionError = error.localizedDescription }
    }

    private func tile(_ value: String, _ title: String) -> some View {
        VStack { Text(value).font(.title3.monospacedDigit().bold()); Text(title).font(.caption).foregroundStyle(.secondary) }
            .frame(maxWidth: .infinity)
    }
}

private struct DriveShare: Identifiable { let url: URL; var id: URL { url } }

private struct RouteMapSheet: View {
    let title: String
    let points: [TrackPoint]
    let sightings: [Sighting]
    let photos: [PhotoItem]
    var currentCoordinate: CLLocationCoordinate2D? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var viewer: PhotoItem?

    var body: some View {
        NavigationStack {
            SightingRouteMap(points: points, sightings: sightings, photos: photos, viewer: $viewer,
                             currentCoordinate: currentCoordinate)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Schliessen") { dismiss() } } }
        }
        .sheet(item: $viewer) { photo in PhotoViewer(photo: photo, photos: photos) }
    }
}

private struct SightingRouteMap: View {
    let points: [TrackPoint]
    let sightings: [Sighting]
    let photos: [PhotoItem]
    @Binding var viewer: PhotoItem?
    var currentCoordinate: CLLocationCoordinate2D? = nil
    @EnvironmentObject private var catalog: SpeciesCatalog

    private var sightingPins: [SightingPin] {
        sightings.compactMap { sighting -> SightingPin? in
            guard let position = LocationProtection.protectedPosition(lat: sighting.lat, lon: sighting.lon,
                coarse: sighting.coarse, sensitive: catalog.isSensitive(name: sighting.name)) else { return nil }
            return SightingPin(sighting: sighting, position: position)
        }
    }

    private var photoPins: [PhotoPin] {
        photos.compactMap { photo -> PhotoPin? in
            let sensitive = LocationProtection.containsSensitive(photo.species.map { $0 as String? } + photo.dets.map(\.name),
                                                                 isSensitive: catalog.isSensitive)
            guard let position = LocationProtection.protectedPosition(lat: photo.lat, lon: photo.lon,
                coarse: photo.coarse, sensitive: sensitive) else { return nil }
            return PhotoPin(photo: photo, position: position)
        }
    }

    var body: some View {
        Map {
            if points.count > 1 { MapPolyline(coordinates: points.map(\.coordinate)).stroke(Color.accentColor, lineWidth: 4) }
            ForEach(photoPins) { pin in
                let photo = pin.photo
                Annotation(photo.species.first ?? "Foto", coordinate: pin.coordinate) {
                    Button { viewer = photo } label: {
                        if let bytes = photo.thumb, let image = UIImage(data: bytes) {
                            Image(uiImage: image).resizable().scaledToFill().frame(width: 40, height: 40)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(pin.position.coarse ? Color.red : Color.white, lineWidth: 2))
                        } else { Image(systemName: "photo.fill").padding(8).background(.black, in: Circle()) }
                    }
                }
            }
            ForEach(sightingPins.filter { !$0.position.coarse }) { pin in
                Annotation(pin.sighting.name, coordinate: pin.coordinate) {
                    Circle().fill(.green).frame(width: 12, height: 12).overlay(Circle().stroke(.black, lineWidth: 1))
                }
            }
            ForEach(sightingPins.filter { $0.position.coarse }) { pin in
                MapCircle(center: pin.coordinate, radius: 10000).foregroundStyle(Color.red.opacity(0.08)).stroke(Color.red, lineWidth: 1.5)
            }
            if let currentCoordinate {
                Annotation("Aktueller Standort", coordinate: currentCoordinate) {
                    Circle().fill(.cyan).frame(width: 14, height: 14).overlay(Circle().stroke(.white, lineWidth: 2))
                }
            }
        }
    }
}

private struct SightingPin: Identifiable {
    let sighting: Sighting
    let position: (lat: Double, lon: Double, coarse: Bool)
    var id: UUID { sighting.id }
    var coordinate: CLLocationCoordinate2D { .init(latitude: position.lat, longitude: position.lon) }
}

private struct PhotoPin: Identifiable {
    let photo: PhotoItem
    let position: (lat: Double, lon: Double, coarse: Bool)
    var id: UUID { photo.id }
    var coordinate: CLLocationCoordinate2D { .init(latitude: position.lat, longitude: position.lon) }
}
