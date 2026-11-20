import GPhotosKit
import SwiftUI

struct AccountSheet: View {
  let model: AppModel
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openURL) private var openURL
  @State private var confirmSignOut = false
  @State private var contentHeight: CGFloat = 0
  @State private var accountToRemove: GoogleAccount?
  @State private var isAddingAccount = false

  var body: some View {
    ScrollView {
      VStack(spacing: 20) {
        if let account = model.selectedAccount {
          AccountIdentityHeader(email: account.email, avatarSize: 80)
            .padding(.top, 8)

          AccountStatsCard(
            uploadedCount: model.accountTransferredCount, backedUpBytes: model.accountCompletedByteCount)

          accountsGroup(primaryEmail: account.email)

          Button {
            openURL(URL(string: "googlephotos://")!) { accepted in
              if !accepted { openURL(ProductCopy.googlePhotosURL) }
            }
          } label: {
            GooglePhotosRowLabel()
          }
          .buttonStyle(PressableButtonStyle())
          .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22, style: .continuous))
          .accessibilityHint("Opens Google Photos")

          Button(role: .destructive) {
            confirmSignOut = true
          } label: {
            Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
              .font(.body.weight(.semibold))
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.glass)
          .foregroundStyle(.red)
          .controlSize(.large)
        }
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 16)
      .overlay(alignment: .topTrailing) {
        Button("Close", systemImage: "xmark") { dismiss() }
          .labelStyle(.iconOnly)
          .buttonStyle(.glass)
          .buttonBorderShape(.circle)
          .controlSize(.large)
          .padding(.top, 16)
          .padding(.trailing, 20)
      }
      .onGeometryChange(for: CGFloat.self) {
        $0.size.height
      } action: {
        contentHeight = $0
      }
    }
    .scrollBounceBehavior(.basedOnSize)
    .presentationDetents(contentHeight > 0 ? [.height(contentHeight), .large] : [.medium])
    .presentationDragIndicator(.hidden)
    .onChange(of: model.selectedAccount == nil) { _, signedOut in
      if signedOut { dismiss() }
    }
    .sheet(isPresented: $isAddingAccount) {
      WebAuthSheet { credential in
        switch credential {
        case .oauthToken(let token): try await model.addAccountFromOAuthToken(token)
        case .credentialString(let raw): try await model.addAccountFromRawCredential(raw)
        }
        isAddingAccount = false
      } onCancel: {
        isAddingAccount = false
      }
    }
    .confirmationDialog(
      "Remove Account?",
      isPresented: Binding(get: { accountToRemove != nil }, set: { if !$0 { accountToRemove = nil } }),
      titleVisibility: .visible,
      presenting: accountToRemove
    ) { account in
      Button("Remove", role: .destructive) {
        Task { await model.removeAccount(email: account.email) }
      }
    } message: { _ in
      Text(ProductCopy.removeAccountConfirmation)
    }
    .confirmationDialog("Sign Out?", isPresented: $confirmSignOut, titleVisibility: .visible) {
      Button("Sign Out", role: .destructive) {
        dismiss()
        Task { await model.signOut() }
      }
    } message: {
      Text(ProductCopy.signOutMessage)
    }
  }

  /// Every other account receives a copy at idle time; the primary is the one above.
  private func accountsGroup(primaryEmail: String) -> some View {
    let secondaries = model.accounts.filter { $0.email != primaryEmail }
    return SettingsGroup(
      "Other Accounts",
      footer: secondaries.isEmpty
        ? nil
        : LocalizedStringKey(ProductCopy.idleCopiesFooter(onlyWhileCharging: model.settings.copiesOnlyWhileCharging))
    ) {
      ForEach(secondaries) { account in
        SecondaryAccountRow(
          account: account,
          state: model.accountMirror.state(for: account.email),
          keepsCopy: Binding(
            get: { account.mirrorEnabled },
            set: { enabled in Task { await model.setMirrorEnabled(email: account.email, enabled: enabled) } }
          )
        )
        .contextMenu {
          Button("Make Primary", systemImage: "star") {
            Task { await model.setPrimary(email: account.email) }
          }
          Button("Remove", systemImage: "trash", role: .destructive) {
            accountToRemove = account
          }
        }
      }
      if !secondaries.isEmpty {
        SettingRow(
          "Copy Only While Charging",
          detail: "Wait for a charger before copying to other accounts.",
          symbol: "battery.100percent.bolt", colors: [.green, .mint]
        ) {
          Toggle("Copy Only While Charging", isOn: model.setting(\.copiesOnlyWhileCharging))
        }
      }
      Button {
        isAddingAccount = true
      } label: {
        SettingRow(
          "Add Account",
          detail: "Keep a second copy in another Google account.",
          symbol: "person.crop.circle.badge.plus", colors: [.blue, .cyan]
        ) {
          Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
        }
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
    }
  }
}

/// A secondary account: its copy progress and whether it keeps a copy at all.
/// Long-press for Make Primary and Remove.
private struct SecondaryAccountRow: View {
  let account: GoogleAccount
  let state: SecondaryMirrorState?
  @Binding var keepsCopy: Bool

  private var detail: String {
    guard keepsCopy else { return "Not keeping a copy" }
    return state?.statusText ?? "Copied 0 of 0"
  }

  var body: some View {
    HStack(spacing: 12) {
      AccountAvatar(email: account.email, size: 30)
      VStack(alignment: .leading, spacing: 2) {
        Text(account.email)
          .font(.body)
          .lineLimit(1)
          .truncationMode(.middle)
        Text(detail)
          .font(.footnote)
          .foregroundStyle(state?.lastError != nil && keepsCopy ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
          .monospacedDigit()
          .contentTransition(.numericText())
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Toggle("Keep a Copy", isOn: $keepsCopy)
        .labelsHidden()
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .accessibilityElement(children: .combine)
    .accessibilityHint("Long-press for Make Primary and Remove.")
  }
}
