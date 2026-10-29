// Landscape as the phone's wallpaper (docs/app/architecture.md « Fond d'écran vidéo »).

/// What this phone offers.
class WallpaperSupport {
  const WallpaperSupport({this.liveWallpaper = false});

  /// Android live wallpapers (`FEATURE_LIVE_WALLPAPER`): the looping video on the home screen
  /// (and on the lock screen when the phone allows it, as One UI does).
  final bool liveWallpaper;

  bool get any => liveWallpaper;

  static const WallpaperSupport none = WallpaperSupport();

  @override
  bool operator ==(Object other) =>
      other is WallpaperSupport && other.liveWallpaper == liveWallpaper;

  @override
  int get hashCode => liveWallpaper.hashCode;
}

/// Outcome of « Mettre en fond d'écran ».
enum WallpaperResult {
  /// Android's live wallpaper preview is open: the user confirms there (Android never lets an
  /// app change the wallpaper silently).
  opened,

  /// The phone has no live wallpapers, or no screen to choose one.
  unsupported,

  /// The current plan cannot use this landscape.
  notAllowed,

  /// Neither the video nor the still picture of this landscape is on the phone yet.
  unavailable,

  /// Something else went wrong.
  failed,
}
