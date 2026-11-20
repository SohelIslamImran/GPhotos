import SwiftUI

/// The signed-in account's avatar, address and backup quality.
public struct AccountIdentityHeader: View {
  private let email: String
  private let avatarSize: CGFloat

  #if os(macOS)
    private static let emailFont: Font = .headline
  #else
    private static let emailFont: Font = .title3.weight(.semibold)
  #endif

  public init(email: String, avatarSize: CGFloat) {
    self.email = email
    self.avatarSize = avatarSize
  }

  public var body: some View {
    VStack(spacing: 10) {
      AccountAvatar(email: email, size: avatarSize)
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
      Text(email)
        .font(Self.emailFont)
        .lineLimit(2)
        .truncationMode(.middle)
        .multilineTextAlignment(.center)
        .textSelection(.enabled)
        .accessibilityAddTraits(.isHeader)
      Label {
        Text(ProductCopy.originalQuality)
          .foregroundStyle(.secondary)
      } icon: {
        Image(systemName: "checkmark.seal.fill")
          .foregroundStyle(.green)
      }
      .font(.footnote.weight(.semibold))
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .glassEffect(.regular, in: .capsule)
    }
  }
}

/// How much the account has backed up: items uploaded and their size.
public struct AccountStatsCard: View {
  private let uploadedCount: Int
  private let backedUpBytes: Int64

  #if os(macOS)
    private static let valueFont: Font = .system(.title2, design: .rounded).weight(.semibold)
    private static let verticalPadding: CGFloat = 14
    // `.separator` all but disappears on glass on the Mac.
    private static var dividerStyle: AnyShapeStyle { AnyShapeStyle(.tertiary) }
  #else
    private static let valueFont: Font = .system(.title, design: .rounded).weight(.semibold)
    private static let verticalPadding: CGFloat = 20
    private static var dividerStyle: AnyShapeStyle { AnyShapeStyle(.separator) }
  #endif

  public init(uploadedCount: Int, backedUpBytes: Int64) {
    self.uploadedCount = uploadedCount
    self.backedUpBytes = backedUpBytes
  }

  public var body: some View {
    HStack(spacing: 0) {
      stat("Uploaded", value: uploadedCount.formatted())
      Capsule()
        .fill(Self.dividerStyle)
        .frame(width: 1, height: 40)
        .accessibilityHidden(true)
      stat("Backed Up", value: ByteFormat.string(backedUpBytes))
    }
    .padding(.vertical, Self.verticalPadding)
    .glassEffect(.regular, in: .rect(cornerRadius: Radius.card, style: .continuous))
  }

  private func stat(_ title: LocalizedStringKey, value: String) -> some View {
    VStack(spacing: 2) {
      Text(value)
        .font(Self.valueFont)
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.6)
      Text(title)
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 12)
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .combine)
  }
}

/// The "Open Google Photos" row's label, with the Google Photos logo from the apps'
/// shared asset catalog.
public struct GooglePhotosRowLabel: View {
  #if os(macOS)
    private static let detail: LocalizedStringKey = "See your library on the web."
  #else
    private static let detail: LocalizedStringKey = "See your library in the app."
  #endif

  public init() {}

  public var body: some View {
    HStack(spacing: 14) {
      Image("GooglePhotosLogo", bundle: .main)
        .resizable()
        .scaledToFit()
        .frame(width: 24, height: 24)
        .frame(width: 36, height: 36)
        .background {
          RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(.white)
            .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
        }
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text("Open Google Photos")
          .font(.body.weight(.semibold))
        Text(Self.detail)
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Image(systemName: "arrow.up.forward")
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.tertiary)
        .accessibilityHidden(true)
    }
    .padding(.vertical, 14)
    .padding(.horizontal, 16)
    .contentShape(.rect)
  }
}

/// The account at a glance: who is signed in, what has been backed up, and the account
/// actions. The Mac shows it in the sidebar's account popover; the iPhone's account
/// sheet is built from the same pieces.
public struct AccountSummaryView: View {
  private let email: String
  private let uploadedCount: Int
  private let backedUpBytes: Int64
  private let onOpenGooglePhotos: () -> Void
  private let onSettings: (() -> Void)?
  private let onSignOut: () -> Void

  public init(
    email: String, uploadedCount: Int, backedUpBytes: Int64, onOpenGooglePhotos: @escaping () -> Void,
    onSettings: (() -> Void)? = nil, onSignOut: @escaping () -> Void
  ) {
    self.email = email
    self.uploadedCount = uploadedCount
    self.backedUpBytes = backedUpBytes
    self.onOpenGooglePhotos = onOpenGooglePhotos
    self.onSettings = onSettings
    self.onSignOut = onSignOut
  }

  public var body: some View {
    VStack(spacing: 16) {
      AccountIdentityHeader(email: email, avatarSize: 56)
      AccountStatsCard(uploadedCount: uploadedCount, backedUpBytes: backedUpBytes)
      Button(action: onOpenGooglePhotos) {
        GooglePhotosRowLabel()
      }
      .buttonStyle(PressableButtonStyle())
      .glassEffect(.regular.interactive(), in: .rect(cornerRadius: Radius.card, style: .continuous))
      .accessibilityHint("Opens Google Photos")
      GlassEffectContainer(spacing: 8) {
        VStack(spacing: 8) {
          if let onSettings {
            Button(action: onSettings) {
              Label("Settings…", systemImage: "gearshape")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
          }
          Button(role: .destructive, action: onSignOut) {
            Label("Sign Out…", systemImage: "rectangle.portrait.and.arrow.right")
              .font(.body.weight(.semibold))
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.glass)
          .foregroundStyle(.red)
        }
        .controlSize(.large)
      }
    }
  }
}
