// Optional Google sign-in (google_sign_in 7.x): only to obtain an id token for
// POST /account/google, which links this installation to the Google account (rights and
// counters then follow the account to a new phone).
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

abstract class AccountAuth {
  /// Shows Google's account picker; returns an id token, or null when cancelled/unavailable.
  Future<String?> signIn();

  Future<void> signOut();
}

class GoogleAccountAuth implements AccountAuth {
  GoogleAccountAuth({required this.serverClientId});

  /// Web client id of the API (audience of the id token).
  final String serverClientId;
  Future<void>? _init;

  Future<void> _ensureInit() => _init ??= GoogleSignIn.instance.initialize(
        serverClientId: serverClientId.isEmpty ? null : serverClientId,
      );

  @override
  Future<String?> signIn() async {
    try {
      await _ensureInit();
      if (!GoogleSignIn.instance.supportsAuthenticate()) return null;
      final account = await GoogleSignIn.instance.authenticate();
      return account.authentication.idToken;
    } on GoogleSignInException catch (e) {
      if (e.code != GoogleSignInExceptionCode.canceled) debugPrint('GoogleAccountAuth: ${e.code} ${e.description}');
      return null;
    } catch (e) {
      debugPrint('GoogleAccountAuth: $e');
      return null;
    }
  }

  @override
  Future<void> signOut() async {
    try {
      await _ensureInit();
      await GoogleSignIn.instance.signOut();
    } catch (_) {}
  }
}
