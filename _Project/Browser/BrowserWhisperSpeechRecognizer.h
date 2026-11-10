#import <Foundation/Foundation.h>

#import "BrowserSpeechRecognizing.h"

NS_ASSUME_NONNULL_BEGIN

@class BrowserSubtitleCue;

/// whisper.cpp-Erkennung für die Web-Untertitel (Weg B). Dünner Adapter um `BrowserSubtitleEngine` (Weg A):
/// gleiche Modelle (`WhisperModels/`, Wahl nach Sprache), gleiche Parameter, Stille- und Rauschfilter.
///
/// Eigene serielle Queue für whisper (die Engine ist nicht threadsicher): `transcribeSamples:…` kopiert die
/// Werte und kehrt sofort zurück, `completion` kommt von dieser Queue, genau einmal. Das Modell wird beim
/// Anlegen im Hintergrund geladen; nach `idleUnloadDelay` ohne Abschnitt wieder freigegeben (Speicher, z. B.
/// während der native Player mit eigener Engine läuft) und beim nächsten Abschnitt neu geladen.
/// Logpräfix `[WebSubs][whisper]` (die Engine selbst loggt mit `[Subtitles]`).
@interface BrowserWhisperSpeechRecognizer : NSObject <BrowserSpeechRecognizing>

/// YES, wenn whisper eingebaut ist und ein Modell für die Sprache („en“ oder „auto“) im Paket liegt.
+ (BOOL)isAvailableForLanguage:(NSString *)language;
/// Deutscher Grund, warum es nicht geht (nil, wenn verfügbar).
+ (nullable NSString *)unavailableReasonForLanguage:(NSString *)language;

/// nil, wenn whisper fehlt oder kein Modell da ist.
- (nullable instancetype)initWithLanguage:(NSString *)language NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Eingestellte Sprache („en“ oder „auto“), wie beim Anlegen übergeben.
@property (nonatomic, copy, readonly) NSString *language;
/// Modellname, z. B. „base.en-q5_1“.
@property (nonatomic, copy, readonly) NSString *modelName;

/// Abschnitt 3,0 s, Überlappung 0,5 s (Vorgabe für BrowserWebSubtitleController).
@property (nonatomic) NSTimeInterval preferredWindowDuration;
@property (nonatomic) NSTimeInterval preferredOverlapDuration;
/// Modell nach so vielen Sekunden ohne Abschnitt freigeben (0 = nie). Standard 90.
@property (nonatomic) NSTimeInterval idleUnloadDelay;

/// Wird auf dem Hauptthread gerufen, wenn das Laden fertig ist (`message` deutsch, für einen Hinweis).
@property (nonatomic, copy, nullable) void (^loadHandler)(BOOL loaded, NSString *message);

/// Bei „auto“: von whisper festgelegte gesprochene Sprache (Engine-`lockedLanguage`), sonst nil. Threadsicher.
/// Für Apples Spracherkennung (BrowserAppleSpeechTranscriber), die whisper nur die Sprache bestimmen lässt.
@property (nonatomic, readonly, nullable) NSString *lockedLanguage;

/// Echtzeitfaktor (Rechenzeit / Audiodauer) seit dem Anlegen, über Neuladen hinweg.
@property (nonatomic, readonly) double averageRealTimeFactor;

/// Für die gemeinsame Pipeline (BrowserSubtitlePipeline, Vorausquelle oder Mithören): rechnet einen Abschnitt
/// (16 kHz mono float) ohne die Überlappungsbehandlung von `transcribeSamples:…` und liefert die Cues der Engine
/// (Satzstücke mit Token-Zeitmarken). `completion` genau einmal auf der whisper-Queue, nil bei Abbruch (`reset`).
- (void)transcribeEngineSamples:(NSData *)samples startTime:(NSTimeInterval)startTime
                     completion:(void (^)(NSArray<BrowserSubtitleCue *> * _Nullable cues))completion;

@end

NS_ASSUME_NONNULL_END
