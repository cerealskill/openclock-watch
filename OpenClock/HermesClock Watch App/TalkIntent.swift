//
//  TalkIntent.swift
//  HermesClock Watch App
//
//  App Intent para el Botón de Acción del Ultra / Atajos / Siri:
//  abre la app y empieza a grabar de inmediato.
//

import AppIntents
import Foundation

// Señal compartida entre el intent y ContentView: si el intent corre antes de
// que la vista exista (cold launch), la vista revisa `pending` en su .task.
final class AutoRecordRequest {
    static let shared = AutoRecordRequest()
    var pending = false
}

extension Notification.Name {
    static let autoRecord = Notification.Name("autoRecord")
}

struct TalkIntent: AppIntent {
    static var title: LocalizedStringResource = "Hablar con Hermes"
    static var description = IntentDescription("Abre HermesClock y empieza a grabar de inmediato.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AutoRecordRequest.shared.pending = true
        NotificationCenter.default.post(name: .autoRecord, object: nil)
        return .result()
    }
}

struct HermesClockShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TalkIntent(),
            phrases: ["Habla con \(.applicationName)"],
            shortTitle: "Hablar",
            systemImageName: "mic.fill"
        )
    }
}
