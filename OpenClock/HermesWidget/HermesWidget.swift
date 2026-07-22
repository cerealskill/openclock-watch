//
//  HermesWidget.swift
//  HermesWidget
//

import WidgetKit
import SwiftUI

struct HermesEntry: TimelineEntry {
    let date: Date
}

struct HermesProvider: TimelineProvider {
    func placeholder(in context: Context) -> HermesEntry { HermesEntry(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping (HermesEntry) -> Void) {
        completion(HermesEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HermesEntry>) -> Void) {
        completion(Timeline(entries: [HermesEntry(date: .now)], policy: .never))
    }
}

struct HermesWidgetEntryView: View {
    var entry: HermesEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Text("⚚")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(.white)
            }
            .widgetURL(URL(string: "hermesclock://open"))

        case .accessoryRectangular:
            HStack(spacing: 6) {
                Text("⚚")
                    .font(.system(size: 18, weight: .bold))
                VStack(alignment: .leading, spacing: 1) {
                    Text("HermesClock")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                    Text("Toca para hablar")
                        .font(.system(size: 10))
                        .foregroundColor(.gray)
                }
                Spacer()
            }
            .widgetURL(URL(string: "hermesclock://open"))

        case .accessoryInline:
            Label("HermesClock", systemImage: "mic.fill")
                .widgetURL(URL(string: "hermesclock://open"))

        default:
            Text("⚚")
                .widgetURL(URL(string: "hermesclock://open"))
        }
    }
}

struct HermesWidget: Widget {
    let kind = "HermesComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: HermesProvider()) { entry in
            HermesWidgetEntryView(entry: entry)
                .containerBackground(.black, for: .widget)
        }
        .configurationDisplayName("HermesClock")
        .description("Acceso rápido a Hermes")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

#Preview(as: .accessoryCircular) {
    HermesWidget()
} timeline: {
    HermesEntry(date: .now)
}
