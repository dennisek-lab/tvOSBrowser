#import "BrowserSpeechRecognizing.h"

NS_ASSUME_NONNULL_BEGIN

/// Platzhalter bis zum Anschluss der whisper-Engine: liefert je Abschnitt einen Cue
/// „[Ton erkannt: 1,0 s · −23 dB]“ (Dauer und RMS-Pegel), bei Stille „[Stille: 1,0 s]“.
@interface BrowserSpeechRecognizerStub : NSObject <BrowserSpeechRecognizing>

/// Künstliche Rechenzeit, um Verzögerung und Überlauf zu testen. Standard 0.
@property (nonatomic) NSTimeInterval simulatedProcessingTime;

@end

NS_ASSUME_NONNULL_END
