import 'package:eventide/core/catalog.dart';
import 'package:eventide/services/audio/audio_engine.dart';
import 'package:eventide/services/content_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('layer volume = level/100 × category gain', () {
    expect(MixRules.layerVolume(LayerKind.son, 60), closeTo(0.6, 1e-9));
    expect(MixRules.layerVolume(LayerKind.musique, 50), closeTo(0.4, 1e-9));
    expect(MixRules.layerVolume(LayerKind.decor, 80), 0);
    expect(MixRules.layerVolume(LayerKind.son, 150), 1.0);
    expect(MixRules.layerVolume(LayerKind.son, -5), 0);
  });

  test('master volume is capped below full scale', () {
    expect(MixRules.masterCap, lessThan(1.0));
    expect(MixRules.timerFadeOut, const Duration(seconds: 30));
    expect(MixRules.crossFade, const Duration(seconds: 2));
  });

  test('layer keys and content keys follow the contract layout', () {
    expect(MixRules.layerKey(LayerKind.son, 'pluie-douce'), 'son:pluie-douce');
    expect(ContentRepository.contentKey(LayerKind.son, 'vagues'), 'audio/sons/vagues.ogg');
    expect(ContentRepository.contentKey(LayerKind.musique, 'harpe'), 'audio/musiques/harpe.ogg');
    expect(ContentRepository.assetKey(LayerKind.musique, 'harpe'), 'assets/audio/musiques/harpe.ogg');
  });

  test('audio sources compare by location', () {
    expect(const AssetAudioSource('a'), const AssetAudioSource('a'));
    expect(const FileAudioSource('/x'), isNot(const AssetAudioSource('/x')));
    expect(const FileAudioSource('/x').cacheKey, 'file:/x');
  });
}
