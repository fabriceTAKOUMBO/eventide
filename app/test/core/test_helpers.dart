import 'dart:convert';
import 'dart:io';

import 'package:eventide/core/catalog.dart';

/// The real catalog (tests run from `app/`).
Catalog loadCatalog() => Catalog.fromJson(loadCatalogJson());

/// The JSON of the real catalog, to build variants of it.
Map<String, dynamic> loadCatalogJson() =>
    jsonDecode(File('assets/catalog.json').readAsStringSync()) as Map<String, dynamic>;
