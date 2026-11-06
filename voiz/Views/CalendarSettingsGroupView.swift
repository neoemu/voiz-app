import SwiftUI

struct CalendarSettingsGroupView: View {
    @EnvironmentObject private var viewModel: TranscriptionViewModel
    @ObservedObject var service: MeetingCalendarService

    var body: some View {
        SettingsGroup(title: "Calendário") {
            SettingsRow(icon: "calendar", title: "Agenda e sugestões de reunião",
                        subtitle: "Calendários das suas contas do macOS.") {
                Toggle("Agenda e sugestões de reunião", isOn: $viewModel.settings.calendarSuggestionsEnabled)
                    .labelsHidden().toggleStyle(.switch).tint(VoizTheme.accent)
            }
            if viewModel.settings.calendarSuggestionsEnabled {
                SettingsDivider()
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Contas do macOS").font(.system(size: 14, weight: .medium))
                        Spacer()
                        Button("Adicionar conta…", systemImage: "plus", action: service.openInternetAccounts)
                            .buttonStyle(.bordered)
                    }
                    if !service.isAuthorized {
                        permissionRow
                    } else if service.accounts.isEmpty {
                        Text("Nenhum calendário encontrado. Ative Calendários nas suas contas do macOS.")
                            .font(.system(size: 12)).foregroundStyle(VoizTheme.mutedText)
                    } else {
                        ForEach(service.accounts) { account in
                            accountGroup(account)
                        }
                    }

                    if let error = service.accessError {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }

                    HStack {
                        if let updatedAt = service.lastRefreshedAt {
                            Text("Atualizado às \(updatedAt.formatted(date: .omitted, time: .shortened))")
                                .font(.caption).foregroundStyle(VoizTheme.mutedText)
                        }
                        Spacer()
                        Button("Atualizar", systemImage: "arrow.clockwise") { service.refresh() }
                            .buttonStyle(.plain).foregroundStyle(VoizTheme.accent)
                            .disabled(!service.isAuthorized)
                    }
                }
                .padding(18)

                if service.isAuthorized {
                    SettingsDivider()
                    SettingsRow(icon: "person.2", title: "Mostrar apenas reuniões",
                                subtitle: "Oculta eventos sem participantes ou link de chamada.") {
                        Toggle("Mostrar apenas reuniões", isOn: $viewModel.settings.calendarSelection.meetingsOnly)
                            .labelsHidden().toggleStyle(.switch).tint(VoizTheme.accent)
                    }
                }
            }
        }
        .task { service.refresh() }
    }

    private var permissionRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(service.isAccessBlocked
                 ? String(localized: "Acesso ao calendário negado. Abra os Ajustes do Sistema e permita o Calendário para o Voiz.")
                 : String(localized: "Permita o acesso para escolher quais contas e calendários aparecem no Voiz."))
                .font(.system(size: 12)).foregroundStyle(VoizTheme.mutedText)
            if service.isAccessBlocked {
                Button("Abrir Ajustes do Sistema", action: service.openSystemSettings)
            } else {
                Button("Permitir acesso ao calendário") {
                    Task { _ = await service.requestAccess() }
                }
                .disabled(service.isRequestingAccess)
            }
        }
    }

    private func accountGroup(_ account: MeetingCalendarAccount) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: accountBinding(account.id)) {
                Label(account.title, systemImage: "person.crop.circle")
                    .font(.system(size: 13, weight: .semibold))
            }
            .toggleStyle(.switch).tint(VoizTheme.accent)
            ForEach(account.calendars) { calendar in
                Toggle(isOn: calendarBinding(calendar.id)) {
                    HStack(spacing: 8) {
                        Circle().fill(calendar.color?.swiftUIColor ?? VoizTheme.accent)
                            .frame(width: 8, height: 8).accessibilityHidden(true)
                        Text(calendar.title).font(.system(size: 13))
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(viewModel.settings.calendarSelection.disabledAccountIDs.contains(account.id))
                .padding(.leading, 24)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VoizTheme.elevatedBackground, in: RoundedRectangle(cornerRadius: 10))
    }

    private func accountBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { !viewModel.settings.calendarSelection.disabledAccountIDs.contains(id) }, set: { enabled in
            if enabled { viewModel.settings.calendarSelection.disabledAccountIDs.remove(id) }
            else { viewModel.settings.calendarSelection.disabledAccountIDs.insert(id) }
        })
    }

    private func calendarBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { !viewModel.settings.calendarSelection.disabledCalendarIDs.contains(id) }, set: { enabled in
            if enabled { viewModel.settings.calendarSelection.disabledCalendarIDs.remove(id) }
            else { viewModel.settings.calendarSelection.disabledCalendarIDs.insert(id) }
        })
    }
}

extension CalendarColor {
    var swiftUIColor: Color { Color(red: red, green: green, blue: blue) }
}
