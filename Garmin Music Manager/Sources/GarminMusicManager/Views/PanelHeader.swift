import SwiftUI

struct PanelHeader<Trailing: View>: View {
    let side: PanelSide
    let title: String
    let subtitle: String
    let systemImage: String
    var chips: [String] = []
    @ViewBuilder var trailing: () -> Trailing

    init(
        side: PanelSide,
        title: String,
        subtitle: String,
        systemImage: String,
        chips: [String] = [],
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.side = side
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.chips = chips
        self.trailing = trailing
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            regularHeader
            compactHeader
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(AppTheme.panelBackground(for: side))
    }

    private var regularHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            headerIcon
            titleBlock(showChips: true)
                .layoutPriority(1)

            Spacer(minLength: 8)
            trailing()
                .layoutPriority(2)
        }
    }

    private var compactHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                headerIcon
                titleBlock(showChips: false)
                    .layoutPriority(1)

                Spacer(minLength: 8)
                trailing()
                    .layoutPriority(2)
            }

            if !chips.isEmpty {
                chipScroller
                    .padding(.leading, 40)
            }
        }
    }

    private var headerIcon: some View {
        Image(systemName: systemImage)
            .font(.title3)
            .foregroundStyle(AppTheme.panelAccent(for: side))
            .frame(width: 28)
    }

    private func titleBlock(showChips: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if showChips, !chips.isEmpty {
                chipRow
            }
        }
    }

    private var chipRow: some View {
        HStack(spacing: 6) {
            ForEach(chips, id: \.self) { chip in
                StatChip(text: chip, tint: AppTheme.panelAccent(for: side))
            }
        }
    }

    private var chipScroller: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            chipRow
        }
    }
}
