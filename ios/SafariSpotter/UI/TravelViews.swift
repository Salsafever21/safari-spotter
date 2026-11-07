import SwiftUI

private struct CountryOption: Identifiable, Hashable {
    let code: String
    let name: String
    var id: String { code }
}

private enum CountryOptions {
    static let all: [CountryOption] = {
        let names = Locale(identifier: "de_CH")
        return Locale.Region.isoRegions.map(\.identifier)
            .filter { $0.count == 2 && $0.allSatisfy(\.isLetter) }
            .compactMap { code in
            names.localizedString(forRegionCode: code).map { CountryOption(code: code, name: $0) }
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }()

    static func name(_ code: String) -> String {
        all.first { $0.code == code }?.name ?? code
    }
}

private enum TravelField: String, Identifiable {
    case origin, destination
    var id: String { rawValue }
}

/// Erster App-Start und spätere Änderung des Reiseziels. Keine Standortfreigabe erforderlich.
struct TravelSetupView: View {
    let firstLaunch: Bool
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var catalog: SpeciesCatalog
    @State private var origin: String
    @State private var destination: String
    @State private var choosing: TravelField?

    init(firstLaunch: Bool) {
        self.firstLaunch = firstLaunch
        _origin = State(initialValue: AppSettings.shared.originCountry.isEmpty
                        ? Locale.current.region?.identifier ?? "" : AppSettings.shared.originCountry)
        _destination = State(initialValue: AppSettings.shared.destinationCountry)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if firstLaunch {
                        HStack(spacing: 10) {
                            JournalIcon(name: "JournalBinoculars")
                                .frame(width: 36, height: 36)
                                .background(JournalStyle.amber, in: RoundedRectangle(cornerRadius: 11))
                            Text("SAFARI SPOTTER").font(JournalStyle.micro).tracking(1.5)
                        }
                        hero
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(firstLaunch ? "Deine nächste Safari wartet." : "Deine Reise")
                            .font(JournalStyle.title(38))
                            .accessibilityAddTraits(.isHeader)
                        Text("Wähle dein aktuelles Land und dein Reiseziel.")
                            .font(JournalStyle.body).foregroundStyle(JournalStyle.muted)
                    }
                    VStack(spacing: 8) {
                        countryRow(.origin, label: "Ich bin in", code: origin, icon: "JournalPin")
                        countryRow(.destination, label: "Ich reise nach", code: destination, icon: "JournalPlane")
                    }
                    Label { Text("Die Länderwahl braucht keinen Standortzugriff.") } icon: { JournalIcon(name: "JournalPrivacy") }
                        .font(JournalStyle.caption).foregroundStyle(JournalStyle.muted)
                    if !destination.isEmpty { destinationProfile }
                    if origin != destination, let profile = catalog.country(origin) {
                        Text("Für \(profile.name) sind \(catalog.featuredClasses(for: origin).count) im Modell erkennbare Arten belegt. Auch dieses Land hilft der Erkennung.")
                            .font(JournalStyle.caption).foregroundStyle(JournalStyle.muted)
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 14)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .background(JournalStyle.paper.ignoresSafeArea())
            .foregroundStyle(JournalStyle.ink)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Button {
                    settings.originCountry = origin
                    settings.destinationCountry = destination
                    settings.onboardingComplete = true
                    if !firstLaunch { dismiss() }
                } label: {
                    HStack {
                        Text(firstLaunch ? "Safari starten" : "Reise speichern")
                        JournalIcon(name: "JournalArrow")
                    }
                }
                .buttonStyle(JournalActionStyle())
                .disabled(origin.isEmpty || destination.isEmpty)
                .accessibilityIdentifier("travel-start")
                .padding(.horizontal, 20).padding(.vertical, 8)
                .background(JournalStyle.paper)
            }
            .navigationTitle(firstLaunch ? "" : "Reise ändern")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(firstLaunch ? .hidden : .visible, for: .navigationBar)
            .toolbar {
                if !firstLaunch {
                    ToolbarItem(placement: .topBarTrailing) { Button("Schliessen") { dismiss() } }
                }
            }
            .sheet(item: $choosing) { field in
                CountryPickerSheet(selection: field == .origin ? $origin : $destination,
                                   title: field == .origin ? "Ausgangsland" : "Reiseziel")
            }
        }
        .preferredColorScheme(.light)
        .tint(JournalStyle.forest)
    }

    private var hero: some View {
        Color.clear.frame(height: 245)
            .overlay { Image("JournalZebras").resizable().scaledToFill() }
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 5) {
                    JournalIcon(name: "JournalPin", size: 12).foregroundStyle(JournalStyle.amber)
                    Text("SÜDAFRIKA").font(JournalStyle.micro).tracking(1)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(JournalStyle.camera, in: Capsule())
                .padding(14)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .allowsHitTesting(false)
            .accessibilityLabel("Zebras in Südafrika")
    }

    private func countryRow(_ field: TravelField, label: String, code: String, icon: String) -> some View {
        Button { choosing = field } label: {
            HStack(spacing: 12) {
                JournalIcon(name: icon).frame(width: 36, height: 36)
                    .foregroundStyle(JournalStyle.forest)
                    .background(JournalStyle.moss, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).font(JournalStyle.micro).foregroundStyle(JournalStyle.muted)
                    Text(code.isEmpty ? "Land wählen" : CountryOptions.name(code))
                        .font(JournalStyle.bold)
                }
                Spacer(minLength: 6)
                JournalIcon(name: "JournalChevron", size: 12).foregroundStyle(JournalStyle.muted)
            }
            .padding(12)
            .frame(minHeight: 60)
            .background(JournalStyle.card, in: RoundedRectangle(cornerRadius: 15))
            .overlay { RoundedRectangle(cornerRadius: 15).strokeBorder(JournalStyle.line) }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("travel-\(field.rawValue)")
    }

    private var destinationProfile: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Arten am Reiseziel").font(JournalStyle.heading)
            if let profile = catalog.country(destination) {
                let classes = catalog.featuredClasses(for: destination)
                Text("\(classes.count) im Modell erkennbare Arten sind in offiziellen Quellen für \(profile.name) belegt.")
                ForEach(AnimalHabitat.allCases) { habitat in
                    Label("\(classes.filter { catalog.habitats(for: $0.key).contains(habitat) }.count) · \(habitat.rawValue)", systemImage: habitat.symbol)
                }
            } else {
                Text("Für dieses Land ist das Artenprofil noch in Vorbereitung. Die allgemeine Erkennung bleibt verfügbar.")
            }
        }
        .font(JournalStyle.caption).foregroundStyle(JournalStyle.muted)
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(JournalStyle.moss, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct CountryPickerSheet: View {
    @Binding var selection: String
    let title: String
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var catalog: SpeciesCatalog
    @State private var search = ""

    private var filtered: [CountryOption] {
        guard !search.isEmpty else { return CountryOptions.all }
        return CountryOptions.all.filter { $0.name.localizedStandardContains(search) || $0.code.localizedStandardContains(search) }
    }

    var body: some View {
        NavigationStack {
            List {
                if search.isEmpty {
                    Section("Safari-Profile") {
                        ForEach(catalog.countryProfiles) { profile in
                            row(CountryOption(code: profile.code, name: profile.name))
                        }
                    }
                }
                Section(search.isEmpty ? "Alle Länder" : "Suchergebnisse") {
                    ForEach(filtered) { row($0) }
                }
            }
            .searchable(text: $search, prompt: "Land suchen")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fertig") { dismiss() } } }
        }
    }

    private func row(_ country: CountryOption) -> some View {
        Button {
            selection = country.code
            dismiss()
        } label: {
            HStack {
                Text(country.name)
                Spacer()
                if selection == country.code { Image(systemName: "checkmark").foregroundStyle(.orange) }
            }
        }
        .accessibilityIdentifier("travel-country-\(country.code)")
    }
}

/// Tierführer zum gewählten Land. Quellennachweise sind von der Liste aus erreichbar.
struct SafariGuideView: View {
    @EnvironmentObject private var catalog: SpeciesCatalog
    @EnvironmentObject private var settings: AppSettings
    @State private var habitat: AnimalHabitat = .ground
    @State private var showAll = false
    @State private var changeTrip = false
    @State private var viewingOrigin = false

    private var activeCountry: String { viewingOrigin ? settings.originCountry : settings.destinationCountry }
    private var featured: [SpeciesClass] { catalog.featuredClasses(for: activeCountry) }
    private var displayed: [SpeciesClass] {
        let source = showAll || featured.isEmpty ? catalog.shownClasses : featured
        return source.filter { catalog.habitats(for: $0.key).contains(habitat) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if settings.originCountry != settings.destinationCountry,
                       catalog.country(settings.originCountry) != nil {
                        Picker("Land", selection: $viewingOrigin) {
                            Text("Hier").tag(true)
                            Text("Reiseziel").tag(false)
                        }.pickerStyle(.segmented)
                    }
                    Button { changeTrip = true } label: {
                        LabeledContent(viewingOrigin ? "Aktuelles Land" : "Reiseziel", value: CountryOptions.name(activeCountry))
                    }.accessibilityIdentifier("travel-guide-country")
                    Text("Die Artenliste zeigt Beispiele aus veröffentlichten Schutzgebieten des Landes. Sie sagt nicht voraus, was du in einem bestimmten Park sehen wirst.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Picker("Lebensraum", selection: $habitat) {
                        ForEach(AnimalHabitat.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                    if !featured.isEmpty {
                        Toggle("Alle erkennbaren Arten zeigen", isOn: $showAll)
                    }
                }
                Section("\(displayed.count) Arten · \(habitat.rawValue)") {
                    ForEach(displayed) { species in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(species.name).font(.headline)
                            if let latin = species.latin,
                               !(activeCountry == "KE" || activeCountry == "TZ" || activeCountry == "UG" || activeCountry == "RW")
                                    || (species.key != "giraffe" && species.key != "steppenzebra") {
                                Text(latin).font(.caption).italic().foregroundStyle(.secondary)
                            }
                            if showAll && !featured.contains(where: { $0.key == species.key }) {
                                Text("Für dieses Land noch nicht im Profil belegt").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if displayed.isEmpty {
                        Text("Für diese Kategorie sind im aktuellen Profil noch keine Arten erfasst.")
                            .foregroundStyle(.secondary)
                    }
                }
                if let profile = catalog.country(activeCountry) {
                    Section("Quellen") {
                        ForEach(Array(profile.sources.enumerated()), id: \.offset) { index, source in
                            if let url = URL(string: source) {
                                Link("Quelle \(index + 1) öffnen", destination: url)
                            }
                        }
                    }
                }
                Section {
                    Text("Die App erkennt derzeit \(catalog.shownClasses.count) Modellarten. Das Modell wurde hauptsächlich mit südafrikanischen Bildern trainiert; regionale Arten und Unterarten können abweichen. Boden, Luft und Wasser beschreiben mögliche Beobachtungsorte. Das Land verändert nur ein schwaches Vorwissen und schliesst keine Art aus.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Tierführer")
            .sheet(isPresented: $changeTrip) { TravelSetupView(firstLaunch: false) }
        }
    }
}
