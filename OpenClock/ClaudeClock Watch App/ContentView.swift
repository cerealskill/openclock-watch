import SwiftUI
import WatchKit
import AVFoundation


private class SpeechManager: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = SpeechManager()
    private let synth = AVSpeechSynthesizer()

    override init() {
        super.init()
        synth.delegate = self
    }

    func speak(_ text: String) {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: .duckOthers)
        try? AVAudioSession.sharedInstance().setActive(true)
        WKExtension.shared().isFrontmostTimeoutExtended = true

        let sentences = text
            .components(separatedBy: CharacterSet(charactersIn: ".!?…\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let chunks = sentences.isEmpty ? [text] : sentences
        for chunk in chunks {
            let utterance = AVSpeechUtterance(string: chunk)
            utterance.voice = AVSpeechSynthesisVoice(language: "es-CL")
            utterance.rate = 0.5
            utterance.preUtteranceDelay = 0.05
            synth.speak(utterance)
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        if !synthesizer.isSpeaking {
            WKExtension.shared().isFrontmostTimeoutExtended = false
        }
    }
}

struct ContentView: View {
    @State private var message = ""
    @State private var reply = ""
    @State private var loading = false
    @State private var showReply = false
    @State private var clawPulse = false
    @State private var clawGlow = false
    @State private var loadingLabel = "Pensando con Claude..."
    @State private var loadingTimer: Timer?
    @State private var loadingPhase = 0

    private let transcribingMessages = [
        "Escuchando...", "Procesando audio...", "Analizando voz..."
    ]
    private let thinkingMessages = [
        "Pensando con Claude...", "Consultando Claude...", "Revisando contexto...",
        "Abriendo herramientas...", "Procesando...", "Casi listo...",
        "Analizando tu pregunta...", "Un momento..."
    ]

    @AppStorage("claude_chat_history") private var historyJSON: String = "[]"

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
            .appendingPathComponent("claudeclock_recording.wav")
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
                        .fill(loading ? Color.orange : isRecording ? Color.red : Color.green)
                        .frame(width: 7, height: 7)
                    Text("Claude Clock ✦")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 4)

                Divider().background(Color.white.opacity(0.15))

                if showReply && !reply.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                if !message.isEmpty {
                                    HStack(alignment: .top, spacing: 6) {
                                        Text("Tú")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundColor(.gray)
                                        Text(message)
                                            .font(.system(size: 11))
                                            .foregroundColor(.white.opacity(0.7))
                                            .multilineTextAlignment(.leading)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                HStack(alignment: .top, spacing: 7) {
                                    Image("ClaudeAvatar")
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 22, height: 22)
                                        .clipShape(Circle())
                                        .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.8))
                                    Text(reply)
                                        .font(.system(size: 12))
                                        .foregroundColor(.white)
                                        .multilineTextAlignment(.leading)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Color.clear.frame(height: 1).id("bottom")
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                        }
                        .onAppear {
                            let words = reply.split(separator: " ").count
                            let duration = max(2.5, Double(words) * 0.35)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                withAnimation(.linear(duration: duration)) {
                                    proxy.scrollTo("bottom", anchor: .bottom)
                                }
                            }
                        }
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        Button {
                            speak(reply)
                            WKInterfaceDevice.current().play(.click)
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(Color.white.opacity(0.12))
                                    .frame(width: 34, height: 34)
                                Image(systemName: "speaker.wave.2.fill")
                                    .font(.system(size: 13))
                                    .foregroundColor(.white)
                            }
                        }
                        .buttonStyle(.plain)

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
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)

                } else if loading {
                    Spacer()
                    VStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .stroke(Color.orange.opacity(0.45), lineWidth: 1.5)
                                .frame(width: 72, height: 72)
                                .scaleEffect(clawGlow ? 1.5 : 1.0)
                                .opacity(clawGlow ? 0.0 : 0.6)
                            Image("ClaudeAvatar")
                                .resizable()
                                .scaledToFill()
                                .frame(width: 58, height: 58)
                                .clipShape(Circle())
                                .overlay(Circle().stroke(Color.orange.opacity(0.35), lineWidth: 1))
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
                    }
                    Spacer()

                } else if isRecording {
                    Spacer()
                    VStack(spacing: 10) {
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

                    Button {
                        stopRecording()
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
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)

                } else {
                    Spacer()
                    Button {
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
                            Text("Toca para hablar")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                        }
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
            }
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

    func stopRecording() {
        recordTimer?.invalidate()
        recordTimer = nil
        audioRecorder?.stop()
        audioRecorder = nil
        isRecording = false
        WKExtension.shared().isFrontmostTimeoutExtended = false
        WKInterfaceDevice.current().play(.stop)

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
        Task { await transcribeAndChat() }
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
                reply = "Error al leer el audio"
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

        guard let transcribeURL = URL(string: "https://open.panicbots.com/claude/transcribe") else { return }
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
            let (transcribeData, _) = try await urlSession.data(for: transcribeRequest)
            let payload = try JSONDecoder().decode(TranscribeResponsePayload.self, from: transcribeData)
            guard let text = payload.text, !text.isEmpty else {
                await MainActor.run {
                    reply = payload.error == nil ? "No se entendió el audio" : "Error transcripción: \(payload.error!)"
                    loading = false
                    showReply = true
                    WKInterfaceDevice.current().play(.failure)
                    speak("No se entendió el audio")
                }
                return
            }

            await MainActor.run {
                message = text
                startLoadingCycle(messages: thinkingMessages)
            }
            await sendMessage(text: text)

        } catch {
            await MainActor.run {
                reply = "Error: \(error.localizedDescription)"
                loading = false
                showReply = true
                WKInterfaceDevice.current().play(.failure)
                speak("Ocurrió un error")
            }
        }
    }

    func sendMessage(text: String) async {
        guard let url = URL(string: "https://open.panicbots.com/claude/chat") else {
            await MainActor.run { reply = "URL inválida"; loading = false; showReply = true }
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ChatRequestPayload(message: text, session_key: "claude_watch", history: history)

        do {
            request.httpBody = try JSONEncoder().encode(body)
            let (data, _) = try await urlSession.data(for: request)
            let payload = try JSONDecoder().decode(ChatResponsePayload.self, from: data)
            let agentReply = payload.reply
            await MainActor.run {
                stopLoadingCycle()
                reply = agentReply
                loading = false
                showReply = true
                var updated = history
                updated.append(ChatMessage(role: "user", content: text))
                updated.append(ChatMessage(role: "assistant", content: agentReply))
                let trimmed = updated.count > 8 ? Array(updated.suffix(8)) : updated
                if let data = try? JSONEncoder().encode(trimmed),
                   let str = String(data: data, encoding: .utf8) {
                    historyJSON = str
                }
                WKInterfaceDevice.current().play(.success)
                speak(agentReply)
            }
        } catch {
            await MainActor.run {
                stopLoadingCycle()
                reply = "Error: \(error.localizedDescription)"
                loading = false
                showReply = true
                WKInterfaceDevice.current().play(.failure)
                speak("Ocurrió un error")
            }
        }
    }

    func speak(_ text: String) {
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
