// Deterministic rules for simple voice commands (voice chain, « règles
// seules »). Conservative: a phrase is resolved only when every word is
// understood; anything else returns null and goes to the server model.
//
// Input is the output of `normalizeFrench`. Matching is accent-insensitive
// and uses the catalog aliases (longest first, exact match after articles
// are removed). The returned operations follow contract §3; the caller still
// runs `validateOps` (rights of the plan) before applying them.

import 'catalog.dart';
import 'french_normalizer.dart';
import 'ops.dart';

/// Parses [normalized] into operations, or returns null when not confident.
List<Map<String, dynamic>>? parseWithRules(
  String normalized,
  AppSnapshot snapshot,
  Catalog catalog,
) {
  final text = _clean(normalized);
  if (text.isEmpty) return null;

  if (_forbidden.hasMatch(text)) {
    return [
      {'op': 'refuser', 'raison': 'interdit'},
    ];
  }

  final parser = _RulesParser(snapshot, catalog, _AliasIndex.of(catalog));
  final whole = parser.parse(text);
  if (whole != null) return whole;

  // Several commands: « ajoute de la pluie et baisse les oiseaux ». A part
  // without a verb borrows the previous add/remove/adjust verb
  // (« ajoute de la pluie et du vent »).
  final parts = text.split(RegExp(r' (?:et puis|puis|ensuite|et) '));
  if (parts.length < 2) return null;
  final ops = <Map<String, dynamic>>[];
  String? verb;
  for (final part in parts) {
    var parsed = parser.parse(part);
    if (parsed == null && verb != null) parsed = parser.parse('$verb $part');
    if (parsed == null) return null;
    ops.addAll(parsed);
    final first = part.split(' ').first;
    if (_carriedVerbs.hasMatch(first)) verb = first;
  }
  return ops;
}

// --- vocabulary ------------------------------------------------------------

const String _add = r'(?:ajoute|ajoutez|ajouter|rajoute|rajoutez|rajouter)';
const String _put =
    r'(?:mets|met|mettez|mettre|remets|remet|remettez|remettre)';
const String _remove =
    r'(?:enleve|enlevez|enlever|retire|retirez|retirer|supprime|supprimez|supprimer|vire|virez|virer|ote|otez|oter|coupe|coupez|couper|arrete|arretez|arreter|stoppe|stoppez|stopper|eteins|eteignez|eteindre)';
const String _raise =
    r'(?:monte|montez|monter|augmente|augmentez|augmenter|remonte|remontez|remonter)';
const String _lower =
    r'(?:baisse|baissez|baisser|diminue|diminuez|diminuer|descends|descendez|descendre|reduis|reduisez|reduire)';
const String _activate =
    r'(?:active|activez|activer|allume|allumez|allumer|lance|lancez|lancer|demarre|demarrez|demarrer|mets|mettez|mettre|remets|commence|commencer)';
const String _deactivate =
    r'(?:desactive|desactivez|desactiver|arrete|arretez|arreter|coupe|coupez|couper|eteins|eteignez|eteindre|enleve|enlevez|enlever|retire|retirez|retirer|stoppe|stopper|supprime|supprimer)';
const String _minutes = r'(\d{1,4}) min';

/// « Coupe la musique »: mute (reversible), not remove (contract §3.1).
const String _mute =
    r'(?:coupe|coupez|couper|arrete|arretez|arreter|stoppe|stoppez|stopper|eteins|eteignez|eteindre)';
const String _unmute =
    r'(?:remets|remet|remettez|remettre|rallume|rallumez|rallumer|reactive|reactivez|reactiver|retablis|retablissez|retablir)';

final RegExp _carriedVerbs = RegExp('^(?:$_add|$_remove|$_raise|$_lower)\$');

/// Purchases, subscriptions, cancellations and account deletion: always
/// refused (`interdit`), whatever else the phrase says.
final RegExp _forbidden = RegExp(
  r"\b(?:achete|achetez|acheter|achat|achats|paye|payez|payer|paiement|abonne|abonnez|abonner|abonnement|desabonne|desabonnez|desabonner|desabonnement|resilie|resiliez|resilier|resiliation|rembourse|remboursez|rembourser|remboursement)\b|\b(?:supprime|supprimez|supprimer|efface|effacez|effacer|ferme|fermez|fermer|detruis|detruire|vide|vider)(?: moi)? (?:mon|le|ce|votre|mes|les|toutes mes) (?:compte|comptes|donnees)\b",
);

const List<String> _leadingFillers = [
  'est ce que tu pourrais',
  'est ce que tu peux',
  'est ce que vous pouvez',
  "s'il te plait",
  "s'il vous plait",
  'je voudrais que tu',
  "j'aimerais que tu",
  'je veux que tu',
  'tu pourrais',
  'pourrais tu',
  'tu peux',
  'peux tu',
  'vous pouvez',
  'pouvez vous',
  'pourriez vous',
  'veux tu',
  'voudrais tu',
  "d'accord",
  'eventide',
  'bonsoir',
  'bonjour',
  'salut',
  'alors',
  'allez',
  'okay',
  'merci',
  'stp',
  'svp',
  'bon',
  'euh',
  'hey',
  'ok',
  'oh',
];

const List<String> _trailingFillers = [
  "s'il te plait",
  "s'il vous plait",
  'merci beaucoup',
  'tout de suite',
  'maintenant',
  'eventide',
  'merci',
  'stp',
  'svp',
];

String _clean(String normalized) {
  var s = foldFrench(normalized)
      .replaceAll('-', ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  var changed = true;
  while (changed && s.isNotEmpty) {
    changed = false;
    for (final f in _leadingFillers) {
      if (s == f) return '';
      if (s.startsWith('$f ')) {
        s = s.substring(f.length + 1).trim();
        changed = true;
      }
    }
    for (final f in _trailingFillers) {
      if (s.endsWith(' $f')) {
        s = s.substring(0, s.length - f.length - 1).trim();
        changed = true;
      }
    }
  }
  return s;
}

final RegExp _articles = RegExp(
  r"^(?:un peu (?:de |d')|tous les |toutes les |tout le |toute la |de la |de l'|du |des |de |d'|le |la |les |l'|un |une |mon |ma |mes |ton |ta |tes |son |sa |ses |ce |cet |cette |ces )",
);
final RegExp _soundOf = RegExp(
  r"^(?:bruit|bruits|son|sons|chant|chants|volume|niveau|musique) (?:de la |de l'|du |des |de |d')",
);

/// Removes leading articles and « le bruit de », « le volume de »…
String _stripArticles(String input) {
  var s = input.trim();
  while (true) {
    final next = s.replaceFirst(_articles, '').replaceFirst(_soundOf, '');
    if (next == s) return s;
    s = next.trim();
  }
}

String _aliasKey(String alias) => _stripArticles(
  foldFrench(alias)
      .replaceAll('’', "'")
      .replaceAll('-', ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim(),
);

typedef _ItemRef = ({LayerKind kind, String id});

/// Aliases of a catalog, keyed by their folded form without articles.
class _AliasIndex {
  _AliasIndex(Catalog catalog) {
    final itemEntries = <(String, _ItemRef)>[];
    for (final kind in LayerKind.values) {
      for (final item in catalog.items(kind)) {
        for (final alias in {...item.aliases, item.name}) {
          itemEntries.add((_aliasKey(alias), (kind: kind, id: item.id)));
        }
      }
    }
    // Longest alias first (deterministic order of the lookups).
    itemEntries.sort((a, b) => b.$1.length.compareTo(a.$1.length));
    for (final (key, ref) in itemEntries) {
      final list = items.putIfAbsent(key, () => []);
      if (!list.contains(ref)) list.add(ref);
    }
    final landscapeEntries = <(String, String)>[];
    for (final l in catalog.landscapes) {
      for (final alias in {...l.aliases, l.name}) {
        landscapeEntries.add((_aliasKey(alias), l.id));
      }
    }
    landscapeEntries.sort((a, b) => b.$1.length.compareTo(a.$1.length));
    for (final (key, id) in landscapeEntries) {
      final list = landscapes.putIfAbsent(key, () => []);
      if (!list.contains(id)) list.add(id);
    }
  }

  static final Expando<_AliasIndex> _cache = Expando();

  static _AliasIndex of(Catalog catalog) =>
      _cache[catalog] ??= _AliasIndex(catalog);

  final Map<String, List<_ItemRef>> items = {};
  final Map<String, List<String>> landscapes = {};
}

class _RulesParser {
  _RulesParser(this.snapshot, this.catalog, this.index);

  final AppSnapshot snapshot;
  final Catalog catalog;
  final _AliasIndex index;

  // --- resolution -----------------------------------------------------------

  /// The single catalog item named by [phrase], or null (unknown or
  /// ambiguous). An alias shared by several kinds resolves to the one
  /// playing in the scene.
  _ItemRef? item(String phrase) {
    final refs = index.items[_stripArticles(phrase)];
    if (refs == null || refs.isEmpty) return null;
    if (refs.length == 1) return refs.single;
    final playing = [
      for (final r in refs)
        if (snapshot.scene.hasLayer(r.kind, r.id)) r,
    ];
    return playing.length == 1 ? playing.single : null;
  }

  String? landscape(String phrase) {
    var s = _stripArticles(phrase);
    s = s.replaceFirst(
      RegExp(
        r"^(?:paysage|ambiance|image|photo|fond) (?:de la |de l'|du |des |de |d')?",
      ),
      '',
    );
    final ids = index.landscapes[_stripArticles(s)];
    return ids != null && ids.length == 1 ? ids.single : null;
  }

  /// « la musique » → musique, « les sons » → son, « le décor » → decor.
  /// « les sons de la nature » arrives here as « nature » (see
  /// [_stripArticles]).
  LayerKind? kindWord(String phrase) {
    switch (_stripArticles(phrase)) {
      case 'musique':
      case 'musiques':
      case 'melodie':
      case 'melodies':
        return LayerKind.musique;
      case 'sons':
      case 'bruits':
      case 'nature':
      case 'sons de la nature':
      case 'bruits de la nature':
        return LayerKind.son;
      case 'decor':
      case 'decors':
      case 'effets':
      case 'effets visuels':
        return LayerKind.decor;
    }
    return null;
  }

  // --- parsing --------------------------------------------------------------

  List<Map<String, dynamic>>? parse(String text) {
    for (final rule in <List<Map<String, dynamic>>? Function(String)>[
      _premium,
      _outOfCatalog,
      _timer,
      _playback,
      _sleep,
      _settings,
      _share,
      _moment,
      _landscapeChange,
      _schedules,
      _mutes,
      _layers,
    ]) {
      final ops = rule(text);
      if (ops != null) return ops;
    }
    return null;
  }

  static RegExpMatch? _m(String pattern, String text) =>
      RegExp('^(?:$pattern)\$').firstMatch(text);

  List<Map<String, dynamic>>? _premium(String t) {
    if (_m(
          r"(?:passe|passez|passer|mets|mettez|bascule|basculez)(?: moi| nous)? (?:en|au|a la|a|sur) (?:version |mode |offre )?premium"
          r"|(?:ouvre|ouvrez|ouvrir|montre|montrez|montre moi|affiche|affichez|voir|je veux voir|je veux|je voudrais)(?: le| la| l'| l| les)?(?: offre| offres| version| ecran| page| formules?)? premium"
          r"|(?:la version |l'offre |le )?premium",
          t,
        ) !=
        null) {
      return [openPremiumOp()];
    }
    return null;
  }

  List<Map<String, dynamic>>? _outOfCatalog(String t) {
    if (_m(r"quelle heure (?:est il|il est)|il est quelle heure", t) != null) {
      return [
        {'op': 'refuser', 'raison': 'hors_catalogue'},
      ];
    }
    return null;
  }

  Map<String, dynamic> _timerOp(Map<String, dynamic> value) => {
    'op': 'definir',
    'cible': 'minuteur',
    'valeur': value,
  };

  List<Map<String, dynamic>>? _timer(String t) {
    RegExpMatch? m = _m(
      r"(?:arrete|arretez|arreter|arrete toi|coupe|coupez|couper|eteins|eteignez|eteins toi|stoppe|stop|termine|finis)"
      r"(?: tout| le son| la musique| la lecture| les sons)? (?:dans|apres) "
      '$_minutes',
      t,
    );
    m ??= _m(
      r"(?:(?:mets|mettez|mettre|met|lance|lancez|lancer|regle|reglez|regler|programme|programmez) )?(?:un |le |mon )?minuteur (?:de |a |sur |pour |d'|d )?"
      '$_minutes',
      t,
    );
    if (m != null) {
      final minutes = int.parse(m[1]!);
      if (minutes < 1 || minutes > 600) return null;
      return [
        _timerOp({'mode': 'duree', 'minutes': minutes}),
      ];
    }
    if (_m(
          r"(?:(?:mets|mettez|mettre|met|lance|lancer|regle|regler) )?(?:un |le )?minuteur (?:pour |sur |a )?toute la nuit"
          r"|(?:(?:joue|jouez|laisse|laissez|laisse tourner|continue|mets|lecture|ecoute) )?(?:pour |pendant |sur )?toute la nuit",
          t,
        ) !=
        null) {
      return [
        _timerOp({'mode': 'nuit'}),
      ];
    }
    if (_m(
          r"sans minuteur|pas de minuteur|aucun minuteur|minuteur (?:desactive|off|arrete|coupe)"
          r"|(?:enleve|enlevez|enlever|retire|retirez|retirer|supprime|supprimez|supprimer|annule|annulez|annuler|desactive|desactivez|desactiver|coupe|couper|arrete|arreter|eteins|eteindre|stoppe) (?:le |ce |mon )?minuteur",
          t,
        ) !=
        null) {
      return [
        _timerOp({'mode': 'aucun'}),
      ];
    }
    return null;
  }

  List<Map<String, dynamic>>? _playback(String t) {
    if (_m(
          r"pause|mets (?:en |sur )?pause|mettez (?:en |sur )?pause|mettre (?:en |sur )?pause|fais une pause|faites une pause|on fait une pause"
          r"|stop|stoppe|arrete|arretez|arrete tout|arrete le son|arrete la lecture|coupe le son|coupe tout|silence|chut",
          t,
        ) !=
        null) {
      return [
        {'op': 'lecture', 'valeur': 'pause'},
      ];
    }
    if (_m(
          r"reprends|reprenez|reprendre|reprise|reprends la lecture|continue|continuez|continuer|relance|relancez|relancer|relance le son"
          r"|remets le son|remettez le son|lecture|joue|jouez|play|rejoue|redemarre|redemarre le son|remets la lecture",
          t,
        ) !=
        null) {
      return [
        {'op': 'lecture', 'valeur': 'reprise'},
      ];
    }
    return null;
  }

  List<Map<String, dynamic>>? _sleep(String t) {
    const tracking = r"(?:le )?suivi (?:du|de|de mon) sommeil";
    if (_m('$_activate $tracking', t) != null) {
      return [
        {'op': 'definir', 'cible': 'sommeil.suivi', 'valeur': true},
      ];
    }
    if (_m(
          '$_deactivate $tracking|(?:plus|pas) de suivi (?:du|de) sommeil',
          t,
        ) !=
        null) {
      return [
        {'op': 'definir', 'cible': 'sommeil.suivi', 'valeur': false},
      ];
    }
    if (_m(
          r"(?:commence|commencez|commencer|lance|lancez|lancer|demarre|demarrez|demarrer|debute|debuter) (?:la|ma) nuit",
          t,
        ) !=
        null) {
      return [
        {'op': 'commencer_nuit'},
      ];
    }
    return null;
  }

  Map<String, dynamic> _setting(String key, Object value) => {
    'op': 'definir',
    'cible': 'reglage',
    'cle': key,
    'valeur': value,
  };

  List<Map<String, dynamic>>? _settings(String t) {
    const text =
        r"(?:le |les |l')?(?:texte|textes|ecriture|caracteres|lettres|police)";
    if (_m(
          r"(?:(?:mets|mettez|mettre|met|ecris|ecrivez|affiche|affichez) )?"
          '$text'
          r" (?:plus grands?|plus grandes?|plus gros|plus grosses?)"
          r"|(?:agrandis|agrandissez|agrandir|grossis|grossissez|grossir|augmente|augmentez|augmenter) (?:la taille (?:du |des )?)?"
          '$text'
          r"|ecris plus gros|ecrivez plus gros",
          t,
        ) !=
        null) {
      return [_setting('taille_texte', 'plus')];
    }
    if (_m(
          r"(?:(?:mets|mettez|mettre|met|ecris|ecrivez|affiche|affichez) )?"
          '$text'
          r" (?:plus petits?|plus petites?|moins gros|moins grand)"
          r"|(?:reduis|reduisez|reduire|diminue|diminuez|diminuer|rapetisse) (?:la taille (?:du |des )?)?"
          '$text'
          r"|ecris plus petit|ecrivez plus petit",
          t,
        ) !=
        null) {
      return [_setting('taille_texte', 'moins')];
    }
    const contrast = r"(?:le )?contraste(?: renforce| eleve| fort)?";
    if (_m(
          r"(?:(?:active|activez|activer|mets|mettez|mettre|allume|allumer) (?:le )?)?contraste (?:renforce|eleve|fort)"
          r"|plus de contraste|(?:renforce|renforcez|renforcer|augmente|augmentez|augmenter) le contraste",
          t,
        ) !=
        null) {
      return [_setting('contraste_renforce', true)];
    }
    if (_m('$_deactivate $contrast|contraste normal|moins de contraste', t) !=
        null) {
      return [_setting('contraste_renforce', false)];
    }
    const black = r"(?:l')?ecran noir";
    const during = r" pendant (?:le |mon )?minuteur";
    if (_m(
          r"(?:(?:active|activez|activer|mets|mettez|mettre|allume|allumer) )?"
          '$black$during'
          r"|(?:active|activez|activer) "
          '$black',
          t,
        ) !=
        null) {
      return [_setting('ecran_noir_minuteur', true)];
    }
    if (_m(
          '$_deactivate $black(?:$during)?|pas d\'ecran noir(?:$during)?',
          t,
        ) !=
        null) {
      return [_setting('ecran_noir_minuteur', false)];
    }
    const wifi = r"wi ?fi";
    const downloads =
        r"(?:les )?(?:telechargements?|telecharger|telecharge) (?:en|par|avec le|avec|uniquement en|seulement en) "
        '$wifi'
        r"(?: seulement| uniquement)?";
    if (_m(
          '(?:(?:active|activez|activer|mets|mettez|mettre) )?$downloads'
          '|(?:(?:active|activez|activer) (?:le )?)?$wifi (?:seulement|uniquement)',
          t,
        ) !=
        null) {
      return [_setting('wifi_seulement', true)];
    }
    if (_m(
          '$_deactivate (?:$downloads|(?:le )?$wifi (?:seulement|uniquement))',
          t,
        ) !=
        null) {
      return [_setting('wifi_seulement', false)];
    }
    return null;
  }

  List<Map<String, dynamic>>? _share(String t) {
    if (_m(
          r"(?:partage|partagez|partager|envoie|envoyez|envoyer)(?: le| la| l'| mon| ma| mes| ce| cette)? ?(?:mix|melange|ambiance|son|sons|paysage|reglages|scene)(?: (?:avec|a|au|aux|pour) .+)?",
          t,
        ) !=
        null) {
      return [
        {'op': 'partager'},
      ];
    }
    return null;
  }

  List<Map<String, dynamic>>? _moment(String t) {
    final m = _m(
      r"il fait (nuit|jour)|c'est (?:la |le |l')?(nuit|soir|jour|aube)"
      r"|(?:mets|mettez|mettre|met|passe|passez|passer|remets) (?:a |au |en |sur )?(?:le |la |l')?(aube|jour|soir|nuit)"
      r"|(?:le |la |l')?(aube|soir)",
      t,
    );
    if (m == null) return null;
    final value = m[1] ?? m[2] ?? m[3] ?? m[4];
    return [
      {'op': 'definir', 'cible': 'moment', 'valeur': value},
    ];
  }

  List<Map<String, dynamic>>? _landscapeChange(String t) {
    if (_m(
          r"(?:change|changez|changer) (?:de |le |d'|d )?(?:paysage|image|photo|fond|ambiance)"
          r"|(?:le |un )?paysage suivant|(?:un )?autre paysage|suivant|le suivant|paysage d'apres"
          r"|(?:passe|passez|va|allez) au (?:paysage )?suivant|(?:mets|montre|montre moi) (?:moi )?un autre paysage",
          t,
        ) !=
        null) {
      return [
        {'op': 'changer', 'cible': 'paysage', 'valeur': 'suivant'},
      ];
    }
    if (_m(
          r"(?:le )?paysage (?:precedent|d'avant)|precedent|le precedent"
          r"|(?:reviens|revenez|revenir|retourne|retournez|retour|va|allez|passe|passez|remets) (?:au|a l') ?(?:paysage )?(?:precedent|d'avant)",
          t,
        ) !=
        null) {
      return [
        {'op': 'changer', 'cible': 'paysage', 'valeur': 'precedent'},
      ];
    }
    return null;
  }

  /// `selecteur` from what follows « ma programmation ».
  Map<String, dynamic>? _selector(String? rest) {
    if (rest == null || rest.isEmpty) {
      final all = snapshot.schedules;
      return all.length == 1 ? {'id': all.single.id} : null;
    }
    final time = RegExp(r"^(?:de |d'|d |a |pour )?(\d{1,2}):(\d{2})$")
        .firstMatch(rest);
    if (time != null) {
      final h = int.parse(time[1]!);
      final min = int.parse(time[2]!);
      if (h > 23 || min > 59) return null;
      return {
        'heure':
            '${h.toString().padLeft(2, '0')}:${min.toString().padLeft(2, '0')}',
      };
    }
    if (_m(r"du matin|de ce matin", rest) != null) {
      return {'moment_journee': 'matin'};
    }
    if (_m(r"de l'apres midi|de l apres midi|d'apres midi", rest) != null) {
      return {'moment_journee': 'apres-midi'};
    }
    if (_m(r"du soir|de ce soir", rest) != null) {
      return {'moment_journee': 'soir'};
    }
    if (_m(r"pour dormir|du coucher|pour le coucher|pour aller dormir", rest) !=
        null) {
      return {'rappel': 'dormir'};
    }
    if (_m(
          r"pour (?:me|se|nous|vous) detendre|de detente|pour la detente",
          rest,
        ) !=
        null) {
      return {'rappel': 'detente'};
    }
    return null;
  }

  List<Map<String, dynamic>>? _schedules(String t) {
    const target = r"(?:ma|la|cette) programmation";
    final toggle = _m(
      r"(active|activez|activer|reactive|reactivez|reactiver|desactive|desactivez|desactiver|supprime|supprimez|supprimer|efface|effacez|effacer|enleve|enlevez|enlever|retire|retirez|retirer) "
      '$target'
      r"(?: (.+))?",
      t,
    );
    if (toggle != null) {
      final selector = _selector(toggle[2]);
      if (selector == null) return null;
      final verb = toggle[1]!;
      final op = verb.startsWith('desactiv')
          ? 'desactiver'
          : (verb.contains('activ') ? 'activer' : 'supprimer');
      return [
        {'op': op, 'cible': 'programmation', 'selecteur': selector},
      ];
    }
    final move = _m(
      r"(?:decale|decalez|decaler|deplace|deplacez|deplacer|change|changez|changer|mets|mettez|mettre|avance|avancez|avancer|recule|reculez|reculer|passe|passez|passer) "
      '$target'
      r"(?: (.+?))? (?:a|pour|vers) (\d{1,2}):(\d{2})",
      t,
    );
    if (move != null) {
      final selector = _selector(move[1]);
      if (selector == null) return null;
      final h = int.parse(move[2]!);
      final min = int.parse(move[3]!);
      if (h > 23 || min > 59) return null;
      return [
        {
          'op': 'modifier',
          'cible': 'programmation',
          'selecteur': selector,
          'valeur': {
            'heure':
                '${h.toString().padLeft(2, '0')}:${min.toString().padLeft(2, '0')}',
          },
        },
      ];
    }
    return null;
  }

  Map<String, dynamic> _categoryOp(String op, LayerKind kind) => {
    'op': op,
    'cible': kind.cible,
  };

  /// Sounds or music named by [phrase] (the decor has no mute).
  LayerKind? _audioKind(String phrase) {
    final kind = kindWord(phrase);
    return kind != null && kind.isAudio ? kind : null;
  }

  /// Mute and unmute of a whole category (contract §3.1). « Coupe la pluie »
  /// (one element) and « coupe le décor » are left to [_layers] (removal).
  List<Map<String, dynamic>>? _mutes(String t) {
    final scene = snapshot.scene;
    // « Enlève la sourdine (de la musique) » (before « coupe … »: « coupe la
    // sourdine » ends the mute).
    var m = _m(
      r"(?:enleve|enlevez|enlever|retire|retirez|retirer|supprime|supprimez|supprimer|ote|otez|oter|coupe|coupez|couper|desactive|desactivez|desactiver|arrete|arretez|arreter) (?:la |le mode )?sourdine(?: (?:de|du|des|sur|pour) (.+))?",
      t,
    );
    if (m != null) {
      final named = m[1];
      if (named != null) {
        final kind = _audioKind(named);
        return kind == null ? null : [_categoryOp('remettre', kind)];
      }
      // No category named: whatever is muted.
      final muted = [
        for (final kind in const [LayerKind.son, LayerKind.musique])
          if (scene.isMuted(kind)) _categoryOp('remettre', kind),
      ];
      return muted.isEmpty ? null : muted;
    }

    // « Mets la musique en sourdine », « mets en sourdine les sons ».
    m = _m(
      r"(?:(?:mets|met|mettez|mettre|passe|passez|passer) )?(.+?) (?:en|sur) sourdine",
      t,
    );
    m ??= _m(
      r"(?:(?:mets|met|mettez|mettre|passe|passez|passer) )?(?:en |sur )?sourdine (?:sur |pour |a )?(.+)",
      t,
    );
    // « Coupe la musique », « arrête les sons de la nature ».
    m ??= _m('$_mute (.+)', t);
    if (m != null) {
      final kind = _audioKind(m[1]!);
      return kind == null ? null : [_categoryOp('couper', kind)];
    }

    // « Remets la musique », « rallume les bruits de la nature ». With
    // nothing of that category in the mix, the model decides (it may add).
    m = _m('$_unmute (.+)', t);
    if (m != null) {
      final kind = _audioKind(m[1]!);
      if (kind == null || scene.layers(kind).isEmpty) return null;
      return [_categoryOp('remettre', kind)];
    }
    return null;
  }

  Map<String, dynamic> _layerOp(
    String op,
    _ItemRef ref, [
    String? key,
    int? value,
  ]) => {'op': op, 'cible': ref.kind.cible, 'id': ref.id, ?key: value};

  /// « un peu » halves the default step of 20.
  static bool _gentle(String? group) => group?.trim() == 'un peu';

  List<Map<String, dynamic>>? _layers(String t) {
    // « Mets l'eau vive à 70 % », « la pluie à 40 % », « mets le vent à fond ».
    var m = _m(
      r"(?:(?:mets|met|mettez|mettre|remets|regle|reglez|regler|passe|passez|monte|montez|baisse|baissez|descends|augmente|diminue) )?(.+?) (?:a|au|sur) (\d{1,3})(?: %)?",
      t,
    );
    if (m != null) {
      final ref = item(m[1]!);
      final level = int.parse(m[2]!);
      if (ref == null || level > 100) return null;
      return [_layerOp('regler', ref, 'niveau', level)];
    }
    m = _m(
      r"(?:(?:mets|met|mettez|mettre|monte|montez|pousse) )?(.+?) (?:a fond|au maximum|au max)",
      t,
    );
    if (m != null) {
      final ref = item(m[1]!);
      return ref == null ? null : [_layerOp('regler', ref, 'niveau', 100)];
    }

    // « Ajoute plus de pluie », « un peu plus d'oiseaux », « la pluie plus fort ».
    m = _m(
      r"(?:(?:ajoute|ajoutez|ajouter|rajoute|rajoutez|mets|met|mettez|mettre|donne moi|donnez moi|je veux) )?(un peu |encore )?plus (?:de |d'|d )(.+)",
      t,
    );
    m ??= _m('$_raise( un peu)? (.+?)', t);
    if (m != null) {
      final ref = item(m[2]!);
      if (ref == null) return null;
      return [_layerOp('ajuster', ref, 'delta', _gentle(m[1]) ? 10 : 20)];
    }
    m = _m(r"(.+?) (un peu )?plus forte?", t);
    if (m != null) {
      final ref = item(m[1]!);
      if (ref == null) return null;
      return [_layerOp('ajuster', ref, 'delta', _gentle(m[2]) ? 10 : 20)];
    }

    // « Baisse les oiseaux », « moins de vent », « le vent moins fort ».
    m = _m(
      r"(?:(?:mets|met|mettez|mettre) )?(un peu )?moins (?:de |d'|d )(.+)",
      t,
    );
    m ??= _m('$_lower( un peu)? (.+?)', t);
    if (m != null) {
      final ref = item(m[2]!);
      if (ref == null) return null;
      return [_layerOp('ajuster', ref, 'delta', _gentle(m[1]) ? -10 : -20)];
    }
    m = _m(r"(.+?) (un peu )?moins forte?", t);
    if (m != null) {
      final ref = item(m[1]!);
      if (ref == null) return null;
      return [_layerOp('ajuster', ref, 'delta', _gentle(m[2]) ? -10 : -20)];
    }

    // « Enlève le vent », « enlève la musique » (all music; « coupe la
    // musique » mutes instead, see [_mutes]).
    m = _m('$_remove (.+)', t);
    if (m != null) {
      final kind = kindWord(m[1]!);
      if (kind != null) {
        return [
          {'op': 'retirer', 'cible': kind.cible, 'id': '*'},
        ];
      }
      final ref = item(m[1]!);
      return ref == null ? null : [_layerOp('retirer', ref)];
    }

    // « Ajoute du piano doux ».
    m = _m('$_add(?: un peu)? (.+)', t);
    if (m != null) {
      final ref = item(m[1]!);
      return ref == null
          ? null
          : [_layerOp('ajouter', ref, 'niveau', defaultAddLevel)];
    }

    // « Mets la cascade en forêt » (landscape) or « Mets les lucioles » (item).
    m = _m(
      '(?:$_put|joue|jouez|jouer|lance|lancez|lancer|choisis|choisissez)(?: (?:sur|a|au|en))? (.+)',
      t,
    );
    final onlyLandscape = m == null
        ? _m(
            r"(?:passe|passez|passer|va|allez|aller|affiche|affichez|montre|montrez|montre moi|emmene moi|emmenez moi) (?:sur |a |au |en |dans |vers )?(.+)",
            t,
          )
        : null;
    if (m != null) {
      final landscapeId = landscape(m[1]!);
      final ref = item(m[1]!);
      if (landscapeId != null && ref == null) {
        return [
          {'op': 'definir', 'cible': 'paysage', 'valeur': landscapeId},
        ];
      }
      if (ref != null && landscapeId == null) {
        return [_layerOp('ajouter', ref, 'niveau', defaultAddLevel)];
      }
      return null;
    }
    if (onlyLandscape != null) {
      final landscapeId = landscape(onlyLandscape[1]!);
      if (landscapeId == null) return null;
      return [
        {'op': 'definir', 'cible': 'paysage', 'valeur': landscapeId},
      ];
    }
    return null;
  }
}
