import SwiftUI

struct WorkflowStep: Identifiable {
    let id: Int
    let title: String
    let systemImage: String
    let hint: String
    let isComplete: Bool
    let isActive: Bool
    var isInProgress: Bool = false
}

struct WorkflowGuideView: View {
    let steps: [WorkflowStep]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                if index > 0 {
                    connector(isComplete: steps[index - 1].isComplete)
                }
                stepView(step)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func stepView(_ step: WorkflowStep) -> some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(step.isComplete ? Color.green.opacity(0.15) : (step.isActive ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1)))
                    .frame(width: 28, height: 28)
                if step.isInProgress {
                    ProgressView()
                        .controlSize(.small)
                } else if step.isComplete {
                    Image(systemName: "checkmark")
                        .font(.caption.bold())
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: step.systemImage)
                        .font(.caption)
                        .foregroundStyle(step.isActive ? Color.accentColor : .secondary)
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("Step \(step.id)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(step.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(step.isActive || step.isComplete ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(step.hint)
    }

    private func connector(isComplete: Bool) -> some View {
        Rectangle()
            .fill(isComplete ? Color.green.opacity(0.4) : Color.secondary.opacity(0.2))
            .frame(width: 24, height: 2)
            .padding(.horizontal, 4)
    }
}
