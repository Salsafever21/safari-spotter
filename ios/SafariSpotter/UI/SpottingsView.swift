import SwiftUI
import SwiftData

enum JournalRoute: Hashable {
    case spottings
    case species(String)
}

struct SpottingsView: View {
    let route: JournalRoute
    let showHistory: (Spottings.Entry) -> Void
    @EnvironmentObject private var catalog: SpeciesCatalog
    @Environment(\.dynamicTypeSize) private var typeSize
    @Query(sort: \Sighting.t, order: .reverse) private var sightings: [Sighting]
    @Query(sort: \PhotoItem.t, order: .reverse) private var photos: [PhotoItem]
    @State private var habitat: AnimalHabitat?
    @State private var showAllOpen = false

    var body: some View {
        let album = Spottings(sightings: sightings, catalog: catalog)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch route {
                case .spottings:
                    albumContent(album)
                case .species(let id):
                    if let entry = album.entries.first(where: { $0.id == id }) {
                        speciesContent(entry)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(JournalStyle.paper.ignoresSafeArea())
        .foregroundStyle(JournalStyle.ink)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if case .species(let id) = route, let entry = album.entries.first(where: { $0.id == id }), entry.discovered {
                Button { showHistory(entry) } label: {
                    HStack(spacing: 8) {
                        Text(entry.sightings.count == 1 ? "Sichtung ansehen" : "Alle \(entry.sightings.count) Sichtungen ansehen")
                        JournalIcon(name: "JournalArrow")
                    }
                }
                .buttonStyle(JournalActionStyle())
                .accessibilityIdentifier("spottings-history")
                .padding(.horizontal, 20).padding(.vertical, 8)
                .background(JournalStyle.paper)
            }
        }
    }

    private func albumContent(_ album: Spottings) -> some View {
        let matches = album.entries.filter { entry in habitat.map(entry.habitats.contains) ?? true }
        let discovered = matches.filter(\.discovered)
        let open = matches.filter { !$0.discovered }
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Spottings").font(JournalStyle.title()).accessibilityAddTraits(.isHeader)
                Text("Dein Sammelalbum").font(JournalStyle.caption).foregroundStyle(JournalStyle.muted)
            }
            progressCard(album.discoveredCount)
            HStack {
                Text("Arten").font(JournalStyle.heading).accessibilityAddTraits(.isHeader)
                Spacer()
                Text("\(discovered.count) entdeckt").font(JournalStyle.micro).foregroundStyle(JournalStyle.muted)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    habitatChip(nil)
                    ForEach(AnimalHabitat.allCases) { habitatChip($0) }
                }
                .frame(minHeight: 44)
            }
            .scrollIndicators(.hidden)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 10) {
                ForEach(discovered) { entry in
                    NavigationLink(value: JournalRoute.species(entry.id)) {
                        VStack(alignment: .leading, spacing: 0) {
                            JournalThumbnail(image: cover(entry), height: 90, placeholder: "pawprint")
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.name).font(JournalStyle.label)
                                Text(sightingCount(entry.sightings.count))
                                    .font(JournalStyle.micro).foregroundStyle(JournalStyle.muted)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                        }
                        .background(JournalStyle.card, in: RoundedRectangle(cornerRadius: 12))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("spottings-species-\(entry.id)")
                }
                ForEach(open.prefix(showAllOpen ? open.count : 2)) { entry in
                    HStack(spacing: 8) {
                        JournalIcon(name: "JournalLock")
                            .frame(width: 32, height: 32).background(JournalStyle.paper, in: Circle())
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.name).font(JournalStyle.label)
                            Text("Noch offen").font(JournalStyle.micro).foregroundStyle(JournalStyle.muted)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                    .padding(8)
                    .background(JournalStyle.moss, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityElement(children: .combine)
                }
            }
            if open.count > 2 {
                Button(showAllOpen ? "Weniger offene Arten" : "Alle offenen Arten anzeigen") { showAllOpen.toggle() }
                    .font(JournalStyle.label)
                    .frame(minHeight: 44)
            }
            Text("Meilensteine").font(JournalStyle.heading).accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: typeSize.isAccessibilitySize ? 1 : 3), spacing: 6) {
                milestone("Erste Art", icon: "JournalCheck", count: album.discoveredCount, goal: 1)
                milestone("Fünf Arten", icon: "JournalTrophy", count: album.discoveredCount, goal: 5)
                milestone("Lebensräume", icon: "JournalPaw", count: album.habitatCount, goal: 3)
            }
        }
    }

    private func progressCard(_ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(count == 1 ? "1 Art entdeckt" : "\(count) Arten entdeckt")
                    .font(JournalStyle.title(30))
                    .accessibilityIdentifier("spottings-progress")
                Spacer(minLength: 6)
                JournalIcon(name: "JournalBinoculars")
                    .frame(width: 32, height: 32).foregroundStyle(JournalStyle.ink)
                    .background(JournalStyle.amber, in: Circle())
            }
            HStack(spacing: 4) {
                ForEach(0..<5) { index in
                    Capsule().fill(index < count ? JournalStyle.amber : Color.white.opacity(0.25)).frame(height: 7)
                }
            }.accessibilityHidden(true)
            Text(count >= 5 ? "Meilenstein «Fünf Arten» erreicht" :
                 count == 4 ? "Noch 1 Art bis «Fünf Arten»" : "Noch \(5 - count) Arten bis «Fünf Arten»")
                .font(JournalStyle.caption)
        }
        .padding(14)
        .foregroundStyle(.white)
        .background(JournalStyle.forest, in: RoundedRectangle(cornerRadius: 18))
    }

    private func habitatChip(_ value: AnimalHabitat?) -> some View {
        Button {
            habitat = value
            showAllOpen = false
        } label: {
            Text(value?.rawValue ?? "Alle")
                .font(JournalStyle.label)
                .padding(.horizontal, 15).padding(.vertical, 9)
                .foregroundStyle(habitat == value ? .white : JournalStyle.forest)
                .background(habitat == value ? JournalStyle.forest : JournalStyle.moss, in: Capsule())
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(habitat == value ? .isSelected : [])
    }

    private func milestone(_ title: String, icon: String, count: Int, goal: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            JournalIcon(name: icon)
            Text(title).font(JournalStyle.micro)
            Text(count >= goal ? "Erreicht" : "\(count) von \(goal)")
                .font(JournalStyle.micro).foregroundStyle(JournalStyle.muted)
        }
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
        .padding(8)
        .background(count >= goal ? JournalStyle.moss : JournalStyle.card, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private func speciesContent(_ entry: Spottings.Entry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            JournalThumbnail(image: cover(entry), height: 240, placeholder: "pawprint")
                .clipShape(RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 3) {
                if entry.discovered {
                    Label { Text("ENTDECKT").tracking(1.3) } icon: { JournalIcon(name: "JournalCheck", size: 12) }
                        .font(JournalStyle.micro).foregroundStyle(JournalStyle.forest)
                }
                Text(entry.name).font(JournalStyle.title(38)).accessibilityAddTraits(.isHeader)
                Text(entry.habitats.map(\.rawValue).joined(separator: " · "))
                    .font(JournalStyle.caption).foregroundStyle(JournalStyle.muted)
            }
            if let first = entry.firstFound {
                HStack(alignment: .top, spacing: 12) {
                    stat("Erster Fund", value: fmtDate(first))
                    stat("Sichtungen", value: "\(entry.sightings.count)")
                }
                .padding(14).background(JournalStyle.moss, in: RoundedRectangle(cornerRadius: 14))
                Text("Letzte Sichtungen").font(JournalStyle.heading).accessibilityAddTraits(.isHeader)
                ForEach(entry.sightings.prefix(3)) { sighting in
                    HStack(spacing: 8) {
                        Image(systemName: sourceIcon(sighting))
                            .font(.caption).frame(width: 32, height: 32)
                            .background(JournalStyle.moss, in: Circle()).accessibilityHidden(true)
                        Text(fmtDate(sighting.t)).font(JournalStyle.label)
                        Spacer(minLength: 4)
                        Text(sourceLabel(sighting)).font(JournalStyle.caption).foregroundStyle(JournalStyle.muted)
                    }
                    .padding(9).background(JournalStyle.card, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityElement(children: .combine)
                }
            } else {
                Text("Noch keine Sichtung für diese Art gespeichert.").font(JournalStyle.body)
            }
        }
    }

    private func stat(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(JournalStyle.micro).foregroundStyle(JournalStyle.muted)
            Text(value).font(JournalStyle.bold)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func cover(_ entry: Spottings.Entry) -> UIImage? {
        for sighting in entry.sightings {
            if let thumb = sighting.thumb, let image = UIImage(data: thumb) { return image }
        }
        let ids = Set(entry.sightings.map(\.id))
        for photo in photos where !ids.isDisjoint(with: photo.sightingIds) {
            if let thumb = photo.thumb, let image = UIImage(data: thumb) { return image }
        }
        return nil
    }

    private func sightingCount(_ count: Int) -> String { count == 1 ? "1 Sichtung" : "\(count) Sichtungen" }

    private func sourceLabel(_ sighting: Sighting) -> String {
        switch sighting.src {
        case "photo": "Foto"
        case "manual": "Manuell"
        default: "Kamera"
        }
    }

    private func sourceIcon(_ sighting: Sighting) -> String {
        switch sighting.src {
        case "photo": "photo"
        case "manual": "pencil"
        default: "camera"
        }
    }
}
