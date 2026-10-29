// Application settings (« Réglages »). The app always opens with the menu
// expanded, so the menu state is not a setting.

class AppSettings {
  const AppSettings({
    this.textSize = 0,
    this.highContrast = false,
    this.blackScreenDuringTimer = false,
    this.wifiOnly = false,
    this.onboarded = false,
  });

  /// 0 Normale, 1 Grande, 2 Très grande (`taille_texte`).
  final int textSize;

  /// « Contraste renforcé » (`contraste_renforce`).
  final bool highContrast;

  /// « Écran noir pendant le minuteur » (`ecran_noir_minuteur`).
  final bool blackScreenDuringTimer;

  /// « Téléchargements en Wi-Fi seulement » (`wifi_seulement`).
  final bool wifiOnly;

  /// The welcome screen has been shown (local only).
  final bool onboarded;

  static const int maxTextSize = 2;
  static const List<String> textSizeLabels = [
    'Normale',
    'Grande',
    'Très grande',
  ];

  /// Extra scale applied on top of the system text scale.
  double get textScale => const [1.0, 1.15, 1.3][textSize.clamp(0, 2)];

  String get textSizeLabel => textSizeLabels[textSize.clamp(0, 2)];

  /// Stored form (French keys, plus local-only fields).
  Map<String, dynamic> toJson() => {
    'taille_texte': textSize,
    'contraste_renforce': highContrast,
    'ecran_noir_minuteur': blackScreenDuringTimer,
    'wifi_seulement': wifiOnly,
    'onboarded': onboarded,
  };

  /// Lenient: unknown or invalid values fall back to the defaults.
  factory AppSettings.fromJson(Map<String, dynamic> json) {
    final size = json['taille_texte'];
    return AppSettings(
      textSize: size is int ? size.clamp(0, maxTextSize) : 0,
      highContrast: json['contraste_renforce'] == true,
      blackScreenDuringTimer: json['ecran_noir_minuteur'] == true,
      wifiOnly: json['wifi_seulement'] == true,
      onboarded: json['onboarded'] == true,
    );
  }

  AppSettings copyWith({
    int? textSize,
    bool? highContrast,
    bool? blackScreenDuringTimer,
    bool? wifiOnly,
    bool? onboarded,
  }) {
    return AppSettings(
      textSize: (textSize ?? this.textSize).clamp(0, maxTextSize),
      highContrast: highContrast ?? this.highContrast,
      blackScreenDuringTimer:
          blackScreenDuringTimer ?? this.blackScreenDuringTimer,
      wifiOnly: wifiOnly ?? this.wifiOnly,
      onboarded: onboarded ?? this.onboarded,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AppSettings &&
      other.textSize == textSize &&
      other.highContrast == highContrast &&
      other.blackScreenDuringTimer == blackScreenDuringTimer &&
      other.wifiOnly == wifiOnly &&
      other.onboarded == onboarded;

  @override
  int get hashCode => Object.hash(
    textSize,
    highContrast,
    blackScreenDuringTimer,
    wifiOnly,
    onboarded,
  );

  @override
  String toString() => 'AppSettings(${toJson()})';
}
