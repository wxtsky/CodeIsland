import SwiftUI

/// Settings control for the Feishu approval long connection. The App Secret
/// stays in the Keychain; this view only holds it until the user saves.
struct FeishuApprovalSettingsSection: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var center = FeishuApprovalCenter.shared
    @AppStorage(SettingsKey.feishuApprovalEnabled) private var enabled = SettingsDefaults.feishuApprovalEnabled
    @AppStorage(SettingsKey.feishuApprovalAppID) private var appID = SettingsDefaults.feishuApprovalAppID
    @State private var secret = ""

    var body: some View {
        Section(l10n["feishu_approval_title"]) {
            Text(l10n["feishu_approval_desc"])
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle(l10n["feishu_approval_enable"], isOn: $enabled)
                .onChange(of: enabled) { _, newValue in
                    center.setEnabled(newValue)
                }
            if enabled {
                TextField(l10n["feishu_approval_app_id"], text: $appID)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .autocorrectionDisabled(true)
                SecureField(
                    center.hasSecret ? l10n["feishu_approval_secret_saved"] : l10n["feishu_approval_secret_placeholder"],
                    text: $secret
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                HStack {
                    Button(l10n["feishu_approval_save"]) {
                        center.save(appID: appID, secretInput: secret)
                        secret = ""
                    }
                    if center.hasSecret {
                        Button(l10n["feishu_approval_clear_secret"]) {
                            secret = ""
                            center.clearSecret()
                        }
                    }
                }
                Text(center.statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if center.isPaired {
                    Text(l10n["feishu_approval_paired"])
                        .font(.caption)
                    HStack {
                        Button(l10n["feishu_approval_rebind"]) { center.unbind(); center.armBind() }
                        Button(l10n["feishu_approval_unbind"]) { center.unbind() }
                    }
                } else {
                    Button(l10n["feishu_approval_arm"]) { center.armBind() }
                    if let openID = center.pairCandidateOpenID {
                        Text(String(format: l10n["feishu_approval_candidate"], openID))
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                        Button(l10n["feishu_approval_bind"]) { center.confirmBind() }
                    }
                }
                Text(l10n["feishu_approval_note"])
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { center.refreshIdentity() }
    }
}
