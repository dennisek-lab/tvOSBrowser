//
//  BrowserSpeechProbe.swift
//  Browser
//
//  Gerätetest für Apples SpeechTranscriber (Speech, tvOS 26+) als mögliche Alternative zu whisper.cpp.
//  Nur Prüfung, keine Erkennung: Verfügbarkeit, unterstützte/installierte Sprachen, Status der Sprachpakete.
//  Aufruf aus Obj-C ohne Bridging-Header per NSClassFromString(@"BrowserSpeechProbe") und
//  Selektor "runWithCompletion:" (Selbsttest-Schritt `speech`, docs/ERWEITERUNGEN.md 14.2).
//

import Foundation
#if canImport(Speech)
import Speech
#endif

@objc(BrowserSpeechProbe)
final class BrowserSpeechProbe: NSObject {
    @objc(runWithCompletion:)
    static func run(completion: @escaping (String) -> Void) {
        #if canImport(Speech)
        if #available(tvOS 26.0, iOS 26.0, macOS 26.0, *) {
            Task {
                var parts: [String] = []
                parts.append("isAvailable=\(SpeechTranscriber.isAvailable)")
                let supported = await SpeechTranscriber.supportedLocales
                parts.append("supported=\(supported.count)")
                let installed = await SpeechTranscriber.installedLocales
                parts.append("installed=[\(installed.map(\.identifier).sorted().joined(separator: ","))]")
                for identifier in ["en-US", "de-DE"] {
                    let locale = Locale(identifier: identifier)
                    guard let match = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
                        parts.append("\(identifier)=nicht unterstützt")
                        continue
                    }
                    let module = SpeechTranscriber(locale: match, preset: .transcription)
                    let status = await AssetInventory.status(forModules: [module])
                    parts.append("\(identifier)->\(match.identifier) Paket=\(status)")
                }
                let line = parts.joined(separator: " ")
                await MainActor.run { completion(line) }
            }
            return
        }
        completion("SpeechTranscriber erst ab tvOS 26 (läuft: \(ProcessInfo.processInfo.operatingSystemVersionString))")
        #else
        completion("Speech-Framework nicht vorhanden")
        #endif
    }
}
