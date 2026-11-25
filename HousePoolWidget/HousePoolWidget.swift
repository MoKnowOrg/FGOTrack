import SwiftUI
import WidgetKit

struct PoolTimelineEntry: TimelineEntry {
    let date: Date
    let snapshot: PoolWidgetSnapshot
}
struct PoolTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> PoolTimelineEntry { PoolTimelineEntry(date: Date(), snapshot: PoolWidgetSnapshot(balance: 850000, spent: 150000, pending: 2, month: "House pool", updated: Date())) }
    func getSnapshot(in context: Context, completion: @escaping (PoolTimelineEntry) -> Void) { completion(context.isPreview ? placeholder(in: context) : PoolTimelineEntry(date: Date(), snapshot: .read())) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<PoolTimelineEntry>) -> Void) {
        completion(Timeline(entries: [PoolTimelineEntry(date: Date(), snapshot: .read())], policy: .after(Date().addingTimeInterval(900))))
    }
}
struct PoolWidgetView: View {
    let entry: PoolTimelineEntry
    @Environment(\.widgetFamily) private var family
    private var status: BudgetStatus { BudgetHealth.poolStatus(balance: entry.snapshot.balance, spent: entry.snapshot.spent) }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("HOUSE POOL", systemImage: "house.fill").font(.caption2.bold())
            if entry.snapshot.updated == .distantPast { Text("Open FGOTrack to get started").font(.headline) }
            else {
                Text(money(entry.snapshot.balance)).font(.title.bold()).foregroundStyle(status.textColor).minimumScaleFactor(0.5).lineLimit(1).privacySensitive()
                Label(status.poolLabel, systemImage: status.icon).font(.caption.weight(.semibold)).foregroundStyle(status.textColor)
                if family == .systemMedium { Text(entry.snapshot.month).font(.caption).foregroundStyle(.secondary) }
                if entry.snapshot.pending > 0 { Text("\(entry.snapshot.pending) \(entry.snapshot.pending == 1 ? "receipt" : "receipts") to review").font(.caption).foregroundStyle(.secondary).privacySensitive() }
            }
            Spacer(minLength: 0)
            if family == .systemMedium {
                HStack {
                    Link(destination: URL(string: "fgotrack://quick/photo?source=pooled")!) { Label("Scan receipt", systemImage: "camera.fill") }
                    Spacer()
                    Link(destination: URL(string: "fgotrack://quick/manual?source=pooled")!) { Label("Add expense", systemImage: "plus.circle") }
                }.font(.subheadline.bold())
            } else { Label("Scan receipt", systemImage: "camera.fill").font(.subheadline.bold()) }
        }.containerBackground(Color(uiColor: .secondarySystemGroupedBackground), for: .widget)
        .widgetURL(URL(string: "fgotrack://quick/photo?source=pooled"))
    }
}
@main struct HousePoolWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "HousePoolWidget", provider: PoolTimelineProvider()) { entry in PoolWidgetView(entry: entry) }
            .configurationDisplayName("House pool")
            .description("Check your pool and save a receipt in seconds.")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}
