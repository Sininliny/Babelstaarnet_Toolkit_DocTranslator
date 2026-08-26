import Combine
import DocPrivacy
import SwiftUI

/// The receipts, in two sizes.
///
/// Every app that handles private documents says it keeps them private, and a
/// reader has no way to check any of those claims from the outside. This file
/// is the check: every connection the app has opened this session, the
/// address, and how many bytes went each way. With the built-in models the
/// list is empty and stays empty, which is a stronger statement than any
/// sentence on the box.
///
/// It comes in two sizes because it answers two different questions. "Has
/// anything left this Mac?" is asked in passing, deserves one paragraph, and
/// used to cost a modal window with a seven-column table in it — the app made
/// the reader work for its own reassurance. "Show me every line" is asked
/// once, by somebody who has a reason, and that one gets the table.

// MARK: - The paragraph

/// What hangs off the lock in the corner.
struct PrivacySummary: View {
    @ObservedObject var ledger: PrivacyLedger
    let showEverything: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(tint)
                Text(headline)
                    .font(.headline)
            }

            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if ledger.totalRequests > 0 {
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text("While translating").foregroundStyle(.secondary)
                        Text("\(ledger.documentRequests.count)")
                            .monospacedDigit()
                    }
                    GridRow {
                        Text("Model downloads").foregroundStyle(.secondary)
                        Text("\(ledger.modelDownloads.count)")
                            .monospacedDigit()
                    }
                    GridRow {
                        Text("Addresses").foregroundStyle(.secondary)
                        Text(
                            ledger.addressesContacted.sorted()
                                .joined(separator: ", ")
                        )
                    }
                }
                .font(.caption)
            }

            Divider()

            Text(
                "Laesesalen can only address 127.0.0.1. Any other address is "
                    + "refused before a connection is opened."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Show every line", action: showEverything)
                    .disabled(ledger.entries.isEmpty)
            }
        }
        .padding(Metrics.gutter)
        .frame(width: 330)
    }

    private var symbol: String {
        ledger.documentsStayedOnThisMac
            ? "lock.fill"
            : "lock.trianglebadge.exclamationmark.fill"
    }

    private var tint: Color {
        ledger.documentsStayedOnThisMac ? .green : .red
    }

    private var headline: String {
        guard ledger.totalRequests > 0 else { return "Nothing has left" }
        return ledger.documentsStayedOnThisMac
            ? "No document has left"
            : "Check this"
    }

    private var detail: String {
        guard ledger.totalRequests > 0 else {
            return "No connection has been opened this session. Everything so "
                + "far has been done by models already on this Mac."
        }
        guard ledger.documentsStayedOnThisMac else {
            return "A request carrying document work went to an address that "
                + "is not this Mac. That should not be possible."
        }
        let downloads = ledger.modelDownloads.count
        if ledger.documentRequests.isEmpty, downloads > 0 {
            return "\(downloads) model "
                + (downloads == 1 ? "download" : "downloads")
                + " fetched weights from a public host. No document was part "
                + "of that request."
        }
        return "Every request made while translating went to this machine."
    }
}

// MARK: - Every line

struct PrivacyPanel: View {
    @ObservedObject var ledger: PrivacyLedger
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader("What has left this Mac", headline)
                .foregroundStyle(
                    ledger.documentsStayedOnThisMac ? .primary : Color.red
                )

            Divider()

            if ledger.entries.isEmpty {
                empty
            } else {
                Table(ledger.entries) {
                    TableColumn("When") { entry in
                        Text(entry.at.formatted(date: .omitted, time: .standard))
                            .monospacedDigit()
                    }
                    .width(80)
                    TableColumn("For") { entry in
                        Text(entry.purpose.displayName)
                    }
                    .width(110)
                    TableColumn("Address", value: \.authority).width(120)
                    TableColumn("Path", value: \.path)
                    TableColumn("Sent") { entry in
                        Text(bytes(entry.bytesSent)).monospacedDigit()
                    }
                    .width(70)
                    TableColumn("Received") { entry in
                        Text(bytes(entry.bytesReceived)).monospacedDigit()
                    }
                    .width(70)
                    TableColumn("Outcome") { entry in
                        switch entry.outcome {
                        case .allowed:
                            Label("allowed", systemImage: "checkmark")
                                .labelStyle(.titleOnly)
                                .foregroundStyle(.secondary)
                        case .refused(let why):
                            Label(why, systemImage: "xmark.octagon.fill")
                                .foregroundStyle(.red)
                        }
                    }
                }
            }

            Divider()

            PanelFooter(
                note: "Laesesalen can only address 127.0.0.1. Any other "
                    + "address is refused before a connection is opened."
            ) { dismiss() }
        }
        .frame(width: 760, height: 460)
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.green)
            Text("No connections at all.")
                .font(.title3.weight(.medium))
            Text(
                "Everything so far has been done by models already on this "
                    + "Mac."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    private var headline: String {
        guard ledger.totalRequests > 0 else {
            return "Nothing. No connection has been opened this session."
        }
        guard ledger.documentsStayedOnThisMac else {
            return "A request carrying document work went to an address that "
                + "is not this Mac. That should not be possible; the line is "
                + "below."
        }
        let documents = ledger.documentRequests.count
        let downloads = ledger.modelDownloads.count
        var sentence = "No document has left this Mac."
        if documents > 0 {
            sentence += " \(documents) requests were made while translating, "
                + "all to "
                + ledger.addressesContacted.sorted().joined(separator: ", ")
                + "."
        }
        if downloads > 0 {
            sentence += " \(downloads) model "
                + (downloads == 1 ? "download" : "downloads")
                + " fetched \(bytes(ledger.totalBytesReceived)) of weights."
        }
        return sentence
    }

    private func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(
            fromByteCount: Int64(count),
            countStyle: .file
        )
    }
}
