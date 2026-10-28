import AVFoundation
import Combine
import Foundation
import Security

/// Personal prototype: the owner enters their own ElevenLabs key on their phone.
/// Never bundle a developer key in this app. A distributed production app needs
/// an authenticated backend instead of distributing a shared service credential.
/// Only the fixed phrases below are sent to ElevenLabs; no sensor readings,
/// location, identifiers from the cane, or microphone recordings are uploaded.
/// API: https://elevenlabs.io/docs/api-reference/text-to-speech/stream
@MainActor
final class ElevenLabsVoice: ObservableObject {
    @Published private(set) var isConfigured = false
    @Published private(set) var status = "Add your ElevenLabs key and voice ID when ready."
    @Published private(set) var isBusy = false
    @Published private(set) var isReady = false

    private enum Phrase: String, CaseIterable {
        case obstacle = "Obstacle ahead. <break time=\"0.5s\" /> Please slow down."
        case unavailable = "Distance reading is unavailable. <break time=\"0.45s\" /> Please continue using your cane with care."
        case test = "PathAhead voice is ready. <break time=\"0.45s\" /> This is a supervised prototype."
        case route = "A familiar route obstacle may be ahead. <break time=\"0.55s\" /> Please pause and use your usual mobility technique."
        case gait = "Your cane-tap rhythm differs from your learned baseline. <break time=\"0.55s\" /> Pause if needed."
    }

    private struct Credentials: Codable {
        let apiKey: String
        let voiceID: String
    }

    private var credentials: Credentials?
    private var cache: [Phrase: Data] = [:]
    private var preparationTask: Task<Void, Error>?
    private var playbackTask: Task<Void, Never>?
    private var player: AVAudioPlayer?
    private var generation: UInt64 = 0
    private var lastPlayed: [Phrase: TimeInterval] = [:]
    private let cooldown: TimeInterval = 5
    // These clips are generated ahead of time, so favor natural, steady
    // delivery over Flash's low-latency optimization.
    private let modelID = "eleven_multilingual_v2"

    // No URL cache, cookies, shared credential storage, or HTTP logs.
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    init() {
        do {
            if let data = try VoiceKeychain.load() {
                let saved = try JSONDecoder().decode(Credentials.self, from: data)
                credentials = try Self.validated(apiKey: saved.apiKey, voiceID: saved.voiceID)
                isConfigured = true
                status = "Credentials saved. Prepare voice to make the alert clips."
            }
        } catch {
            // Never display a raw server response, credential, or decoded data.
            status = "Saved voice credentials could not be read. Unlock your phone and save them again."
        }
    }

    /// Saves credentials only. It does not contact ElevenLabs or spend credits.
    func configure(apiKey: String, voiceID: String) throws {
        let validated = try Self.validated(apiKey: apiKey, voiceID: voiceID)
        let encoded = try JSONEncoder().encode(validated)
        // Commit the combined record before replacing the in-memory state.
        try VoiceKeychain.save(encoded)
        stop()
        credentials = validated
        cache.removeAll()
        clearAudioFiles()
        lastPlayed.removeAll()
        isConfigured = true
        isReady = false
        status = "Saved securely on this device. Tap Prepare voice next."
    }

    func forgetCredentials() {
        stop()
        credentials = nil
        cache.removeAll()
        clearAudioFiles()
        lastPlayed.removeAll()
        isConfigured = false
        isReady = false
        do {
            try VoiceKeychain.delete()
            status = "Credentials and cached audio removed."
        } catch {
            status = "Audio cleared, but saved credentials could not be removed. Unlock the phone and tap Forget again."
        }
    }

    /// User-triggered preparation. Reuses saved clips, downloading only missing
    /// phrases. Successful audio survives app restarts and is excluded from backup.
    /// Replaying an alert never makes an API request or accumulates a speech queue.
    @discardableResult
    func prepare() async -> Bool {
        guard let credentials else {
            status = "Add your ElevenLabs API key and voice ID first."
            return false
        }
        if isReady { return true }
        guard preparationTask == nil else { return false }
        stopPlayback()
        let requestGeneration = generation
        isBusy = true
        status = "Preparing ElevenLabs voice…"

        let task = Task<Void, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            for phrase in Phrase.allCases {
                try Task.checkCancellation()
                guard self.generation == requestGeneration else { throw CancellationError() }
                if self.cache[phrase] != nil { continue }
                if let saved = self.loadClip(for: phrase), self.isPlayable(saved) {
                    self.cache[phrase] = saved
                    continue
                }
                let data = try await self.fetchAudio(phrase, credentials: credentials)
                try Task.checkCancellation()
                guard self.generation == requestGeneration else { throw CancellationError() }
                // Verify decoding now, not for the first time during an alert.
                guard self.isPlayable(data) else { throw VoiceError.invalidAudio }
                self.cache[phrase] = data
                self.saveClip(data, for: phrase)
            }
        }
        preparationTask = task

        do {
            try await task.value
            guard generation == requestGeneration, !Task.isCancelled else { return false }
            preparationTask = nil
            isBusy = false
            isReady = Phrase.allCases.allSatisfy { cache[$0] != nil }
            status = "ElevenLabs ready · clips saved on this iPhone."
            return isReady
        } catch {
            guard generation == requestGeneration else { return false }
            preparationTask = nil
            isBusy = false
            isReady = false
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                status = "Voice preparation stopped. Tap Prepare voice to retry."
            } else {
                status = Self.message(for: error)
            }
            return false
        }
    }

    /// Explicit user action: prepares missing clips if necessary, then plays a
    /// test. A stop/disconnect during preparation prevents delayed test playback.
    func testVoice() async {
        let requestGeneration = generation
        let ready = isReady ? true : await prepare()
        guard ready, generation == requestGeneration, !Task.isCancelled else { return }
        playCached(.test, bypassCooldown: true)
    }

    func speakObstacle() {
        playCached(.obstacle)
    }

    func speakUnavailable() {
        playCached(.unavailable)
    }

    func speakRouteCue() {
        playCached(.route)
    }

    func speakGaitCue() {
        playCached(.gait)
    }

    /// Call when alert clears, hardware disconnects, or the app leaves the
    /// foreground. Invalidates both in-flight downloads and pending playback.
    func stop() {
        generation &+= 1
        preparationTask?.cancel()
        preparationTask = nil
        stopPlayback()
        isBusy = false
        status = isReady
            ? "ElevenLabs ready · clips saved on this iPhone."
            : (isConfigured ? "Voice stopped. Tap Prepare voice when ready." : "Add your ElevenLabs key and voice ID when ready.")
    }

    private func playCached(_ phrase: Phrase, bypassCooldown: Bool = false) {
        guard isReady, let data = cache[phrase] else {
            if preparationTask == nil {
                status = isConfigured ? "Prepare ElevenLabs voice before enabling alerts." : "Voice needs your ElevenLabs credentials."
            }
            return
        }
        // Do not interrupt an existing sentence or enqueue a stale one.
        guard preparationTask == nil, player?.isPlaying != true else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if !bypassCooldown, let previous = lastPlayed[phrase], now - previous < cooldown { return }

        stopPlayback()
        let playbackGeneration = generation
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try audioSession.setActive(true)
            let newPlayer = try AVAudioPlayer(data: data)
            newPlayer.volume = 1
            newPlayer.prepareToPlay()
            guard newPlayer.play() else { throw VoiceError.playback }
            player = newPlayer
            lastPlayed[phrase] = now
            isBusy = true
            status = "Speaking with ElevenLabs…"

            // Poll only while this short clip plays. No delegate crossing actor
            // boundaries, no speech queue, and cancellation on every stop.
            playbackTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 100_000_000) }
                    catch { return }
                    guard let self, self.generation == playbackGeneration else { return }
                    if self.player?.isPlaying != true {
                        self.player = nil
                        self.playbackTask = nil
                        self.isBusy = false
                        self.status = "ElevenLabs ready · clips saved on this iPhone."
                        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                        return
                    }
                }
            }
        } catch {
            stopPlayback()
            isBusy = false
            status = "Audio could not play. Check the phone's volume and selected audio output, then test again."
        }
    }

    private func stopPlayback() {
        playbackTask?.cancel()
        playbackTask = nil
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func fetchAudio(_ phrase: Phrase, credentials: Credentials) async throws -> Data {
        // voiceID has already been restricted to ASCII letters, digits, _ and -.
        let address = "https://api.elevenlabs.io/v1/text-to-speech/\(credentials.voiceID)/stream?output_format=mp3_44100_128"
        guard let url = URL(string: address) else { throw VoiceError.invalidVoiceID }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue(credentials.apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(SpeechRequest(
            text: phrase.rawValue,
            model_id: modelID,
            voice_settings: VoiceSettings(
                stability: 0.65,
                similarity_boost: 0.78,
                style: 0.0,
                use_speaker_boost: true,
                speed: 0.7
            )
        ))
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw VoiceError.invalidResponse }
        guard (200...299).contains(response.statusCode) else { throw VoiceError.http(response.statusCode) }
        let type = response.mimeType?.lowercased() ?? ""
        guard type.hasPrefix("audio/") || type == "application/octet-stream" else { throw VoiceError.invalidAudio }
        guard !data.isEmpty, data.count <= 2_000_000 else { throw VoiceError.invalidAudio }
        return data
    }

    private struct SpeechRequest: Encodable {
        let text: String
        let model_id: String
        let voice_settings: VoiceSettings
    }

    private struct VoiceSettings: Encodable {
        let stability: Double
        let similarity_boost: Double
        let style: Double
        let use_speaker_boost: Bool
        let speed: Double
    }

    private func isPlayable(_ data: Data) -> Bool {
        guard let check = try? AVAudioPlayer(data: data) else { return false }
        return check.duration > 0
    }

    private func audioDirectory() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = base.appendingPathComponent("PathAhead/ElevenLabs", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutable = directory
            try? mutable.setResourceValues(values)
            return directory
        } catch {
            return nil
        }
    }

    private func clipURL(for phrase: Phrase) -> URL? {
        guard let directory = audioDirectory() else { return nil }
        let filename: String
        switch phrase {
        // Bump this suffix whenever the model, wording, or voice profile
        // changes so the app regenerates instead of replaying stale clips.
        case .obstacle: filename = "obstacle-paced-v3.mp3"
        case .unavailable: filename = "unavailable-paced-v3.mp3"
        case .test: filename = "test-paced-v3.mp3"
        case .route: filename = "route-paced-v1.mp3"
        case .gait: filename = "gait-paced-v1.mp3"
        }
        return directory.appendingPathComponent(filename, isDirectory: false)
    }

    private func loadClip(for phrase: Phrase) -> Data? {
        guard let url = clipURL(for: phrase),
              let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let bytes = values.fileSize, bytes > 0, bytes <= 2_000_000 else { return nil }
        return try? Data(contentsOf: url, options: [.mappedIfSafe])
    }

    private func saveClip(_ data: Data, for phrase: Phrase) {
        guard let url = clipURL(for: phrase) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    private func clearAudioFiles() {
        guard let directory = audioDirectory() else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    private static func validated(apiKey: String, voiceID: String) throws -> Credentials {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let identifier = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw VoiceError.missingKey }
        guard key.utf8.count <= 1024, key.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }) else {
            throw VoiceError.invalidKey
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        guard !identifier.isEmpty, identifier.utf8.count <= 128,
              identifier.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw VoiceError.invalidVoiceID
        }
        return Credentials(apiKey: key, voiceID: identifier)
    }

    private static func message(for error: Error) -> String {
        if let known = error as? VoiceError { return known.localizedDescription }
        if let network = error as? URLError {
            switch network.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost:
                return "Cannot reach ElevenLabs. Check internet access and tap Prepare voice again."
            case .timedOut:
                return "ElevenLabs took too long to respond. Tap Prepare voice to retry."
            default:
                return "The secure connection to ElevenLabs failed. Check internet access and retry."
            }
        }
        return "Voice preparation failed. Check your ElevenLabs settings and retry."
    }

    private enum VoiceError: LocalizedError {
        case missingKey, invalidKey, invalidVoiceID, invalidResponse, invalidAudio, playback
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .missingKey: return "Enter your own ElevenLabs API key."
            case .invalidKey: return "The API key contains spaces or unsupported characters. Copy the key again."
            case .invalidVoiceID: return "Enter a voice ID, not a voice name or link (letters, numbers, - and _ only)."
            case .invalidResponse: return "ElevenLabs returned an unexpected response. Try again."
            case .invalidAudio: return "ElevenLabs did not return a playable audio clip. Check your voice and model access."
            case .playback: return "The audio could not start playing."
            case .http(let code):
                switch code {
                case 401: return "ElevenLabs rejected the key. Check it and save your settings again."
                case 403: return "ElevenLabs access was denied. Check the key's text-to-speech permission and your account access."
                case 404: return "The ElevenLabs voice was not found. Check the voice ID and your access to that voice."
                case 422: return "ElevenLabs could not use this voice or model. Check the voice ID and account access."
                case 429: return "ElevenLabs is rate-limiting requests or your usage allowance is exhausted. Check your account and retry later."
                case 500...599: return "ElevenLabs is temporarily unavailable. Try preparing voice again later."
                default: return "ElevenLabs returned HTTP \(code). Check your account settings and retry."
                }
            }
        }
    }
}

/// One atomic JSON record. Not synchronizable, not shared with another app,
/// and not included in a transferable device backup.
private enum VoiceKeychain {
    private static let service = "PathAhead.ElevenLabs"
    private static let account = "personal-voice-credentials"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    static func save(_ data: Data) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError(code: update) }
        var entry = query
        attributes.forEach { entry[$0.key] = $0.value }
        let result = SecItemAdd(entry as CFDictionary, nil)
        guard result == errSecSuccess else { throw KeychainError(code: result) }
    }

    static func load() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let code = SecItemCopyMatching(request as CFDictionary, &result)
        if code == errSecItemNotFound { return nil }
        guard code == errSecSuccess, let data = result as? Data else { throw KeychainError(code: code) }
        return data
    }

    static func delete() throws {
        let code = SecItemDelete(query as CFDictionary)
        guard code == errSecSuccess || code == errSecItemNotFound else { throw KeychainError(code: code) }
    }

    private struct KeychainError: LocalizedError {
        let code: OSStatus
        var errorDescription: String? {
            "Secure storage is unavailable (code \(code)). Unlock the device and try again."
        }
    }
}
