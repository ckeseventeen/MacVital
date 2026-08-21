import SwiftUI
import MacVitalKit

/// The findings table, split out of the old `ScanResultView` so both the page
/// and the detail inspector can live inside the new shell.
struct FindingsList: View {
    @EnvironmentObject private var model: ScanViewModel

    var body: some View {
        HSplitView {
            List(selection: $model.selectedFindingID) {
                ForEach(groupedFindings, id: \.key) { group in
                    Section {
                        ForEach(group.value) { finding in
                            FindingRow(
                                finding: finding,
                                isChecked: model.selection.contains(finding.id),
                                toggle: { model.toggle(finding) }
                            )
                            .tag(finding.id)
                        }
                    } header: {
                        sectionHeader(group.key, findings: group.value)
                    }
                }
            }
            .listStyle(.inset)
            .alternatingRowBackgrounds()
            .frame(minWidth: 420)

            ItemDetailPane(finding: model.selectedFinding) {
                // Whatever was holding it is gone; re-derive the verdicts so
                // the row unlocks instead of staying stale until a full rescan.
                await model.revalidate()
            }
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
        }
    }

    private func sectionHeader(_ category: ScanCategory, findings: [Finding]) -> some View {
        HStack(spacing: 8) {
            GlyphTile(systemImage: category.symbolName, tint: category.tint, size: 22)
            Text(category.title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.label)
            Text("\(findings.count)")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(category.tint.opacity(0.14), in: Capsule())
                .foregroundStyle(category.tint)
            Spacer()
            Text(ByteFormat.string(findings.reduce(Int64(0)) { $0 + $1.item.sizeBytes }))
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.junk)
        }
        .padding(.vertical, 4)
        .textCase(nil)
    }

    private var groupedFindings: [(key: ScanCategory, value: [Finding])] {
        Dictionary(grouping: model.visibleFindings) { $0.item.category }
            .sorted { lhs, rhs in
                let l = lhs.value.reduce(Int64(0)) { $0 + $1.item.sizeBytes }
                let r = rhs.value.reduce(Int64(0)) { $0 + $1.item.sizeBytes }
                return l > r
            }
    }
}

struct FindingRow: View {
    let finding: Finding
    let isChecked: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            Toggle("", isOn: Binding(get: { isChecked }, set: { _ in toggle() }))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(!finding.isSelectable)
                .help(finding.isSelectable ? "" : finding.decision.rationale)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(finding.item.displayName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.label)
                        .lineLimit(1)
                    if let owner = finding.assessment?.attribution ?? finding.item.ownerHint?.label {
                        Text(owner)
                            .font(.system(size: 11))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Theme.well, in: Capsule())
                            .foregroundStyle(Theme.secondaryLabel)
                            .lineLimit(1)
                    }
                }
                Text(finding.assessment?.whatItIs ?? finding.item.kindHint)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryLabel)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            ConfidenceBadge(assessment: finding.assessment)
            if finding.decision.admission != .allow {
                AdmissionBadge(decision: finding.decision)
            }
            Text(ByteFormat.string(finding.item.sizeBytes))
                .font(.system(size: 14, weight: isChecked ? .medium : .regular))
                .monospacedDigit()
                .foregroundStyle(isChecked ? Theme.junk : Theme.secondaryLabel)
                .frame(width: 76, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .opacity(finding.isSelectable ? 1 : 0.5)
    }
}
