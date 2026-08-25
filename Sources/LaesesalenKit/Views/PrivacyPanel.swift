import Combine
import DocPrivacy
import SwiftUI

/// The receipts.
///
/// Every app that handles private documents says it keeps them private, and a
/// reader has no way to check any of those claims from the outside. This
/// panel is the check: every connection the app has opened this session, the
/// address, and how many bytes went each way. With the built-in models the
/// list is empty and stays empty, which is a stronger statement than any
/// sentence on the box.
struct PrivacyPanel: View {
    @ObservedObject var ledger: PrivacyLedger
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("What has left this Mac")
                    .font(.headline)
                Text(headline)
                    .font(.callout)
                    .foregroundStyle(ledger.stayedOnThisMac ? Color.secondary : Color.red)
            }
            .padding(18)

            Divider()

            if ledger.entries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "lock")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("No connections at all.")
                    Text(
                        "Everything so far has been done by models that came "
                            + "with macOS."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(30)
            } else {
                Table(ledger.entries) {
                    TableColumn("When") { entry in
                        Text(entry.at.formatted(date: .omitted, time: .standard))
                    }
                    .width(80)
                    TableColumn("Address", value: \.authority).width(120)
                    TableColumn("Path", value: \.path)
                    TableColumn("Sent") { entry in
                        Text(bytes(entry.bytesSent))
                    }
                    .width(70)
                    TableColumn("Received") { entry in
                        Text(bytes(entry.bytesReceived))
                    }
                    .width(70)
                    TableColumn("Outcome") { entry in
                        switch entry.outcome {
                        case .allowed: Text("ok").foregroundStyle(.secondary)
                        case .refused(let why): Text(why).foregroundStyle(.red)
                        }
                    }
                }
            }

            Divider()

            HStack {
                Text(
                    "Læsesalen can only address 127.0.0.1. Any other address "
                        + "is refused before a connection is opened."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 720, height: 440)
    }

    private var headline: String {
        guard ledger.totalRequests > 0 else {
            return "Nothing. No connection has been opened this session."
        }
        let addresses = ledger.addressesContacted.sorted().joined(
            separator: ", "
        )
        return "\(ledger.totalRequests) requests to \(addresses) — "
            + "\(bytes(ledger.totalBytesSent)) sent, "
            + "\(bytes(ledger.totalBytesReceived)) received."
    }

    private func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(
            fromByteCount: Int64(count),
            countStyle: .file
        )
    }
}
