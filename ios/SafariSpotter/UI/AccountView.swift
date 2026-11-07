import AuthenticationServices
import SwiftUI

struct AccountView: View {
    @EnvironmentObject private var account: AppleAccountSession
    @Environment(\.colorScheme) private var colorScheme
    @State private var name = ""
    @State private var editingName = false
    @State private var confirmingRemoval = false
    @State private var showAppleInstructions = false

    var body: some View {
        Form {
            if !account.canReadProfile {
                Section {
                    Button("Erneut versuchen") { Task { await account.refresh() } }
                    removeProfileButton
                }
            } else if let profile = account.profile {
                Section("Profil") {
                    LabeledContent("Anmeldung", value: "Apple")
                    Button {
                        name = profile.displayName ?? ""
                        editingName = true
                    } label: {
                        LabeledContent("Anzeigename", value: profile.displayName ?? "Hinzufügen")
                    }
                    .accessibilityIdentifier("account-edit-name")
                }
                Section {
                    Button("Abmelden") { account.signOut() }
                        .accessibilityIdentifier("account-sign-out")
                    removeProfileButton
                } footer: {
                    Text("Beim Abmelden bleibt dein Anzeigename für die nächste Anmeldung gespeichert. Deine Safari-Daten sind weiterhin verfügbar.")
                }
            } else {
                Section {
                    SignInWithAppleButton(.signIn) { request in
                        request.requestedScopes = [.fullName]
                    } onCompletion: { result in
                        account.completeSignIn(result)
                    }
                    .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                    .frame(minHeight: 48)
                    .listRowInsets(EdgeInsets())
                    .accessibilityIdentifier("account-sign-in")
                } footer: {
                    Text("Die Anmeldung ist freiwillig. Deine Safari-Daten bleiben auf diesem iPhone. Du kannst sie in den Einstellungen sichern.")
                }
                if account.hasSavedProfile { Section { removeProfileButton } }
            }
            if let message = account.message {
                Section {
                    Text(message).foregroundStyle(.secondary)
                        .accessibilityIdentifier("account-message")
                }
            }
        }
        .navigationTitle("Konto")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Anzeigename", isPresented: $editingName) {
            TextField("Name", text: $name)
                .textContentType(.name)
            Button("Speichern") { account.changeName(name) }
            Button("Abbrechen", role: .cancel) {}
        }
        .confirmationDialog("Lokales Profil entfernen?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("Profil entfernen", role: .destructive) {
                if account.removeProfile() { showAppleInstructions = true }
            }
        } message: {
            Text("Der Anzeigename und die Anmeldung werden auf diesem iPhone entfernt. Deine Safari-Aufnahmen und Sicherungen bleiben verfügbar.")
        }
        .sheet(isPresented: $showAppleInstructions) {
            NavigationStack {
                AppleAccessInstructions()
            }
        }
    }

    private var removeProfileButton: some View {
        Button("Profil entfernen", role: .destructive) { confirmingRemoval = true }
            .accessibilityIdentifier("account-remove")
    }

}

private struct AppleAccessInstructions: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                Text("Dein lokales Profil wurde entfernt. Um Safari Spotter auch den Zugriff auf dein Apple-Konto zu entziehen, öffne auf dem iPhone Einstellungen → dein Name → Mit Apple anmelden → Safari Spotter.")
                if let help = URL(string: "https://support.apple.com/de-ch/102571") {
                    Link("Anleitung von Apple öffnen", destination: help)
                }
            }
        }
        .navigationTitle("Apple-Zugriff verwalten")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
        }
    }
}
