// One simple sentence before each Android permission (dossier § 4: never ask cold).
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../app/app_model.dart';
import '../theme/vitre.dart';
import 'glass.dart';
import 'vicons.dart';

String permissionTitle(PermissionKind kind) => switch (kind) {
  PermissionKind.microphone => 'Le micro',
  PermissionKind.notifications => 'Les notifications',
  PermissionKind.exactAlarm => 'Démarrer à l’heure',
};

String permissionSentence(PermissionKind kind) => switch (kind) {
  PermissionKind.microphone => 'Pour vous écouter quand vous parlez, Eventide a besoin du micro. Votre voix n’est pas enregistrée.',
  PermissionKind.notifications => 'Pour vous rappeler l’heure d’aller dormir et afficher les commandes du son, Eventide a besoin des notifications.',
  PermissionKind.exactAlarm => 'Pour lancer le son exactement à l’heure choisie, Android demande votre autorisation.',
};

VIconData _permissionIcon(PermissionKind kind) => switch (kind) {
  PermissionKind.microphone => VIcons.mic,
  PermissionKind.notifications => VIcons.bell,
  PermissionKind.exactAlarm => VIcons.alarm,
};

/// Explains why, then asks Android. Returns true when the permission is granted.
/// Already granted: returns true without showing anything.
Future<bool> explainAndRequestPermission(
  BuildContext context,
  AppModel model,
  PermissionKind kind,
) async {
  if (model.permissionGranted(kind)) return true;
  final go = await showVitreDialog<bool>(
    context,
    icon: _permissionIcon(kind),
    title: permissionTitle(kind),
    message: permissionSentence(kind),
    confirm: 'Continuer',
    cancel: 'Plus tard',
  );
  if (go != true) return false;
  return model.requestPermission(kind);
}

/// Glass confirmation dialog. Returns true for [confirm], false for [cancel].
Future<T?> showVitreDialog<T>(
  BuildContext context, {
  required String title,
  required String message,
  required String confirm,
  String? cancel,
  VIconData? icon,
  bool destructive = false,
  Widget? extra,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Fermer',
    barrierColor: const Color(0x99000000),
    transitionDuration: motion(context, const Duration(milliseconds: 200)),
    pageBuilder: (dialogContext, a, b) {
      final p = Vitre.of(context);
      return SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Material(
              type: MaterialType.transparency,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(32),
                child: BackdropFilter(
                  filter: ui.ImageFilter.blur(sigmaX: 15, sigmaY: 15),
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 420),
                    padding: const EdgeInsets.fromLTRB(22, 24, 22, 18),
                    decoration: BoxDecoration(
                      color: p.glass(0.84),
                      borderRadius: BorderRadius.circular(32),
                      border: Border.all(color: p.border(0.2)),
                    ),
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (icon != null)
                            Align(
                              alignment: Alignment.centerLeft,
                              child: Container(
                                width: 56,
                                height: 56,
                                decoration: BoxDecoration(
                                  color: p.fill(0.1),
                                  shape: BoxShape.circle,
                                  border: Border.all(color: p.border(0.24)),
                                ),
                                alignment: Alignment.center,
                                child: VIcon(
                                  icon,
                                  size: 28,
                                  color: VitreColors.white,
                                ),
                              ),
                            ),
                          if (icon != null) const SizedBox(height: 16),
                          Semantics(
                            header: true,
                            child: Text(
                              title,
                              style: manrope(
                                24,
                                weight: 600,
                                letterSpacingEm: -0.015,
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            message,
                            style: manrope(
                              18,
                              height: 1.4,
                              color: p.text(0.86),
                            ),
                          ),
                          if (extra != null) ...[
                            const SizedBox(height: 14),
                            extra,
                          ],
                          const SizedBox(height: 22),
                          PrimaryButton(
                            label: confirm,
                            onPressed: () =>
                                Navigator.of(dialogContext).pop(true),
                            height: 60,
                            fontSize: 19,
                          ),
                          if (cancel != null) ...[
                            const SizedBox(height: 6),
                            LinkButton(
                              label: cancel,
                              onPressed: () =>
                                  Navigator.of(dialogContext).pop(false),
                              fontSize: 18,
                              height: 52,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
    transitionBuilder: (context, animation, secondary, child) => FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
      child: child,
    ),
  );
}
