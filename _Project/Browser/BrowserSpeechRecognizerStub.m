#import "BrowserSpeechRecognizerStub.h"

#include <math.h>

@implementation BrowserSpeechRecognizerStub

- (NSTimeInterval)preferredWindowDuration {
    return 1.0;
}

- (NSTimeInterval)preferredOverlapDuration {
    return 0.0;
}

- (NSString *)recognizerName {
    return @"stub";
}

- (void)transcribeSamples:(const float *)samples
                    count:(NSUInteger)count
                startTime:(NSTimeInterval)startTime
               completion:(void (^)(NSArray<BrowserWebSubtitleCue *> *))completion {
    double sum = 0.0;
    float peak = 0.0f;
    for (NSUInteger i = 0; i < count; i++) {
        float value = samples[i];
        sum += (double)value * value;
        peak = MAX(peak, fabsf(value));
    }
    double rms = count > 0 ? sqrt(sum / count) : 0.0;
    double duration = count / 16000.0;
    NSString *seconds = [NSString stringWithFormat:@"%.1f", duration];
    seconds = [seconds stringByReplacingOccurrencesOfString:@"." withString:@","];
    NSString *text;
    if (peak == 0.0f) {
        text = [NSString stringWithFormat:@"[Stille: %@ s]", seconds];
    } else {
        double decibels = 20.0 * log10(MAX(rms, 1e-9));
        NSString *level = [[NSString stringWithFormat:@"%.0f", decibels] stringByReplacingOccurrencesOfString:@"-" withString:@"−"];
        text = [NSString stringWithFormat:@"[Ton erkannt: %@ s · %@ dB]", seconds, level];
    }
    NSArray *cues = @[[BrowserWebSubtitleCue cueWithStart:startTime end:startTime + duration text:text]];
    if (self.simulatedProcessingTime > 0.0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.simulatedProcessingTime * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            completion(cues);
        });
        return;
    }
    completion(cues);
}

@end
