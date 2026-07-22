//
//  OpenClawWidget.swift
//  OpenClawWidget
//

import WidgetKit
import SwiftUI

struct OpenClawEntry: TimelineEntry {
    let date: Date
}

struct OpenClawProvider: TimelineProvider {
    func placeholder(in context: Context) -> OpenClawEntry { OpenClawEntry(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping (OpenClawEntry) -> Void) {
        completion(OpenClawEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<OpenClawEntry>) -> Void) {
        completion(Timeline(entries: [OpenClawEntry(date: .now)], policy: .never))
    }
}

struct OpenClawWidgetEntryView: View {
    var entry: OpenClawEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Text("🦞")
                    .font(.system(size: 22))
            }
            .widgetURL(URL(string: "openclaw://open"))

        case .accessoryRectangular:
            HStack(spacing: 6) {
                Text("🦞")
                    .font(.system(size: 16))
                VStack(alignment: .leading, spacing: 1) {
                    Text("OpenClaw")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                    Text("Toca para hablar")
                        .font(.system(size: 10))
                        .foregroundColor(.gray)
                }
                Spacer()
            }
            .widgetURL(URL(string: "openclaw://open"))

        case .accessoryInline:
            Label("OpenClaw", systemImage: "mic.fill")
                .widgetURL(URL(string: "openclaw://open"))

        default:
            Text("🦞")
                .widgetURL(URL(string: "openclaw://open"))
        }
    }
}

struct OpenClawWidget: Widget {
    let kind = "OpenClawComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: OpenClawProvider()) { entry in
            OpenClawWidgetEntryView(entry: entry)
                .containerBackground(.black, for: .widget)
        }
        .configurationDisplayName("OpenClaw")
        .description("Acceso rápido a Rasputina")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

#Preview(as: .accessoryCircular) {
    OpenClawWidget()
} timeline: {
    OpenClawEntry(date: .now)
}
