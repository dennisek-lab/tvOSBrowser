#import <Foundation/Foundation.h>

#import "BrowserSubtitlePipeline.h"

NS_ASSUME_NONNULL_BEGIN

/// Klassenmethoden der Swift-Klasse `BrowserAppleSpeechRecognizer` (BrowserAppleSpeechRecognizer.swift, ohne
/// Bridging-Header, geholt per NSClassFromString).
@protocol BrowserAppleSpeechRecognizerClass <NSObject>
@property (class, nonatomic, readonly) BOOL isFrameworkAvailable;
+ (void)prepareLanguage:(NSString *)language
               progress:(nullable void (^)(NSString *message))progress
             completion:(void (^)(NSString * _Nullable locale, NSString *message))completion;
+ (void)transcribeSamples:(NSData *)samples
                startTime:(double)startTime
                   locale:(NSString *)locale
            maxCharacters:(NSInteger)maxCharacters
           wholeSentences:(BOOL)wholeSentences
               completion:(void (^)(NSArray<NSDictionary<NSString *, id> *> * _Nullable pieces, NSString * _Nullable failure))completion;
+ (void)runProbeWithLog:(void (^)(NSString *line))log completion:(void (^)(void))completion;
@end

/// Apples Spracherkennung (SpeechAnalyzer + SpeechTranscriber, ab tvOS 26) als Erkennung der automatischen
/// Untertitel, statt whisper. Gleiche Schnittstelle wie der whisper-Block der Pipeline (Abschnitt → Cues), die Pipeline
/// bleibt unverändert. docs/ERWEITERUNGEN.md 10.10.
///
/// Auswahl: `defaults write io.github.tvosbrowser.app SubtitlesRecognizer apple` (Standard `whisper`), Selbsttest
/// `pref:SubtitlesRecognizer=apple`. whisper bleibt geladen, aber nur als Spracherkennung („auto“: welche Sprache
/// spricht das Video?) und als Rückfall: SpeechTranscriber fehlt, Sprache nicht unterstützt, Sprachpaket fehlt oder
/// wird noch geladen, Fehler beim Erkennen. Log `[AppleSpeech] … Rückfall whisper`.
///
/// Sprache je Abschnitt: festgelegte Sprache von whisper (`spokenLanguageProvider`, Engine-`lockedLanguage`), vorher
/// die Sprache, die whisper für den Abschnitt erkannt hat (whisper rechnet den Abschnitt dafür zuerst). Ist die
/// Untertitelsprache fest und eine andere, bekommen die Cues `translationTarget`, Apple übersetzt danach wie bisher
/// (BrowserSubtitleTranslator in der Pipeline); dann bleiben Sätze ganz (bis 150 Zeichen).
@interface BrowserAppleSpeechTranscriber : NSObject

/// Einstellung `SubtitlesRecognizer` = „apple“.
+ (BOOL)isRequested;
/// Angefordert und SpeechTranscriber.isAvailable (synchron). Loggt beim ersten Mal den Rückfall, wenn nicht.
+ (BOOL)isUsable;
/// Sprache, mit der die whisper-Engine angelegt werden soll: bei Apple „auto“ (whisper erkennt nur die Sprache und
/// ist Rückfall), sonst unverändert `language`.
+ (NSString *)whisperLanguageForSubtitleLanguage:(NSString *)language;
/// nil, wenn nicht angefordert oder nicht verfügbar.
+ (nullable instancetype)transcriberForSubtitleLanguage:(NSString *)language;

- (instancetype)initWithSubtitleLanguage:(NSString *)language NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Eingestellte Untertitelsprache („auto“, „de“, „en“ …).
@property (nonatomic, copy, readonly) NSString *subtitleLanguage;
/// Von whisper festgelegte gesprochene Sprache (nil = noch offen). Wird je Abschnitt gefragt, beliebiger Thread.
@property (atomic, copy, nullable) NSString * _Nullable (^spokenLanguageProvider)(void);

/// Wie BrowserSubtitleTranscriber; `whisper` ist der bisherige Block (Sprache bestimmen, Rückfall).
- (void)transcribeSamples:(NSData *)samples
                startTime:(NSTimeInterval)startTime
                  whisper:(BrowserSubtitleTranscriber)whisper
               completion:(void (^)(NSArray<BrowserSubtitleCue *> * _Nullable cues))completion;

/// Kennzahlen: „Apple-Spracherkennung: N Abschnitte, Ø … s, max … s, RTF …, N Rückfälle whisper“.
- (NSString *)summary;

/// Selbsttest `speechprobe`: Verfügbarkeit, Sprachen, Pakete (lädt en bei Bedarf), 5 s Testton erkennen.
+ (void)runProbeWithCompletion:(nullable void (^)(void))completion;

@end

NS_ASSUME_NONNULL_END
