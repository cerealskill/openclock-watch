import SwiftUI
import WatchKit
import AVFoundation


private class SpeechManager: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = SpeechManager()
    private let synth = AVSpeechSynthesizer()
    private var restartWorkItem: DispatchWorkItem?
    // Frases encoladas aún no terminadas: solo al llegar a 0 se libera el
    // frontmost extendido. Evita que la app se duerma entre frase y frase
    // y corte el audio a la mitad.
    private var pendingUtterances = 0

    override init() {
        super.init()
        synth.delegate = self
    }

    func speak(_ text: String) {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return }

        DispatchQueue.main.async {
            self.restartWorkItem?.cancel()

            // AVSpeechSynthesizer en watchOS a veces ignora un nuevo speak()
            // si se llama inmediatamente después de stopSpeaking(). Esperamos
            // un ciclo corto para que el sintetizador termine de cancelar.
            if self.synth.isSpeaking {
                self.pendingUtterances = 0
                self.synth.stopSpeaking(at: .immediate)
                let item = DispatchWorkItem { [weak self] in
                    self?.enqueue(cleanText)
                }
                self.restartWorkItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
            } else {
                self.enqueue(cleanText)
            }
        }
    }

    private func enqueue(_ text: String) {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // Si la sesión de audio falla por una interrupción temporal, no
            // abortamos: el sintetizador puede recuperarse en el siguiente tap.
        }

        WKExtension.shared().isFrontmostTimeoutExtended = true

        for chunk in speechChunks(from: text) {
            let utterance = AVSpeechUtterance(string: chunk)
            utterance.voice = AVSpeechSynthesisVoice(language: "es-CL")
                ?? AVSpeechSynthesisVoice(language: "es-ES")
            utterance.rate = 0.5
            utterance.preUtteranceDelay = 0.05
            pendingUtterances += 1
            synth.speak(utterance)
        }
    }

    private func speechChunks(from text: String) -> [String] {
        let sentenceChunks = text
            .components(separatedBy: CharacterSet(charactersIn: ".!?…\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let baseChunks = sentenceChunks.isEmpty ? [text] : sentenceChunks
        return baseChunks.flatMap { splitLongChunk($0, maxLength: 180) }
    }

    private func splitLongChunk(_ text: String, maxLength: Int) -> [String] {
        var chunks: [String] = []
        var current = ""

        for word in text.split(separator: " ") {
            let candidate = current.isEmpty ? String(word) : "\(current) \(word)"
            if candidate.count > maxLength, !current.isEmpty {
                chunks.append(current)
                current = String(word)
            } else {
                current = candidate
            }
        }

        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private func releaseFrontmostTimeoutIfIdle() {
        DispatchQueue.main.async {
            self.pendingUtterances = max(0, self.pendingUtterances - 1)
            if self.pendingUtterances == 0 && !self.synth.isSpeaking {
                WKExtension.shared().isFrontmostTimeoutExtended = false
            }
        }
    }

    // Encola sin cortar lo que ya se está hablando: para TTS incremental
    // durante el streaming (frase por frase).
    func speakAppending(_ text: String) {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return }
        DispatchQueue.main.async {
            self.enqueue(cleanText)
        }
    }

    // Corta todo: cola, frase actual y reinicios pendientes.
    func stopSpeaking() {
        DispatchQueue.main.async {
            self.restartWorkItem?.cancel()
            self.pendingUtterances = 0
            if self.synth.isSpeaking { self.synth.stopSpeaking(at: .immediate) }
            WKExtension.shared().isFrontmostTimeoutExtended = false
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        releaseFrontmostTimeoutIfIdle()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        releaseFrontmostTimeoutIfIdle()
    }
}

struct ContentView: View {
    @State private var message = ""
    @State private var reply = ""
    @State private var loading = false
    @State private var showReply = false
    @State private var clawPulse = false
    @State private var clawGlow = false
    @State private var loadingLabel = "Pensando con Hermes..."
    @State private var loadingTimer: Timer?
    @State private var loadingPhase = 0
    @State private var backendHealthy: Bool? = nil
    @State private var isStreaming = false
    @State private var chatTask: Task<Void, Never>? = nil
    @AppStorage("tts_muted") private var ttsMuted = false
    @State private var suppressSpeakerTap = false
    @State private var suppressMicTap = false

    private let transcribingMessages = [
        "Escuchando...", "Procesando audio...", "Analizando voz..."
    ]
    private let thinkingMessages = [
        "Pensando con Hermes...", "Consultando Hermes Agent...", "Buscando en la memoria...",
        "Abriendo herramientas...", "Procesando...", "Casi listo...",
        "Analizando tu pregunta...", "Un momento..."
    ]

    @AppStorage("hermes_chat_history") private var historyJSON: String = "[]"

    private struct ChatMessage: Codable {
        let role: String
        let content: String
    }

    private struct ChatRequestPayload: Codable {
        let message: String
        let session_key: String
        let history: [ChatMessage]
    }

    private struct ChatResponsePayload: Codable {
        let reply: String
        let backend: String?
        let session_key: String?
    }

    private struct TranscribeResponsePayload: Codable {
        let text: String?
        let error: String?
    }

    private struct StreamEventPayload: Codable {
        let delta: String?
        let done: Bool?
        let reply: String?
        let error: String?
    }

    private var history: [ChatMessage] {
        get {
            guard let data = historyJSON.data(using: .utf8),
                  let msgs = try? JSONDecoder().decode([ChatMessage].self, from: data)
            else { return [] }
            return msgs
        }
        set {
            let trimmed = newValue.count > 8 ? Array(newValue.suffix(8)) : newValue
            if let data = try? JSONEncoder().encode(trimmed),
               let str = String(data: data, encoding: .utf8) {
                historyJSON = str
            }
        }
    }

    // Conversación completa en pantalla (se persiste vía historyJSON)
    @State private var conversation: [ChatMessage] = []

    // Recording
    @State private var isRecording = false
    @State private var recordPulse = false
    @State private var audioRecorder: AVAudioRecorder?
    @State private var recordingDuration: TimeInterval = 0
    @State private var recordTimer: Timer?

    // Preview
    @State private var isPreviewing = false
    @State private var audioPlayer: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var playbackTime: TimeInterval = 0
    @State private var playTimer: Timer?

    private var recordedURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("hermesclock_recording.wav")
    }

    private var urlSession: URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 200
        config.timeoutIntervalForResource = 200
        return URLSession(configuration: config)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {

                HStack {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                    Text("HermesClock ⚚")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                    Spacer()
                }
                .padding(.leading, 18)
                .padding(.trailing, 8)
                .padding(.top, 12)
                .padding(.bottom, 2)

                Divider().background(Color.white.opacity(0.15))

                if !loading && !isRecording && !isPreviewing && !conversation.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(conversation.indices, id: \.self) { index in
                                    messageRow(conversation[index])
                                }
                                Color.clear.frame(height: 1).id("bottom")
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                        }
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                        }
                        .onChange(of: conversation.last?.content) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                        .clipped()
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        if isStreaming {
                        Button {
                            cancelResponse()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "stop.fill").font(.system(size: 11))
                                Text("Detener").font(.system(size: 12, weight: .medium))
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(Color.red.opacity(0.8))
                            .cornerRadius(20)
                        }
                        .buttonStyle(.plain)
                        } else {
                        Button {
                            // El tap tambien se dispara al soltar un long-press:
                            // si venimos de togglear el mute, no reproducir.
                            if suppressSpeakerTap {
                                suppressSpeakerTap = false
                                return
                            }
                            SpeechManager.shared.speak(reply)
                            WKInterfaceDevice.current().play(.click)
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(Color.white.opacity(0.12))
                                    .frame(width: 34, height: 34)
                                Image(systemName: ttsMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                    .font(.system(size: 13))
                                    .foregroundColor(ttsMuted ? .gray : .white)
                            }
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(
                            LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                                suppressSpeakerTap = true
                                ttsMuted.toggle()
                                if ttsMuted { SpeechManager.shared.stopSpeaking() }
                                WKInterfaceDevice.current().play(ttsMuted ? .directionDown : .directionUp)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                    suppressSpeakerTap = false
                                }
                            }
                        )

                        Button {
                            showReply = false
                            message = ""
                            reply = ""
                            startRecording()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "mic.fill").font(.system(size: 11))
                                Text("Nuevo").font(.system(size: 12, weight: .medium))
                            }
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(Color.white)
                            .cornerRadius(20)
                        }
                        .buttonStyle(.plain)

                        Button {
                            presentKeyboard()
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(Color.white.opacity(0.12))
                                    .frame(width: 34, height: 34)
                                Image(systemName: "keyboard")
                                    .font(.system(size: 13))
                                    .foregroundColor(.white)
                            }
                        }
                        .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)

                } else if loading {
                    Spacer()
                    VStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .stroke(Color.yellow.opacity(0.45), lineWidth: 1.5)
                                .frame(width: 72, height: 72)
                                .scaleEffect(clawGlow ? 1.5 : 1.0)
                                .opacity(clawGlow ? 0.0 : 0.6)
                            Image("HermesAvatar")
                                .resizable()
                                .scaledToFill()
                                .frame(width: 58, height: 58)
                                .clipShape(Circle())
                                .overlay(Circle().stroke(Color.yellow.opacity(0.35), lineWidth: 1))
                                .scaleEffect(clawPulse ? 1.1 : 0.92)
                        }
                        .onAppear {
                            withAnimation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true)) { clawPulse = true }
                            withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) { clawGlow = true }
                        }
                        Text(loadingLabel).font(.system(size: 12)).foregroundColor(.gray)
                        if !message.isEmpty {
                            Text("\"\(message)\"")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.5))
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .padding(.horizontal, 16)
                        }
                        Button {
                            cancelResponse()
                        } label: {
                            Text("Cancelar")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 4)
                                .background(Color.white.opacity(0.08))
                                .cornerRadius(12)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()

                } else if isRecording {
                    Spacer()
                    VStack(spacing: 10) {
                        // Tocar el mic: detener y ENVIAR de inmediato.
                        Button {
                            stopAndSend()
                        } label: {
                            ZStack {
                                Circle()
                                    .stroke(Color.red.opacity(0.6), lineWidth: 1.5)
                                    .frame(width: 44, height: 44)
                                    .scaleEffect(recordPulse ? 1.5 : 1.0)
                                    .opacity(recordPulse ? 0.0 : 0.8)
                                Circle()
                                    .fill(Color.red.opacity(0.12))
                                    .frame(width: 34, height: 34)
                                Image(systemName: "mic.fill")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(.red)
                            }
                        }
                        .buttonStyle(.plain)
                        .onAppear {
                            withAnimation(.easeOut(duration: 0.9).repeatForever(autoreverses: false)) { recordPulse = true }
                        }
                        .onDisappear { recordPulse = false }

                        Text(formatDuration(recordingDuration))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white)
                            .monospacedDigit()
                    }
                    Spacer()

                    // Stop: detener SIN enviar (pasa al preview para revisar o botar).
                    Button {
                        stopToPreview()
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.12))
                                .frame(width: 44, height: 44)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.red)
                                .frame(width: 15, height: 15)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 8)

                } else if isPreviewing {
                    Spacer()
                    VStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .stroke(Color.white.opacity(0.1), lineWidth: 3)
                                .frame(width: 54, height: 54)
                            Circle()
                                .trim(from: 0, to: {
                                    let total = audioPlayer?.duration ?? 0
                                    return total > 0 ? min(playbackTime / total, 1) : 0
                                }())
                                .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                .frame(width: 54, height: 54)
                                .rotationEffect(.degrees(-90))
                                .animation(.linear(duration: 0.05), value: playbackTime)
                            Button {
                                togglePlayback()
                            } label: {
                                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 20, weight: .medium))
                                    .foregroundColor(.white)
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain)
                        }

                        Text(isPlaying ? formatDuration(playbackTime) : formatDuration(audioPlayer?.duration ?? 0))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.gray)
                            .monospacedDigit()
                    }
                    Spacer()

                    HStack(spacing: 10) {
                        Button {
                            discardRecording()
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(Color.white.opacity(0.1))
                                    .frame(width: 38, height: 38)
                                Image(systemName: "trash")
                                    .font(.system(size: 14))
                                    .foregroundColor(.gray)
                            }
                        }
                        .buttonStyle(.plain)

                        Button {
                            sendRecording()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.up.circle.fill").font(.system(size: 11))
                                Text("Enviar").font(.system(size: 12, weight: .medium))
                            }
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(Color.white)
                            .cornerRadius(20)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)

                } else {
                    Spacer()
                    Button {
                        if suppressMicTap {
                            suppressMicTap = false
                            return
                        }
                        startRecording()
                    } label: {
                        VStack(spacing: 6) {
                            ZStack {
                                Circle()
                                    .fill(Color.white.opacity(0.08))
                                    .frame(width: 56, height: 56)
                                Circle()
                                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
                                    .frame(width: 56, height: 56)
                                Image(systemName: "mic.fill")
                                    .font(.system(size: 22, weight: .medium))
                                    .foregroundColor(.white)
                            }
                            Text("Toca: hablar · mantén: escribir")
                                .font(.system(size: 10))
                                .foregroundColor(.gray)
                        }
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                            suppressMicTap = true
                            WKInterfaceDevice.current().play(.click)
                            presentKeyboard()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                suppressMicTap = false
                            }
                        }
                    )
                    Spacer()
                }
            }
            .ignoresSafeArea(edges: [.top, .bottom])
        }
        .task {
            if conversation.isEmpty { conversation = history }
            if AutoRecordRequest.shared.pending { triggerAutoRecord() }
            await checkHealth()
        }
        .onOpenURL { _ in triggerAutoRecord() }
        .onReceive(NotificationCenter.default.publisher(for: .autoRecord)) { _ in
            triggerAutoRecord()
        }
    }

    // Complicación, Botón de Acción o Siri: entrar directo a grabar.
    func triggerAutoRecord() {
        AutoRecordRequest.shared.pending = false
        guard !isRecording && !loading else { return }
        if isPreviewing { discardRecording() }
        showReply = false
        message = ""
        reply = ""
        startRecording()
    }

    @ViewBuilder
    private func messageRow(_ msg: ChatMessage) -> some View {
        HStack(alignment: .top, spacing: msg.role == "user" ? 6 : 7) {
            if msg.role == "user" {
                Text("Tú")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.gray)
                Text(msg.content)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.leading)
            } else {
                Image("HermesAvatar")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 22, height: 22)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.8))
                Text(msg.content)
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Actualiza (o crea) el último mensaje del asistente en la conversación.
    private func setAssistantReply(_ text: String) {
        if conversation.last?.role == "assistant" {
            conversation[conversation.count - 1] = ChatMessage(role: "assistant", content: text)
        } else {
            conversation.append(ChatMessage(role: "assistant", content: text))
        }
        reply = text
    }

    private func persistConversation() {
        let trimmed = conversation.count > 8 ? Array(conversation.suffix(8)) : conversation
        if let data = try? JSONEncoder().encode(trimmed),
           let str = String(data: data, encoding: .utf8) {
            historyJSON = str
        }
    }

    private var statusColor: Color {
        if loading { return .yellow }
        if isRecording { return .red }
        switch backendHealthy {
        case .some(true): return .green
        case .some(false): return .red
        case .none: return .gray
        }
    }

    func checkHealth() async {
        guard let url = URL(string: "https://open.panicbots.com/hermes/health") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
                && ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["ok"] as? Bool ?? false)
            await MainActor.run { backendHealthy = ok }
        } catch {
            await MainActor.run { backendHealthy = false }
        }
    }

    // MARK: - Loading messages

    func startLoadingCycle(messages: [String]) {
        loadingPhase = 0
        loadingLabel = messages[0]
        loadingTimer?.invalidate()
        loadingTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            DispatchQueue.main.async {
                loadingPhase = (loadingPhase + 1) % messages.count
                withAnimation(.easeInOut(duration: 0.4)) {
                    loadingLabel = messages[loadingPhase]
                }
            }
        }
    }

    func stopLoadingCycle() {
        loadingTimer?.invalidate()
        loadingTimer = nil
    }

    // MARK: - Recording

    func startRecording() {
        // Barge-in: si esta hablando, se calla al empezar a grabar.
        SpeechManager.shared.stopSpeaking()
        AVAudioApplication.requestRecordPermission { granted in
            guard granted else { return }
            DispatchQueue.main.async {
                try? beginRecording()
            }
        }
    }

    func beginRecording() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .default)
        try audioSession.setActive(true)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        let recorder = try AVAudioRecorder(url: recordedURL, settings: settings)
        recorder.record()
        audioRecorder = recorder
        recordingDuration = 0
        isRecording = true
        WKExtension.shared().isFrontmostTimeoutExtended = true
        WKInterfaceDevice.current().play(.start)

        recordTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            DispatchQueue.main.async { recordingDuration += 0.1 }
        }
    }

    private func finishRecording() {
        recordTimer?.invalidate()
        recordTimer = nil
        audioRecorder?.stop()
        audioRecorder = nil
        isRecording = false
        WKExtension.shared().isFrontmostTimeoutExtended = false
        WKInterfaceDevice.current().play(.stop)
    }

    // Tocar el mic durante la grabación: detener y enviar de inmediato.
    // Toques accidentales (<0.6s) se descartan en silencio.
    func stopAndSend() {
        finishRecording()
        guard recordingDuration >= 0.6 else {
            try? FileManager.default.removeItem(at: recordedURL)
            return
        }
        isStreaming = true
        chatTask = Task { await transcribeAndChat() }
    }

    // Tocar stop: detener sin enviar; queda en preview para revisar,
    // botar o enviar después.
    func stopToPreview() {
        finishRecording()
        guard let player = try? AVAudioPlayer(contentsOf: recordedURL) else { return }
        player.prepareToPlay()
        audioPlayer = player
        recordingDuration = player.duration
        isPreviewing = true
    }

    // MARK: - Preview

    func togglePlayback() {
        guard let player = audioPlayer else { return }
        if isPlaying {
            player.pause()
            playTimer?.invalidate()
            isPlaying = false
        } else {
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            if player.currentTime >= player.duration { player.currentTime = 0 }
            player.play()
            isPlaying = true
            playTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
                DispatchQueue.main.async {
                    playbackTime = player.currentTime
                    if !player.isPlaying {
                        isPlaying = false
                        playbackTime = 0
                        player.currentTime = 0
                        playTimer?.invalidate()
                    }
                }
            }
        }
    }

    func discardRecording() {
        stopPlayback()
        audioPlayer = nil
        isPreviewing = false
        recordingDuration = 0
        try? FileManager.default.removeItem(at: recordedURL)
        WKInterfaceDevice.current().play(.click)
    }

    func sendRecording() {
        stopPlayback()
        audioPlayer = nil
        isPreviewing = false
        isStreaming = true
        chatTask = Task { await transcribeAndChat() }
    }

    func stopPlayback() {
        audioPlayer?.stop()
        playTimer?.invalidate()
        playTimer = nil
        isPlaying = false
        playbackTime = 0
    }

    // MARK: - Transcription + Chat

    func transcribeAndChat() async {
        guard let audioData = try? Data(contentsOf: recordedURL) else {
            await MainActor.run {
                setAssistantReply("Error al leer el audio")
                showReply = true
            }
            return
        }

        await MainActor.run {
            clawPulse = false
            clawGlow = false
            loading = true
            showReply = false
            reply = ""
            startLoadingCycle(messages: transcribingMessages)
        }

        guard let transcribeURL = URL(string: "https://open.panicbots.com/hermes/transcribe") else { return }
        var transcribeRequest = URLRequest(url: transcribeURL)
        transcribeRequest.httpMethod = "POST"

        let boundary = "Boundary-\(UUID().uuidString)"
        transcribeRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"audio\"; filename=\"recording.wav\"\r\n")
        body.append("Content-Type: audio/wav\r\n\r\n")
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n")
        transcribeRequest.httpBody = body

        do {
            let (transcribeData, transcribeResponse) = try await urlSession.data(for: transcribeRequest)
            if let http = transcribeResponse as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let details = String(data: transcribeData, encoding: .utf8) ?? "sin detalle"
                await MainActor.run {
                    stopLoadingCycle()
                    setAssistantReply("Error transcripción HTTP \(http.statusCode): \(details.prefix(120))")
                    loading = false
                    showReply = true
                    isStreaming = false
                    WKInterfaceDevice.current().play(.failure)
                    speak("Ocurrió un error al transcribir")
                }
                return
            }

            let payload = try JSONDecoder().decode(TranscribeResponsePayload.self, from: transcribeData)
            guard let text = payload.text, !text.isEmpty else {
                await MainActor.run {
                    stopLoadingCycle()
                    setAssistantReply(payload.error == nil ? "No se entendió el audio" : "Error transcripción: \(payload.error!)")
                    loading = false
                    showReply = true
                    isStreaming = false
                    WKInterfaceDevice.current().play(.failure)
                    speak("No se entendió el audio")
                }
                return
            }

            // Comando de voz: "borra el historial" / "nueva conversación"
            if isResetCommand(text) {
                await MainActor.run {
                    stopLoadingCycle()
                    loading = false
                    conversation = []
                    historyJSON = "[]"
                    message = ""
                    setAssistantReply("Historial borrado. Empezamos de cero.")
                    showReply = true
                    isStreaming = false
                    WKInterfaceDevice.current().play(.success)
                    speak("Listo, empezamos de cero")
                }
                await resetBackendSession()
                return
            }

            // Comando de voz: "modo silencio" / "activa el sonido"
            let lowerText = text.lowercased()
            if lowerText.contains("modo silencio") || lowerText.contains("silenciate") || lowerText.contains("silénciate") {
                await MainActor.run {
                    stopLoadingCycle()
                    loading = false
                    isStreaming = false
                    ttsMuted = true
                    SpeechManager.shared.stopSpeaking()
                    setAssistantReply("Modo silencio activado 🔇")
                    showReply = true
                    WKInterfaceDevice.current().play(.directionDown)
                }
                return
            }
            if lowerText.contains("activa el sonido") || lowerText.contains("quita el silencio") || lowerText.contains("desactiva el silencio") {
                await MainActor.run {
                    stopLoadingCycle()
                    loading = false
                    isStreaming = false
                    ttsMuted = false
                    setAssistantReply("Sonido activado 🔊")
                    showReply = true
                    WKInterfaceDevice.current().play(.directionUp)
                    SpeechManager.shared.speak("Sonido activado")
                }
                return
            }

            await MainActor.run {
                message = text
                conversation.append(ChatMessage(role: "user", content: text))
                startLoadingCycle(messages: thinkingMessages)
            }
            await sendMessage(text: text)

        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                return
            }
            await MainActor.run {
                stopLoadingCycle()
                setAssistantReply("Error: \(error.localizedDescription)")
                loading = false
                showReply = true
                isStreaming = false
                WKInterfaceDevice.current().play(.failure)
                speak("Ocurrió un error")
            }
        }
    }

    func sendMessage(text: String) async {
        // Streaming SSE: el texto aparece progresivamente; si algo falla,
        // sendMessageClassic reintenta contra el endpoint normal.
        guard let url = URL(string: "https://open.panicbots.com/hermes/chat/stream") else {
            await MainActor.run { reply = "URL inválida"; loading = false; showReply = true }
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ChatRequestPayload(message: text, session_key: "hermes_watch", history: history)

        do {
            request.httpBody = try JSONEncoder().encode(body)
            let (bytes, response) = try await urlSession.bytes(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }

            var fullReply = ""
            var finalReply: String? = nil
            var spokenChars = 0
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let payloadText = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                guard let data = payloadText.data(using: .utf8),
                      let event = try? JSONDecoder().decode(StreamEventPayload.self, from: data) else { continue }

                if let errorText = event.error {
                    throw NSError(domain: "stream", code: 1, userInfo: [NSLocalizedDescriptionKey: errorText])
                }
                if let delta = event.delta {
                    fullReply += delta
                    let current = fullReply
                    // TTS incremental: habla cada oración completa apenas llega.
                    let pending = String(fullReply.dropFirst(spokenChars))
                    var sentence: String? = nil
                    if let idx = pending.lastIndex(where: { ".!?…\n".contains($0) }) {
                        sentence = String(pending[...idx])
                        spokenChars += sentence!.count
                    }
                    await MainActor.run {
                        stopLoadingCycle()
                        loading = false
                        showReply = true
                        setAssistantReply(current)
                        if let sentence, !ttsMuted { SpeechManager.shared.speakAppending(sentence) }
                    }
                }
                if event.done == true {
                    finalReply = event.reply ?? fullReply
                    break
                }
            }

            guard let agentReply = finalReply ?? (fullReply.isEmpty ? nil : fullReply) else {
                if Task.isCancelled { return }
                await sendMessageClassic(text: text)
                return
            }

            let remaining = String(fullReply.dropFirst(spokenChars))
            await MainActor.run {
                stopLoadingCycle()
                loading = false
                showReply = true
                setAssistantReply(agentReply)
                persistConversation()
                isStreaming = false
                WKInterfaceDevice.current().play(.success)
                if !ttsMuted { SpeechManager.shared.speakAppending(remaining) }
            }
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                return
            }
            await sendMessageClassic(text: text)
        }
    }

    func sendMessageClassic(text: String) async {
        guard let url = URL(string: "https://open.panicbots.com/hermes/chat") else {
            await MainActor.run { reply = "URL inválida"; loading = false; showReply = true }
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ChatRequestPayload(message: text, session_key: "hermes_watch", history: history)

        do {
            request.httpBody = try JSONEncoder().encode(body)
            let (data, _) = try await urlSession.data(for: request)
            let payload = try JSONDecoder().decode(ChatResponsePayload.self, from: data)
            let agentReply = payload.reply
            await MainActor.run {
                stopLoadingCycle()
                loading = false
                showReply = true
                setAssistantReply(agentReply)
                persistConversation()
                isStreaming = false
                WKInterfaceDevice.current().play(.success)
                speak(agentReply)
            }
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                return
            }
            await MainActor.run {
                stopLoadingCycle()
                setAssistantReply("Error: \(error.localizedDescription)")
                loading = false
                showReply = true
                isStreaming = false
                WKInterfaceDevice.current().play(.failure)
                speak("Ocurrió un error")
            }
        }
    }

    private func isResetCommand(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.contains("borra el historial") || t.contains("borrar el historial")
            || t.contains("limpia el historial") || t.contains("nueva conversación")
            || t.contains("nueva conversacion")
    }

    func resetBackendSession() async {
        guard let url = URL(string: "https://open.panicbots.com/hermes/reset") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["session_key": "hermes_watch"])
        _ = try? await URLSession.shared.data(for: request)
    }

    // Detiene la respuesta en curso: red, streaming y voz.
    func cancelResponse() {
        chatTask?.cancel()
        chatTask = nil
        SpeechManager.shared.stopSpeaking()
        stopLoadingCycle()
        loading = false
        isStreaming = false
        showReply = true
        WKInterfaceDevice.current().play(.stop)
    }

    // Abre el teclado/scribble nativo de watchOS y envia lo escrito.
    func presentKeyboard() {
        SpeechManager.shared.stopSpeaking()
        WKExtension.shared().visibleInterfaceController?.presentTextInputController(
            withSuggestions: nil,
            allowedInputMode: .allowEmoji
        ) { results in
            if let text = results?.first as? String {
                DispatchQueue.main.async { sendTyped(text) }
            }
        }
    }

    // Entrada por teclado: mismo pipeline que el dictado, sin audio.
    func sendTyped(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        SpeechManager.shared.stopSpeaking()
        isStreaming = true
        chatTask = Task {
            await MainActor.run {
                showReply = false
                reply = ""
                message = clean
                conversation.append(ChatMessage(role: "user", content: clean))
                loading = true
                startLoadingCycle(messages: thinkingMessages)
            }
            await sendMessage(text: clean)
        }
    }

    func speak(_ text: String) {
        guard !ttsMuted else { return }
        SpeechManager.shared.speak(text)
    }

    func formatDuration(_ time: TimeInterval) -> String {
        let t = max(0, time)
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) { append(data) }
    }
}
