import BC125ATKit
import SwiftUI

/// Every stage of "Write to Scanner" in one sheet: checking, review, writing, result.
struct WriteSheet: View {
    var writer: ScannerWriter
    var write: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch writer.state {
            case .idle:
                EmptyView()
            case .checking(let progress):
                Text("Checking the Scanner").font(.headline)
                ProgressView(value: progress.fraction)
                Text("Reading what's on the scanner now, to work out what needs to change.").foregroundStyle(.secondary)
                buttons { Button("Cancel", role: .cancel) { writer.cancel() }.keyboardShortcut(.cancelAction) }
            case .upToDate:
                Label("The Scanner Is Up to Date", systemImage: "checkmark.circle.fill").font(.headline).foregroundStyle(.green)
                Text("The scanner already holds everything in this document.")
                buttons { Button("OK") { writer.dismiss() }.keyboardShortcut(.defaultAction) }
            case .review(let plan, _):
                review(plan)
            case .compared(let plan):
                Text("The Scanner Differs in \(plan.steps.count) \(plan.steps.count == 1 ? "Place" : "Places")").font(.headline)
                changeList(plan)
                Text("Each line shows the scanner's value → this document's. Nothing was written; use Write to Scanner to make the scanner match.")
                    .font(.callout).foregroundStyle(.secondary)
                buttons { Button("Done") { writer.dismiss() }.keyboardShortcut(.defaultAction) }
            case .writing(let progress, let plan):
                Text("Writing \(plan.steps.count) \(plan.steps.count == 1 ? "Change" : "Changes")").font(.headline)
                ProgressView(value: progress.fraction)
                Text("After writing, the scanner is read back to check every change. Don't disconnect it.")
                    .foregroundStyle(.secondary)
                buttons { Button("Cancel", role: .cancel) { writer.cancel() }.keyboardShortcut(.cancelAction) }
            case .finished(let report, let plan, let backup):
                finished(report, plan: plan, backup: backup)
            case .failed(let message):
                Label("Couldn't Write to the Scanner", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline).foregroundStyle(.orange)
                Text(message).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                buttons {
                    Button("Show Backups") { BackupStore.reveal() }
                    Button("OK") { writer.dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
        .interactiveDismissDisabled()
    }

    // MARK: Stages

    @ViewBuilder
    private func review(_ plan: WritePlan) -> some View {
        Text("Write \(plan.steps.count) \(plan.steps.count == 1 ? "Change" : "Changes") to the Scanner?").font(.headline)
        changeList(plan)
        if plan.target.settings.bandPlan == .canada {
            Text("The band plan is Canada, so frequencies are written as entered. Any the scanner stores differently are listed afterwards.")
                .font(.callout).foregroundStyle(.orange)
        }
        Text("The scanner's current contents are backed up first, so you can go back to them.")
            .font(.callout).foregroundStyle(.secondary)
        buttons {
            Button("Cancel", role: .cancel) { writer.cancel() }.keyboardShortcut(.cancelAction)
            Button("Write \(plan.steps.count) \(plan.steps.count == 1 ? "Change" : "Changes")", action: write)
                .keyboardShortcut(.defaultAction)
        }
    }

    /// The differences by section, plus anything the scanner will store differently.
    private func changeList(_ plan: WritePlan) -> some View {
        List {
            ForEach(WritePlan.Section.allCases, id: \.self) { section in
                let steps = plan.steps(in: section)
                if !steps.isEmpty {
                    Section("\(section.rawValue) (\(steps.count))") {
                        ForEach(steps) { step in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(step.title).fontWeight(.medium)
                                Text(step.detail).foregroundStyle(.secondary).font(.callout)
                            }
                        }
                    }
                }
            }
            if !plan.adjustments.isEmpty {
                Section("The scanner will store these differently") {
                    ForEach(plan.adjustments, id: \.self) { adjustment in
                        Label("\(adjustment.title): \(adjustment.detail)", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .frame(minHeight: 160, idealHeight: 300, maxHeight: 360)
    }

    @ViewBuilder
    private func finished(_ report: WriteReport, plan: WritePlan, backup: URL?) -> some View {
        if report.succeeded {
            Label("Wrote \(report.written) \(report.written == 1 ? "Change" : "Changes")", systemImage: "checkmark.circle.fill")
                .font(.headline).foregroundStyle(.green)
            Text("The scanner was read back and matches this document.")
            if !plan.adjustments.isEmpty {
                Text("\(plan.adjustments.count) \(plan.adjustments.count == 1 ? "value was" : "values were") stored as the scanner allows, and the document was updated to match.")
                    .foregroundStyle(.secondary)
            }
            if !report.storedDifferently.isEmpty {
                Text("The scanner stored \(report.storedDifferently.count == 1 ? "this frequency" : "these frequencies") differently than sent, and the document was updated to match:")
                List(report.storedDifferently, id: \.self) { adjustment in
                    Label("\(adjustment.title): \(adjustment.detail)", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.orange)
                }
                .frame(minHeight: 60, maxHeight: 200)
            }
        } else {
            Label("Some Changes Didn't Take", systemImage: "exclamationmark.triangle.fill")
                .font(.headline).foregroundStyle(.orange)
            List {
                if !report.failures.isEmpty {
                    Section("Rejected by the scanner") {
                        ForEach(report.failures) { failure in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(failure.step.title).fontWeight(.medium)
                                Text(failure.reason).foregroundStyle(.secondary).font(.callout)
                            }
                        }
                    }
                }
                if !report.mismatches.isEmpty {
                    Section("Still different after reading back") {
                        ForEach(report.mismatches) { step in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(step.title).fontWeight(.medium)
                                Text("Scanner → document: \(step.detail)").foregroundStyle(.secondary).font(.callout)
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 120, maxHeight: 260)
            Text("Wrote \(report.written) of \(plan.steps.count). The document wasn't changed.").foregroundStyle(.secondary)
        }
        Text("The scanner is now in Scan Hold. Press Scan on the scanner to start scanning again.")
        buttons {
            if let backup {
                Button("Show Backup") { BackupStore.reveal(backup) }
                    .help(backup.lastPathComponent)
            }
            Button("Done") { writer.dismiss() }.keyboardShortcut(.defaultAction)
        }
    }

    private func buttons(@ViewBuilder _ content: () -> some View) -> some View {
        HStack {
            Spacer()
            content()
        }
    }
}
