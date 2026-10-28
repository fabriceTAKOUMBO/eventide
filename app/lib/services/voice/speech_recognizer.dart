// On-device speech recognition (Android's recognizer through speech_to_text).
// The recorded sound is never stored by the app; the transcript only lives in memory.
import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

abstract class SpeechRecognizer {
  /// False when no recognizer is available on the phone.
  Future<bool> initialize();

  /// fr_BE, else fr_FR, else any French locale offered by the phone; null if none.
  Future<String?> frenchLocale();

  /// Starts listening at once. [onResult] receives partial texts then the final one.
  Future<void> listen({
    required String? localeId,
    required void Function(String text, bool isFinal) onResult,
    required void Function(double level) onLevel,
    required void Function(String error) onError,
    required void Function() onDone,
    Duration maxDuration,
  });

  /// Stops and delivers the final result.
  Future<void> stop();

  /// Stops without result.
  Future<void> cancel();
}

/// Picks the best French locale id among [available] ids (`fr_BE` > `fr_FR` > `fr*`).
String? pickFrenchLocale(Iterable<String> available) {
  String norm(String id) => id.replaceAll('-', '_').toLowerCase();
  final ids = available.toList();
  for (final wanted in const ['fr_be', 'fr_fr']) {
    for (final id in ids) {
      if (norm(id) == wanted) return id;
    }
  }
  for (final id in ids) {
    if (norm(id).startsWith('fr')) return id;
  }
  return null;
}

class SpeechToTextRecognizer implements SpeechRecognizer {
  final SpeechToText _speech = SpeechToText();
  bool _initialized = false;
  void Function(String error)? _onError;
  void Function()? _onDone;

  @override
  Future<bool> initialize() async {
    if (_initialized) return true;
    try {
      _initialized = await _speech.initialize(
        onError: (SpeechRecognitionError error) => _onError?.call(error.errorMsg),
        onStatus: (String status) {
          // « done » comes after the final result (« notListening » may come before it).
          if (status == SpeechToText.doneStatus) _onDone?.call();
        },
      );
    } catch (e) {
      debugPrint('SpeechToTextRecognizer: $e');
      _initialized = false;
    }
    return _initialized;
  }

  @override
  Future<String?> frenchLocale() async {
    try {
      final locales = await _speech.locales();
      return pickFrenchLocale(locales.map((l) => l.localeId));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> listen({
    required String? localeId,
    required void Function(String text, bool isFinal) onResult,
    required void Function(double level) onLevel,
    required void Function(String error) onError,
    required void Function() onDone,
    Duration maxDuration = const Duration(seconds: 20),
  }) async {
    _onError = onError;
    _onDone = onDone;
    await _speech.listen(
      onResult: (SpeechRecognitionResult result) => onResult(result.recognizedWords, result.finalResult),
      // Android reports roughly -2..10 dB.
      onSoundLevelChange: (double level) => onLevel(((level + 2) / 12).clamp(0.0, 1.0)),
      listenOptions: SpeechListenOptions(
        localeId: localeId,
        listenFor: maxDuration,
        pauseFor: const Duration(seconds: 4),
        partialResults: true,
        cancelOnError: true,
        listenMode: ListenMode.dictation,
      ),
    );
  }

  @override
  Future<void> stop() => _speech.stop();

  @override
  Future<void> cancel() => _speech.cancel();
}
