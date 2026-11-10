//
//  BrowserAppleSpeechRecognizer.swift
//  Browser
//
//  Apples Spracherkennung (Speech-Framework, SpeechAnalyzer + SpeechTranscriber, ab tvOS 26) als Alternative zu
//  whisper.cpp für die automatischen Untertitel (docs/ERWEITERUNGEN.md 10.10). Wie BrowserSpeechProbe.swift ohne
//  Bridging-Header: Swift sieht nur Foundation/AVFAudio/Speech, die Obj-C-Seite (BrowserAppleSpeechTranscriber.m)
//  holt die Klasse per NSClassFromString(@"BrowserAppleSpeechRecognizer") und ruft die Klassenmethoden über das
//  Protokoll BrowserAppleSpeechRecognizerClass (BrowserAppleSpeechTranscriber.h). Ergebnisse als Wörterbücher
//  {start, end, text} in Medienzeit; daraus baut die Obj-C-Seite BrowserSubtitleCue.
//
//  Ablauf je Abschnitt (16 kHz mono float): eigener SpeechAnalyzer mit einem SpeechTranscriber (nur fertige
//  Ergebnisse, keine volatilen, Attribut audioTimeRange je Textstück), Ton in Apples Format umrechnen, auswerten,
//  abschließen. Das Modell bleibt per modelRetention .processLifetime geladen. Aus den Textstücken mit Zeiten
//  entstehen Untertitel: Sätze, lange Sätze an Kommas bzw. Wortgrenzen geteilt (≤ maxCharacters, ≤ 7 s), kurze
//  Stücke mit dem nächsten zusammengelegt. Mit wholeSentences (Apple übersetzt danach) bleiben Sätze ganz.
//  Logpräfix `[AppleSpeech]`.
//

import AVFAudio
import CoreMedia
import Foundation
#if canImport(Speech)
import Speech
#endif

@objc(BrowserAppleSpeechRecognizer)
final class BrowserAppleSpeechRecognizer: NSObject {

    private static let logPrefix = "[AppleSpeech]"
    private static let sampleRate = 16000.0

    /// Bevorzugte Region je Sprache (whisper-Codes), sonst `supportedLocale(equivalentTo:)` bzw. erste passende.
    private static let preferredRegions: [String: String] = [
        "en": "en-US", "de": "de-DE", "fr": "fr-FR", "es": "es-ES", "it": "it-IT", "nl": "nl-NL",
        "pl": "pl-PL", "tr": "tr-TR", "pt": "pt-BR", "ru": "ru-RU", "ja": "ja-JP", "zh": "zh-CN", "ko": "ko-KR",
    ]

    // MARK: Verfügbarkeit

    /// YES ab tvOS 26, wenn das Gerät SpeechTranscriber kann (Simulator: bisher NO).
    @objc static var isFrameworkAvailable: Bool {
        #if canImport(Speech)
        if #available(tvOS 26.0, iOS 26.0, macOS 26.0, *) {
            return SpeechTranscriber.isAvailable
        }
        #endif
        return false
    }

    /// Sprache vorbereiten: unterstützte Locale suchen, Sprachpaket prüfen und bei Bedarf laden (AssetInventory).
    /// `completion` genau einmal, beliebige Queue: Locale-Kennung (z. B. „en_US“) oder nil mit Grund. Lädt das Paket,
    /// kommt `completion` erst nach dem Laden; `progress` meldet zwischendurch (Text, beliebige Queue).
    @objc(prepareLanguage:progress:completion:)
    static func prepare(language: String,
                        progress: ((String) -> Void)?,
                        completion: @escaping (String?, String) -> Void) {
        #if canImport(Speech)
        if #available(tvOS 26.0, iOS 26.0, macOS 26.0, *) {
            Task.detached(priority: .userInitiated) {
                let result = await prepareAsync(language: language, progress: progress)
                completion(result.0, result.1)
            }
            return
        }
        #endif
        completion(nil, "SpeechTranscriber erst ab tvOS 26")
    }

    #if canImport(Speech)
    @available(tvOS 26.0, iOS 26.0, macOS 26.0, *)
    private static func supportedLocale(for language: String) async -> Locale? {
        guard SpeechTranscriber.isAvailable else {
            return nil
        }
        let supported = await SpeechTranscriber.supportedLocales
        if let preferred = preferredRegions[language],
           let match = supported.first(where: { $0.identifier(.bcp47) == preferred }) {
            return match
        }
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) {
            return match
        }
        return supported.first(where: { $0.language.languageCode?.identifier == language })
    }

    @available(tvOS 26.0, iOS 26.0, macOS 26.0, *)
    private static func prepareAsync(language: String, progress: ((String) -> Void)?) async -> (String?, String) {
        guard SpeechTranscriber.isAvailable else {
            return (nil, "SpeechTranscriber.isAvailable = false")
        }
        guard let locale = await supportedLocale(for: language) else {
            return (nil, "Sprache \(language) nicht unterstützt")
        }
        let module = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                       attributeOptions: [.audioTimeRange])
        let status = await AssetInventory.status(forModules: [module])
        if status == .installed {
            return (locale.identifier, "\(language) → \(locale.identifier), Paket installiert")
        }
        if status == .unsupported {
            return (nil, "\(language) → \(locale.identifier), Paket nicht angeboten (unsupported)")
        }
        let begin = CFAbsoluteTimeGetCurrent()
        // Sprachen für die App reservieren (Simulator: höchstens 1). Ist die Grenze erreicht, die älteste andere
        // Reservierung freigeben (deren Paket darf das System dann wieder löschen) und noch einmal versuchen.
        do {
            let reserved = try await AssetInventory.reserve(locale: locale)
            NSLog("%@ %@ reserviert: %@ (höchstens %ld)", logPrefix, locale.identifier, reserved ? "ja" : "schon",
                  AssetInventory.maximumReservedLocales)
        } catch {
            let others = await AssetInventory.reservedLocales.filter { $0.identifier != locale.identifier }
            NSLog("%@ %@ reservieren fehlgeschlagen: %@ (reserviert: %@)", logPrefix, locale.identifier,
                  error.localizedDescription, others.map(\.identifier).joined(separator: ","))
            if let oldest = others.first {
                let released = await AssetInventory.release(reservedLocale: oldest)
                let again = (try? await AssetInventory.reserve(locale: locale)) ?? false
                NSLog("%@ %@ freigegeben: %@, %@ reserviert: %@", logPrefix, oldest.identifier, released ? "ja" : "nein",
                      locale.identifier, again ? "ja" : "nein")
            }
        }
        do {
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else {
                // nil = nichts zu laden (inzwischen installiert)
                return (locale.identifier, "\(language) → \(locale.identifier), Paket schon vorhanden")
            }
            progress?("\(language) → \(locale.identifier): Sprachpaket wird geladen (Status \(status))")
            let observation = request.progress.observe(\.fractionCompleted, options: [.new]) { item, _ in
                let percent = Int(item.fractionCompleted * 100)
                if percent % 25 == 0 {
                    progress?("\(locale.identifier): \(percent) %")
                }
            }
            try await request.downloadAndInstall()
            observation.invalidate()
            let after = await AssetInventory.status(forModules: [module])
            let seconds = CFAbsoluteTimeGetCurrent() - begin
            if after == .installed {
                return (locale.identifier, String(format: "%@ → %@, Paket geladen in %.1f s", language, locale.identifier, seconds))
            }
            return (nil, String(format: "%@ → %@, nach dem Laden Status %@ (%.1f s)", language, locale.identifier,
                                String(describing: after), seconds))
        } catch {
            return (nil, "\(language) → \(locale.identifier), Laden fehlgeschlagen: \(error.localizedDescription)")
        }
    }
    #endif

    // MARK: Erkennen

    /// Ein Abschnitt (16 kHz mono float32, `samples`) → Untertitel [{start, end, text}] in Medienzeit
    /// (`startTime` + audioTimeRange). `completion` genau einmal, beliebige Queue; nil mit Grund bei Fehler.
    @objc(transcribeSamples:startTime:locale:maxCharacters:wholeSentences:completion:)
    static func transcribe(samples: Data, startTime: Double, locale: String, maxCharacters: Int, wholeSentences: Bool,
                           completion: @escaping ([[String: Any]]?, String?) -> Void) {
        #if canImport(Speech)
        if #available(tvOS 26.0, iOS 26.0, macOS 26.0, *) {
            Task.detached(priority: .userInitiated) {
                do {
                    let words = try await recognizeWords(samples: samples, locale: Locale(identifier: locale))
                    let pieces = cues(from: words, maxCharacters: maxCharacters, wholeSentences: wholeSentences)
                    completion(pieces.map { ["start": startTime + $0.start, "end": startTime + $0.end, "text": $0.text] }, nil)
                } catch {
                    completion(nil, error.localizedDescription)
                }
            }
            return
        }
        #endif
        completion(nil, "SpeechTranscriber erst ab tvOS 26")
    }

    /// Ein Textstück mit Zeit (Sekunden ab Abschnittsbeginn).
    struct Word {
        var text: String
        var start: Double
        var end: Double
    }

    struct Piece {
        var text: String
        var start: Double
        var end: Double
    }

    #if canImport(Speech)
    private static let converterLock = NSLock()
    nonisolated(unsafe) private static var cachedFormat: AVAudioFormat?

    @available(tvOS 26.0, iOS 26.0, macOS 26.0, *)
    private static func analyzerFormat(for module: SpeechTranscriber) async -> AVAudioFormat? {
        if let cached = converterLock.withLock({ cachedFormat }) {
            return cached
        }
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
        converterLock.withLock { cachedFormat = format }
        return format
    }

    /// 16 kHz mono float32 → Format des Analyzers (meist 16 kHz Int16 mono).
    static func convert(samples: Data, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let count = samples.count / MemoryLayout<Float>.size
        guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(max(1, count))) else {
            throw NSError(domain: "BrowserAppleSpeech", code: 1, userInfo: [NSLocalizedDescriptionKey: "Puffer anlegen"])
        }
        input.frameLength = AVAudioFrameCount(count)
        samples.withUnsafeBytes { raw in
            if let base = raw.bindMemory(to: Float.self).baseAddress, let channel = input.floatChannelData?[0] {
                channel.update(from: base, count: count)
            }
        }
        if format == source {
            return input
        }
        guard let converter = AVAudioConverter(from: source, to: format) else {
            throw NSError(domain: "BrowserAppleSpeech", code: 2, userInfo: [NSLocalizedDescriptionKey: "kein Umrechner nach \(format)"])
        }
        let capacity = AVAudioFrameCount(ceil(Double(count) * format.sampleRate / sampleRate)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw NSError(domain: "BrowserAppleSpeech", code: 3, userInfo: [NSLocalizedDescriptionKey: "Ausgabepuffer"])
        }
        var delivered = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if delivered {
                outStatus.pointee = .endOfStream
                return nil
            }
            delivered = true
            outStatus.pointee = .haveData
            return input
        }
        if status == .error {
            throw conversionError ?? NSError(domain: "BrowserAppleSpeech", code: 4, userInfo: [NSLocalizedDescriptionKey: "Umrechnen"])
        }
        return output
    }

    @available(tvOS 26.0, iOS 26.0, macOS 26.0, *)
    static func recognizeWords(samples: Data, locale: Locale) async throws -> [Word] {
        let begin = CFAbsoluteTimeGetCurrent()
        let module = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                       attributeOptions: [.audioTimeRange])
        guard let format = await analyzerFormat(for: module) else {
            throw NSError(domain: "BrowserAppleSpeech", code: 5, userInfo: [NSLocalizedDescriptionKey: "kein Audioformat für den Analyzer"])
        }
        let buffer = try convert(samples: samples, to: format)
        let analyzer = SpeechAnalyzer(modules: [module],
                                      options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime))
        // Ergebnisse parallel einsammeln (nur fertige; ohne .volatileResults kommen keine vorläufigen).
        let collector = Task { () -> [SpeechTranscriber.Result] in
            var results: [SpeechTranscriber.Result] = []
            for try await result in module.results where result.isFinal {
                results.append(result)
            }
            return results
        }
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        continuation.yield(AnalyzerInput(buffer: buffer))
        continuation.finish()
        do {
            if let last = try await analyzer.analyzeSequence(stream) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            throw error
        }
        let results = try await collector.value
        var words: [Word] = []
        for result in results {
            let text = result.text
            for run in text.runs {
                let piece = String(text[run.range].characters)
                if piece.isEmpty {
                    continue
                }
                if let range = run.audioTimeRange, range.duration.isNumeric, range.start.isNumeric {
                    let start = range.start.seconds
                    words.append(Word(text: piece, start: start, end: start + range.duration.seconds))
                } else if !words.isEmpty {
                    // ohne Zeit (z. B. Satzzeichen): ans vorige Stück hängen
                    words[words.count - 1].text += piece
                } else {
                    let start = result.range.start.seconds
                    words.append(Word(text: piece, start: start, end: start))
                }
            }
        }
        let seconds = Double(samples.count / MemoryLayout<Float>.size) / sampleRate
        let compute = CFAbsoluteTimeGetCurrent() - begin
        NSLog("%@ Abschnitt %.1f s (%@): %ld Ergebnisse, %ld Wörter in %.2f s (RTF %.2f)", logPrefix, seconds,
              locale.identifier, results.count, words.count, compute, seconds > 0 ? compute / seconds : 0)
        return words
    }
    #endif

    // MARK: Untertitel aus Wörtern

    private static func endsSentence(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else {
            return false
        }
        return ".?!…。？！".contains(last) || (trimmed.hasSuffix(".\"") || trimmed.hasSuffix("?\"") || trimmed.hasSuffix("!\""))
    }

    private static func endsClause(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else {
            return false
        }
        return ",;:–—".contains(last)
    }

    private static func joined(_ words: ArraySlice<Word>) -> String {
        var text = ""
        for word in words {
            let piece = word.text
            if text.isEmpty || piece.hasPrefix(" ") || piece.first.map({ ",.;:!?…)".contains($0) }) == true {
                text += piece
            } else if text.hasSuffix(" ") {
                text += piece
            } else {
                text += " " + piece
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func characterCount(_ words: ArraySlice<Word>) -> Int {
        joined(words).count
    }

    /// Satz zu lang (Zeichen oder Dauer): an einem Komma nahe der Mitte teilen, sonst an der Wortgrenze nahe der Mitte,
    /// mit dem linken Teil ≤ maxCharacters. Rekursiv.
    private static func splitLong(_ words: ArraySlice<Word>, maxCharacters: Int, maxDuration: Double) -> [ArraySlice<Word>] {
        guard words.count > 1 else {
            return [words]
        }
        let duration = (words.last?.end ?? 0) - (words.first?.start ?? 0)
        if characterCount(words) <= maxCharacters && duration <= maxDuration {
            return [words]
        }
        let total = characterCount(words)
        var best: Int?
        var bestScore = Double.infinity
        for index in words.indices.dropLast() {
            let left = words[words.startIndex...index]
            let leftCount = characterCount(left)
            if leftCount > maxCharacters {
                break
            }
            let balance = abs(Double(leftCount) - Double(total) / 2.0)
            // Kommas/Satzzeichen bevorzugen: wie 20 Zeichen näher an der Mitte
            let score = balance - (endsSentence(words[index].text) ? 30 : (endsClause(words[index].text) ? 20 : 0))
            if score < bestScore {
                bestScore = score
                best = index
            }
        }
        guard let cut = best else {
            return [words]
        }
        let left = words[words.startIndex...cut]
        let right = words[(cut + 1)..<words.endIndex]
        return splitLong(left, maxCharacters: maxCharacters, maxDuration: maxDuration)
            + splitLong(right, maxCharacters: maxCharacters, maxDuration: maxDuration)
    }

    static func cues(from words: [Word], maxCharacters: Int, wholeSentences: Bool) -> [Piece] {
        guard !words.isEmpty else {
            return []
        }
        // 1. Sätze: nach Satzzeichen oder einer Sprechpause ≥ 1,2 s
        var sentences: [ArraySlice<Word>] = []
        var begin = 0
        for index in words.indices {
            let last = index == words.count - 1
            let pause = !last && words[index + 1].start - words[index].end >= 1.2
            if last || endsSentence(words[index].text) || pause {
                sentences.append(words[begin...index])
                begin = index + 1
            }
        }
        // 2. Lange Sätze teilen (bei folgender Übersetzung nur über das großzügige Zeichenlimit, nicht nach Dauer)
        let limit = wholeSentences ? max(maxCharacters, 150) : maxCharacters
        let maxDuration = wholeSentences ? 30.0 : 7.0
        var parts: [ArraySlice<Word>] = []
        for sentence in sentences {
            parts.append(contentsOf: splitLong(sentence, maxCharacters: limit, maxDuration: maxDuration))
        }
        // 3. Kurze Stücke (< 2 s oder < 28 Zeichen) mit dem nächsten zusammenlegen, solange beides ≤ maxCharacters
        //    und ≤ 8 s und die Lücke < 1 s ist (wie die whisper-Engine).
        var pieces: [Piece] = parts.compactMap { part in
            guard let first = part.first, let last = part.last else {
                return nil
            }
            let text = joined(part)
            return text.isEmpty ? nil : Piece(text: text, start: first.start, end: max(last.end, first.start + 0.2))
        }
        var index = 0
        while index + 1 < pieces.count {
            let current = pieces[index]
            let next = pieces[index + 1]
            let short = current.end - current.start < 2.0 || current.text.count < 28
            let combined = current.text + " " + next.text
            if short && combined.count <= maxCharacters && next.end - current.start <= 8.0 && next.start - current.end < 1.0 {
                pieces[index] = Piece(text: combined, start: current.start, end: next.end)
                pieces.remove(at: index + 1)
            } else {
                index += 1
            }
        }
        return pieces
    }

    // MARK: Selbsttest `speechprobe`

    /// Loggt Verfügbarkeit, Sprachen, Paketstatus (en, de; lädt das englische Paket bei Bedarf), erkennt dann 5 s Testton:
    /// gesprochenen Satz von AVSpeechSynthesizer (en-US), sonst einen Sinuston (dann erwartet: kein Text).
    @objc(runProbeWithLog:completion:)
    static func runProbe(log: @escaping (String) -> Void, completion: @escaping () -> Void) {
        #if canImport(Speech)
        if #available(tvOS 26.0, iOS 26.0, macOS 26.0, *) {
            Task.detached(priority: .userInitiated) {
                await probeAsync(log: log)
                completion()
            }
            return
        }
        #endif
        log("SpeechTranscriber erst ab tvOS 26 (läuft: \(ProcessInfo.processInfo.operatingSystemVersionString))")
        completion()
    }

    #if canImport(Speech)
    @available(tvOS 26.0, iOS 26.0, macOS 26.0, *)
    private static func probeAsync(log: @escaping (String) -> Void) async {
        log("isAvailable=\(SpeechTranscriber.isAvailable) System \(ProcessInfo.processInfo.operatingSystemVersionString)")
        let supported = await SpeechTranscriber.supportedLocales
        log("unterstützt (\(supported.count)): \(supported.map(\.identifier).sorted().joined(separator: ","))")
        let installed = await SpeechTranscriber.installedLocales
        log("installiert (\(installed.count)): \(installed.map(\.identifier).sorted().joined(separator: ","))")
        let reserved = await AssetInventory.reservedLocales
        log("reserviert (\(reserved.count) von höchstens \(AssetInventory.maximumReservedLocales)): \(reserved.map(\.identifier).joined(separator: ","))")
        var english: String?
        for language in ["en", "de"] {
            if let locale = await supportedLocale(for: language) {
                let module = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
                let status = await AssetInventory.status(forModules: [module])
                log("\(language) → \(locale.identifier): Paket \(status)")
            } else {
                log("\(language): nicht unterstützt")
            }
        }
        // Nur Englisch laden (für den Testton); andere Sprachen lädt die Erkennung bei Bedarf selbst. Der Simulator
        // erlaubt nur eine reservierte Sprache, sonst würde de die Reservierung von en verdrängen.
        let (identifier, message) = await prepareAsync(language: "en", progress: { log($0) })
        log("vorbereitet en: \(message)")
        english = identifier
        guard SpeechTranscriber.isAvailable else {
            log("Testton übersprungen: SpeechTranscriber nicht verfügbar → Untertitel laufen mit whisper (Rückfall)")
            return
        }
        guard let locale = english else {
            log("Testton übersprungen: kein englisches Sprachpaket")
            return
        }
        let sentence = "The quick brown fox jumps over the lazy dog. Subtitles are working now."
        var samples = await synthesizedSpeech(sentence)
        let kind: String
        if samples.count >= 16000 {
            kind = "Sprachausgabe „\(sentence)“"
        } else {
            kind = "Sinuston 440 Hz (keine Sprachausgabe verfügbar)"
            samples = (0..<Int(5 * sampleRate)).map { Float(0.2 * sin(2 * Double.pi * 440 * Double($0) / sampleRate)) }
        }
        if samples.count > Int(5 * sampleRate) {
            samples = Array(samples.prefix(Int(5 * sampleRate)))
        } else if samples.count < Int(5 * sampleRate) {
            samples += [Float](repeating: 0, count: Int(5 * sampleRate) - samples.count)
        }
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let begin = CFAbsoluteTimeGetCurrent()
        do {
            let words = try await recognizeWords(samples: data, locale: Locale(identifier: locale))
            let pieces = cues(from: words, maxCharacters: 84, wholeSentences: false)
            log(String(format: "Testton 5 s (%@): %ld Wörter in %.2f s", kind, words.count, CFAbsoluteTimeGetCurrent() - begin))
            for word in words {
                log(String(format: "  Wort %.2f–%.2f s: %@", word.start, word.end, word.text))
            }
            for piece in pieces {
                log(String(format: "Untertitel %.2f–%.2f s: %@", piece.start, piece.end, piece.text))
            }
        } catch {
            log("Testton: Fehler \(error.localizedDescription)")
        }
    }

    /// Satz mit AVSpeechSynthesizer in 16 kHz mono float sprechen lassen (leer, wenn keine Stimme da ist).
    private static func synthesizedSpeech(_ text: String) async -> [Float] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[Float], Never>) in
            DispatchQueue.main.async {
                let synthesizer = AVSpeechSynthesizer()
                let utterance = AVSpeechUtterance(string: text)
                utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
                var collected: [Float] = []
                var finished = false
                var converter: AVAudioConverter?
                let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
                let finish = {
                    if !finished {
                        finished = true
                        _ = synthesizer  // bis zum Ende festhalten
                        continuation.resume(returning: collected)
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { finish() }
                synthesizer.write(utterance) { buffer in
                    DispatchQueue.main.async {
                        guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                            finish()  // leerer Puffer = Ende
                            return
                        }
                        if converter == nil {
                            converter = AVAudioConverter(from: pcm.format, to: target)
                        }
                        guard let converter,
                              let out = AVAudioPCMBuffer(pcmFormat: target,
                                                         frameCapacity: AVAudioFrameCount(Double(pcm.frameLength) * sampleRate / pcm.format.sampleRate) + 512) else {
                            return
                        }
                        var given = false
                        var error: NSError?
                        _ = converter.convert(to: out, error: &error) { _, status in
                            if given {
                                status.pointee = .noDataNow
                                return nil
                            }
                            given = true
                            status.pointee = .haveData
                            return pcm
                        }
                        if let channel = out.floatChannelData?[0] {
                            collected.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
                        }
                    }
                }
            }
        }
    }
    #endif
}
