import SwiftUI
import WidgetKit

// Tick widgets: small, medium, lock-screen rectangular + inline.
// They read a snapshot JSON written by the Flutter app (home_widget) into the App Group "group.com.prithvi.tick".
// Colors follow the brand: Ink #0E0E12, Volt #C8FF2E (a fill; text on Volt is always Ink), Paper #F5F3EC, Mist #A3A3AF, Clay #FF6B4A, Sky #7AA7FF.

private let appGroup = "group.com.prithvi.tick"

struct TickSnapshot: Codable {
  var safeCents: Int = 0
  var until: String = "payday"
  var spentTodayCents: Int = 0
  var nextBillName: String? = nil
  var nextBillCents: Int? = nil
  var nextBillDay: String? = nil
  var hasData: Bool = false

  static func load() -> TickSnapshot {
    guard let raw = UserDefaults(suiteName: appGroup)?.string(forKey: "snapshot"),
          let data = raw.data(using: .utf8),
          let s = try? JSONDecoder().decode(TickSnapshot.self, from: data) else { return TickSnapshot() }
    return s
  }
}

struct Entry: TimelineEntry {
  let date: Date
  let snap: TickSnapshot
}

struct Provider: TimelineProvider {
  func placeholder(in context: Context) -> Entry {
    Entry(date: .now, snap: TickSnapshot(safeCents: 21400, until: "Friday", spentTodayCents: 2415, nextBillName: "Internet", nextBillCents: 6400, nextBillDay: "tomorrow", hasData: true))
  }
  func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) { completion(Entry(date: .now, snap: TickSnapshot.load())) }
  func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
    let entry = Entry(date: .now, snap: TickSnapshot.load())
    // The app pushes fresh data and reloads timelines; this is only a backstop.
    completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(30 * 60))))
  }
}

private func dollars(_ cents: Int) -> String {
  let f = NumberFormatter(); f.numberStyle = .currency; f.currencyCode = "USD"; f.maximumFractionDigits = 0
  return f.string(from: NSNumber(value: Double(cents) / 100)) ?? "$0"
}

extension Color {
  static let ink = Color(red: 0x0E / 255, green: 0x0E / 255, blue: 0x12 / 255)
  static let volt = Color(red: 0xC8 / 255, green: 0xFF / 255, blue: 0x2E / 255)
  static let paper = Color(red: 0xF5 / 255, green: 0xF3 / 255, blue: 0xEC / 255)
  static let mist = Color(red: 0xA3 / 255, green: 0xA3 / 255, blue: 0xAF / 255)
  static let clay = Color(red: 1, green: 0x6B / 255, blue: 0x4A / 255)
}

struct StickerAmount: View {
  let cents: Int
  let size: CGFloat
  var body: some View {
    Text(dollars(cents))
      .font(.system(size: size, weight: .heavy, design: .rounded))   // Cabinet Grotesk can be bundled with the extension; rounded system is the fallback
      .minimumScaleFactor(0.6).lineLimit(1)
      .foregroundColor(.ink)
      .padding(.horizontal, 16).padding(.vertical, 6)
      .background(Capsule().fill(Color.volt))
      .rotationEffect(.degrees(-2.5))
  }
}

struct SmallView: View {
  let snap: TickSnapshot
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Safe to spend").font(.system(size: 12, weight: .bold)).foregroundColor(.mist)
      if snap.hasData {
        StickerAmount(cents: snap.safeCents, size: 30)
        Text("until \(snap.until)").font(.system(size: 12, weight: .medium)).foregroundColor(.paper)
      } else {
        Text("Open Tick").font(.system(size: 16, weight: .bold)).foregroundColor(.paper)
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct MediumView: View {
  let snap: TickSnapshot
  var body: some View {
    HStack(spacing: 16) {
      SmallView(snap: snap)
      VStack(alignment: .leading, spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Spent today").font(.system(size: 12, weight: .bold)).foregroundColor(.mist)
          Text(dollars(snap.spentTodayCents)).font(.system(size: 20, weight: .semibold, design: .monospaced)).foregroundColor(.paper)
        }
        if let name = snap.nextBillName, let c = snap.nextBillCents {
          VStack(alignment: .leading, spacing: 2) {
            Text("Next bill").font(.system(size: 12, weight: .bold)).foregroundColor(.clay)
            Text("\(name) \(dollars(c))").font(.system(size: 14, weight: .semibold)).foregroundColor(.paper).lineLimit(1)
            if let d = snap.nextBillDay { Text(d).font(.system(size: 12)).foregroundColor(.mist) }
          }
        }
        Spacer(minLength: 0)
      }.frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

struct LockRect: View {
  let snap: TickSnapshot
  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("Safe to spend").font(.system(size: 12, weight: .semibold))
      Text(snap.hasData ? dollars(snap.safeCents) : "Open Tick").font(.system(size: 22, weight: .heavy, design: .rounded))
      if snap.hasData { Text("until \(snap.until)").font(.system(size: 11)) }
    }
  }
}

struct TickWidgetView: View {
  @Environment(\.widgetFamily) var family
  let entry: Entry
  var body: some View {
    switch family {
    case .systemSmall: SmallView(snap: entry.snap).padding(14).containerBackground(Color.ink, for: .widget)
    case .systemMedium: MediumView(snap: entry.snap).padding(14).containerBackground(Color.ink, for: .widget)
    case .accessoryRectangular: LockRect(snap: entry.snap).containerBackground(.clear, for: .widget)
    case .accessoryInline: Text(entry.snap.hasData ? "\(dollars(entry.snap.safeCents)) safe to spend" : "Tick")
    default: SmallView(snap: entry.snap).padding(14).containerBackground(Color.ink, for: .widget)
    }
  }
}

@main
struct TickWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "TickWidget", provider: Provider()) { entry in
      TickWidgetView(entry: entry).widgetURL(URL(string: "tick://today"))
    }
    .configurationDisplayName("Safe to spend")
    .description("What you can spend until payday.")
    .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
  }
}
