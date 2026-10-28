// Share links: Android share sheet, clipboard, and incoming App Links
// (`https://<host>/m/<code>`, `https://<host>/s#<data>`).
import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

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
