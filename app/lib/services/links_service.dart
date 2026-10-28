// Links: Android share sheet, clipboard, incoming App Links (`https://<host>/m/<code>`,
// `https://<host>/s#<data>`) and outgoing pages (Google Play subscriptions, privacy policy).
import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

abstract class LinkSource {
  /// The link that opened the app, if any.
  Future<Uri?> initialLink();

  /// Links received while the app runs.
  Stream<Uri> get links;
}

class AppLinksSource implements LinkSource {
  final AppLinks _appLinks = AppLinks();

  @override
  Future<Uri?> initialLink() async {
    try {
      return await _appLinks.getInitialLink();
    } catch (_) {
      return null;
    }
  }

  @override
  Stream<Uri> get links => _appLinks.uriLinkStream;
}

abstract class ShareSheet {
  Future<void> share(String text, {String? subject});
  Future<void> copy(String text);
}

class PlatformShareSheet implements ShareSheet {
  @override
  Future<void> share(String text, {String? subject}) async {
    await SharePlus.instance.share(ShareParams(text: text, subject: subject));
  }

  @override
  Future<void> copy(String text) => Clipboard.setData(ClipboardData(text: text));
}

abstract class UrlOpener {
  /// Opens [uri] outside the app (Play Store, browser). False if nothing could open it.
  Future<bool> open(Uri uri);
}

/// `ACTION_VIEW` intent through url_launcher: Google Play opens its own links, the browser
/// opens the others. No `canLaunchUrl` (it would need `<queries>` in the manifest).
class PlatformUrlOpener implements UrlOpener {
  @override
  Future<bool> open(Uri uri) async {
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('PlatformUrlOpener: cannot open $uri ($e)');
      return false;
    }
  }
}
