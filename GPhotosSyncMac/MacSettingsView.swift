import GPhotosKit
import SwiftUI

/// The Settings section of the main window (⌘,).
struct MacSettingsPage: View {
  let store: MacSyncStore
  let router: MacRouter

  var body: some View {
    Form {
      // Signed out, the sidebar's Sign In is the way in; there is nothing to manage yet.
      if store.selectedAccount != nil {
        AccountsSettingsGroup(store: store)
      }
      BackupSettingsGroup(store: store)
      StorageSettingsGroup(store: store, router: router)
      SystemSettingsGroup(store: store)
    }
    .formStyle(.grouped)
    .navigationTitle("Settings")
  }
}

extension MacSyncStore {
  /// A binding that writes one setting through `updateSettings`, which persists it.
  func setting<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
    Binding {
      self.settings[keyPath: keyPath]
    } set: { value in
      var settings = self.settings
      settings[keyPath: keyPath] = value
      self.updateSettings(settings)
    }
  }
}

private struct AccountsSettingsGroup: View {
  let store: MacSyncStore
  @State private var accountToRemove: GoogleAccount?
  @State private var isAddingAccount = false

  var body: some View {
    Section {
      ForEach(store.accounts) { account in
        let isPrimary = (account.email == store.selectedAccount?.email)
        let state = store.accountMirror.state(for: account.email)
        HStack(spacing: 12) {
          AccountAvatar(email: account.email, size: 28)
          VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
              Text(account.email)
                .font(.body.weight(.medium))
              if isPrimary {
                Text("Primary")
                  .font(.caption2.weight(.semibold))
                  .padding(.horizontal, 6)
                  .padding(.vertical, 2)
                  .background(Capsule().fill(.quaternary))
                  .foregroundStyle(.secondary)
              }
            }
            if !isPrimary {
              Text(account.mirrorEnabled ? (state?.statusText ?? "Copied 0 of 0") : "Not keeping a copy")
                .font(.caption)
                .foregroundStyle(state?.lastError != nil && account.mirrorEnabled ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .monospacedDigit()
            }
          }
          Spacer()
          if !isPrimary {
            Toggle(
              "Keep a Copy",
              isOn: Binding(
                get: { account.mirrorEnabled },
                set: { enabled in
                  Task { await store.setMirrorEnabled(email: account.email, enabled: enabled) }
                }
              )
            )
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("Keep a copy of all primary photos on this account")

            Menu {
              Button("Make Primary") {
                Task { await store.setPrimary(email: account.email) }
              }
              Button("Remove…", role: .destructive) {
                accountToRemove = account
              }
            } label: {
              Image(systemName: "ellipsis.circle")
                .font(.body)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24, height: 24)
          }
        }
        .contextMenu {
          if !isPrimary {
            Button("Make Primary") {
              Task { await store.setPrimary(email: account.email) }
            }
            Button("Remove…", role: .destructive) {
              accountToRemove = account
            }
          }
        }
      }

      if store.accounts.count > 1 {
        Toggle("Copy Only While Plugged In", isOn: store.setting(\.copiesOnlyWhileCharging))
          .help("Wait for power before copying to other accounts")
      }
      HStack {
        Spacer()
        Button("Add Account…") {
          isAddingAccount = true
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }
    } header: {
      Text("Accounts")
    } footer: {
      if store.accounts.count > 1 {
        Text(ProductCopy.idleCopiesFooter(onlyWhileCharging: store.settings.copiesOnlyWhileCharging))
      }
    }
    .sheet(isPresented: $isAddingAccount) {
      MacSignInSheet(store: store) {
        isAddingAccount = false
      }
    }
    .confirmationDialog(
      "Remove Account?",
      isPresented: Binding(
        get: { accountToRemove != nil },
        set: { if !$0 { accountToRemove = nil } }
      ), titleVisibility: .visible
    ) {
      Button("Remove", role: .destructive) {
        if let account = accountToRemove {
          Task { await store.removeAccount(email: account.email) }
        }
        accountToRemove = nil
      }
    } message: {
      Text(ProductCopy.removeAccountConfirmation)
    }
  }
}

private struct BackupSettingsGroup: View {
  let store: MacSyncStore

  var body: some View {
    Section("Backup & Sync") {
      MacSettingsRow(
        "Auto-Sync",
        detail: "Back up new photos and videos in your folders automatically.",
        symbol: "arrow.triangle.2.circlepath", colors: [.green, .mint]
      ) {
        Toggle("Auto-Sync", isOn: autoSync)
          .toggleStyle(.switch)
      }
      MacSettingsRow(
        "Pair Live Photos",
        detail: "Upload the photo and its motion together.",
        symbol: "livephoto", colors: [.orange, .yellow]
      ) {
        Toggle("Pair Live Photos", isOn: store.setting(\.pairLivePhotos))
          .toggleStyle(.switch)
      }
      MacSettingsRow(
        "Albums from Folders", detail: "Add photos to an album named after their folder.",
        symbol: "rectangle.stack.fill", colors: [.blue, .indigo]
      ) {
        Toggle("Albums from Folders", isOn: store.setting(\.createAlbumsFromFolders))
          .toggleStyle(.switch)
      }
      MacSettingsRow(
        "Date from Filename",
        detail: "Use dates in names like IMG_20240101_120000.",
        symbol: "calendar.badge.clock", colors: [.purple, .indigo]
      ) {
        Toggle("Date from Filename", isOn: store.setting(\.setDateFromFilename))
          .toggleStyle(.switch)
      }
      MacSettingsRow(
        "Use Personal Hotspot",
        detail: "Upload and prepare Search over an iPhone hotspot when there’s no Wi‑Fi or Ethernet.",
        symbol: "personalhotspot", colors: [.green, .teal]
      ) {
        Toggle("Use Personal Hotspot", isOn: store.setting(\.uploadsOnMeteredNetworks))
          .toggleStyle(.switch)
      }
      MacSettingsRow(
        "Concurrent Uploads",
        detail: store.isRunning ? "Can be changed when no backup is running." : "Upload more files at once for faster backups.",
        symbol: "square.stack.3d.up.fill", colors: [.blue, .cyan]
      ) {
        HStack(spacing: 8) {
          Text(store.settings.uploadThreads, format: .number)
            .font(.headline)
            .monospacedDigit()
          Stepper("Concurrent Uploads", value: store.setting(\.uploadThreads), in: 1...8)
        }
        .fixedSize()
        .disabled(store.isRunning)
      }
    }
  }

  private var autoSync: Binding<Bool> {
    Binding {
      store.settings.autoSyncEnabled
    } set: { enabled in
      store.setting(\.autoSyncEnabled).wrappedValue = enabled
      if enabled { store.requestSyncNow() }
    }
  }
}

private struct StorageSettingsGroup: View {
  let store: MacSyncStore
  @Bindable var router: MacRouter
  @State private var cleanupPlan: MacCleanupPlan?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isAddingProtectedFolder = false
  @State private var protectedFolderPendingRemoval: IgnoredFolderLocation?

  private var foundItemsDetail: LocalizedStringKey {
    ProductCopy.foundItemsDetail(
      count: store.foundInAccountCount, isOn: store.settings.removesItemsAlreadyInGooglePhotos,
      deleteDelay: store.settings.autoDeleteDelay)
  }

  private var cleanupDetail: LocalizedStringKey {
    ProductCopy.cleanupDetail(
      isSignedIn: store.selectedAccount != nil, deleteDelay: store.settings.autoDeleteDelay, isBackingUp: store.isRunning)
  }

  var body: some View {
    Section {
      MacSettingsRow(
        "Delete After Backup",
        detail: "Free up space once files are safely in Google Photos.",
        symbol: "clock.badge.checkmark", colors: [.red, .orange]
      ) {
        Picker("Delete After Backup", selection: store.setting(\.autoDeleteDelay)) {
          ForEach(AutoDeleteDelay.allCases) { Text($0.title).tag($0) }
        }
        .fixedSize()
      }
      MacSettingsRow(
        "Only When Low on Space",
        detail: store.settings.autoDeleteDelay == .never
          ? "Choose a Delete After Backup time to use this." : "Only remove files when the disk has less than 5 GB free.",
        symbol: "internaldrive", colors: [.teal, .cyan]
      ) {
        Toggle("Only When Low on Space", isOn: store.setting(\.smartDeleteEnabled))
          .toggleStyle(.switch)
          .disabled(store.settings.autoDeleteDelay == .never)
      }
      MacSettingsRow(
        "Remove Items Found in Google Photos",
        detail: foundItemsDetail,
        symbol: "checkmark.icloud", colors: [.green, .mint]
      ) {
        Toggle("Remove Items Found in Google Photos", isOn: store.setting(\.removesItemsAlreadyInGooglePhotos))
          .toggleStyle(.switch)
          .disabled(store.settings.autoDeleteDelay == .never)
      }
      MacSettingsRow(
        "Clean Up Now", detail: cleanupDetail,
        symbol: "sparkles", colors: [.orange, .yellow]
      ) {
        if store.isPreparingCleanup || store.isCleaningUp {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel(store.isCleaningUp ? "Cleaning Up" : "Preparing Clean Up")
        } else {
          Button("Clean Up…", action: startCleanup)
            .disabled(!store.canCleanUp)
        }
      }
      MacSettingsRow(
        "Protected Folders", detail: "Never clean up files in these folders.",
        symbol: "lock.shield.fill", colors: [.blue, .indigo]
      ) {
        Button("Add…") { isAddingProtectedFolder = true }
      }
      protectedFolderList
      if let notice = store.cleanupNotice {
        InlineMessage(notice.text, style: notice.isWarning ? .error : .info)
          .transition(.opacity)
      }
    } header: {
      Text("Device Storage")
    } footer: {
      Text("Files in these folders are never removed, even after they’re backed up.")
    }
    .animation(reduceMotion ? nil : .smooth, value: store.cleanupNotice?.text)
    .onAppear { store.refreshProtectedFolderStatus() }
    .onChange(of: router.isConfirmingCleanup, initial: true) { _, requested in
      guard requested else { return }
      router.isConfirmingCleanup = false
      if store.canCleanUp { startCleanup() }
    }
    .fileImporter(isPresented: $isAddingProtectedFolder, allowedContentTypes: [.folder]) { result in
      guard case .success(let url) = result else { return }
      let started = url.startAccessingSecurityScopedResource()
      defer { if started { url.stopAccessingSecurityScopedResource() } }
      store.addIgnoredFolder(url: url)
    }
    .fileDialogMessage("Files in this folder are never removed by cleanup.")
    .fileDialogConfirmationLabel("Protect Folder")
    .confirmationDialog(
      Text(ProductCopy.inflected("Remove ^[\(cleanupPlan?.count ?? 0) file](inflect: true) from this Mac?")),
      isPresented: Binding(get: { cleanupPlan != nil }, set: { if !$0 { cleanupPlan = nil } }),
      titleVisibility: .visible,
      presenting: cleanupPlan
    ) { plan in
      Button(ProductCopy.inflected("Remove ^[\(plan.count) File](inflect: true)"), role: .destructive) {
        Task { await store.performCleanup(plan: plan) }
      }
    } message: { _ in
      Text(cleanupMessage)
    }
    .confirmationDialog(
      "Remove Folder Protection?",
      isPresented: Binding(
        get: { protectedFolderPendingRemoval != nil }, set: { if !$0 { protectedFolderPendingRemoval = nil } }),
      titleVisibility: .visible,
      presenting: protectedFolderPendingRemoval
    ) { folder in
      Button("Remove Protection", role: .destructive) { store.removeIgnoredFolder(id: folder.id) }
    } message: { _ in
      Text("Backed-up files in this folder can then be removed by Clean Up.")
    }
  }

  @ViewBuilder
  private var protectedFolderList: some View {
    if store.settings.ignoredFolders.isEmpty {
      Text("No protected folders")
        .font(.subheadline)
        .foregroundStyle(.tertiary)
    }
    ForEach(store.settings.ignoredFolders) { folder in
      let isMissing = store.missingProtectedFolderIDs.contains(folder.id)
      HStack(spacing: 10) {
        Image(systemName: isMissing ? "exclamationmark.triangle.fill" : "folder.fill")
          .foregroundStyle(isMissing ? .orange : .blue)
          .frame(width: 16)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(folder.title)
            .font(.subheadline.weight(.medium))
          Text(abbreviatedHomePath(folder.path))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
          if isMissing {
            Text("Can’t find this folder, so Clean Up removes nothing. Reconnect it or remove its protection.")
              .font(.caption)
              .foregroundStyle(.orange)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .accessibilityElement(children: .combine)
        Spacer()
        Button("Remove Protection", systemImage: "lock.open", role: .destructive) {
          protectedFolderPendingRemoval = folder
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .frame(width: 24, height: 24)
        .contentShape(.rect)
        .help("Remove Protection…")
      }
      .contextMenu {
        Button("Remove Protection…", role: .destructive) { protectedFolderPendingRemoval = folder }
      }
    }
  }

  private var cleanupMessage: String {
    let email = store.selectedAccount?.email ?? String(localized: "your Google account")
    return String(
      localized:
        "They’re backed up to \(email). They’re deleted from their folders on this Mac; nothing in a protected folder is touched."
    )
  }

  /// Works out what would be removed first, so the confirmation can name the count. An
  /// empty plan shows the store's notice instead of a dialog.
  private func startCleanup() {
    guard store.canCleanUp else { return }
    cleanupPlan = nil
    Task {
      guard let plan = await store.prepareCleanup(), !plan.isEmpty else { return }
      cleanupPlan = plan
    }
  }
}

private struct SystemSettingsGroup: View {
  let store: MacSyncStore
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    Section("System") {
      MacSettingsRow(
        "Launch at Login", detail: "Open automatically when you log in.",
        symbol: "power", colors: [.gray, Color(nsColor: .darkGray)]
      ) {
        Toggle("Launch at Login", isOn: Binding(get: { store.launchAtLoginEnabled }, set: { store.setLaunchAtLogin($0) }))
          .toggleStyle(.switch)
      }
      if let message = store.launchAtLoginError {
        VStack(alignment: .leading, spacing: 8) {
          InlineMessage(message, style: store.launchAtLoginRequiresApproval ? .info : .error)
          if store.launchAtLoginRequiresApproval {
            Button("Open Login Items Settings…") { store.openLoginItemsSettings() }
          }
        }
      }
    }
    .onChange(of: scenePhase, initial: true) { _, phase in
      if phase == .active { store.refreshLaunchAtLoginStatus() }
    }
  }
}

/// Lets the grouped Form own row spacing, separators and backgrounds.
private struct MacSettingsRow<Control: View>: View {
  private let label: SettingLabel
  private let control: Control

  init(
    _ title: LocalizedStringKey, detail: LocalizedStringKey? = nil, symbol: String, colors: [Color],
    @ViewBuilder control: () -> Control
  ) {
    label = SettingLabel(title, detail: detail, symbol: symbol, colors: colors)
    self.control = control()
  }

  var body: some View {
    LabeledContent {
      control.labelsHidden()
    } label: {
      label
    }
    .accessibilityElement(children: .contain)
  }
}
