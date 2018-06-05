// Copyright 2017 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:convert' as convert;

import 'package:json_schema/json_schema.dart';
import 'package:meta/meta.dart';
import 'package:yaml/yaml.dart';

import 'base/file_system.dart';
import 'cache.dart';
import 'globals.dart';

final RegExp _versionPattern = new RegExp(r'^(\d+)(\.(\d+)(\.(\d+))?)?(\+(\d+))?$');

/// A wrapper around the `flutter` section in the `pubspec.yaml` file.
class FlutterManifest {
  FlutterManifest._();

  /// Returns null on invalid manifest. Returns empty manifest on missing file.
  static Future<FlutterManifest> createFromPath(String path) async {
    if (path == null || !fs.isFileSync(path))
      return _createFromYaml(null);
    final String manifest = await fs.file(path).readAsString();
    return createFromString(manifest);
  }

  /// Returns null on missing or invalid manifest
  @visibleForTesting
  static Future<FlutterManifest> createFromString(String manifest) async {
    return _createFromYaml(loadYaml(manifest));
  }

  static Future<FlutterManifest> _createFromYaml(Object yamlDocument) async {
    final FlutterManifest pubspec = new FlutterManifest._();
    if (yamlDocument != null && !await _validate(yamlDocument))
      return null;

    pubspec._descriptor = yamlDocument ?? <String, dynamic>{};
    pubspec._flutterDescriptor = pubspec._descriptor['flutter'] ?? <String, dynamic>{};
    return pubspec;
  }

  /// A map representation of the entire `pubspec.yaml` file.
  Map<String, dynamic> _descriptor;

  /// A map representation of the `flutter` section in the `pubspec.yaml` file.
  Map<String, dynamic> _flutterDescriptor;

  bool get isEmpty => _descriptor.isEmpty;

  String get appName => _descriptor['name'] ?? '';

  /// The version String from the `pubspec.yaml` file.
  /// Can be null if it isn't set or has a wrong format.
  String get appVersion {
    final String version = _descriptor['version']?.toString();
    if (version != null && _versionPattern.hasMatch(version))
      return version;
    else
      return null;
  }

  /// The build version name from the `pubspec.yaml` file.
  /// Can be null if version isn't set or has a wrong format.
  String get buildName {
    if (appVersion != null && appVersion.contains('+'))
      return appVersion.split('+')?.elementAt(0);
    else
      return appVersion;
  }

  /// The build version number from the `pubspec.yaml` file.
  /// Can be null if version isn't set or has a wrong format.
  int get buildNumber {
    if (appVersion != null && appVersion.contains('+')) {
      final String value = appVersion.split('+')?.elementAt(1);
      return value == null ? null : int.tryParse(value);
    } else {
      return null;
    }
  }

  bool get usesMaterialDesign {
    return _flutterDescriptor['uses-material-design'] ?? false;
  }

  List<Map<String, dynamic>> get fontsDescriptor {
   return _flutterDescriptor['fonts'] ?? const <Map<String, dynamic>>[];
  }

  List<Uri> get assets {
    return _flutterDescriptor['assets']?.map(Uri.encodeFull)?.map(Uri.parse)?.toList() ?? const <Uri>[];
  }

  List<Font> _fonts;

  List<Font> get fonts {
    _fonts ??= _extractFonts();
    return _fonts;
  }

  List<Font> _extractFonts() {
    if (!_flutterDescriptor.containsKey('fonts'))
      return <Font>[];

    final List<Font> fonts = <Font>[];
    for (Map<String, dynamic> fontFamily in _flutterDescriptor['fonts']) {
      final List<Map<String, dynamic>> fontFiles = fontFamily['fonts'];
      final String familyName = fontFamily['family'];
      if (familyName == null) {
        printError('Warning: Missing family name for font.', emphasis: true);
        continue;
      }
      if (fontFiles == null) {
        printError('Warning: No fonts specified for font $familyName', emphasis: true);
        continue;
      }

      final List<FontAsset> fontAssets = <FontAsset>[];
      for (Map<String, dynamic> fontFile in fontFiles) {
        final String asset = fontFile['asset'];
        if (asset == null) {
          printError('Warning: Missing asset in fonts for $familyName', emphasis: true);
          continue;
        }

        fontAssets.add(new FontAsset(
          Uri.parse(asset),
          weight: fontFile['weight'],
          style: fontFile['style'],
        ));
      }
      if (fontAssets.isNotEmpty)
        fonts.add(new Font(fontFamily['family'], fontAssets));
    }
    return fonts;
  }
}

class Font {
  Font(this.familyName, this.fontAssets)
    : assert(familyName != null),
      assert(fontAssets != null),
      assert(fontAssets.isNotEmpty);

  final String familyName;
  final List<FontAsset> fontAssets;

  Map<String, dynamic> get descriptor {
    return <String, dynamic>{
      'family': familyName,
      'fonts': fontAssets.map((FontAsset a) => a.descriptor).toList(),
    };
  }

  @override
  String toString() => '$runtimeType(family: $familyName, assets: $fontAssets)';
}

class FontAsset {
  FontAsset(this.assetUri, {this.weight, this.style})
    : assert(assetUri != null);

  final Uri assetUri;
  final int weight;
  final String style;

  Map<String, dynamic> get descriptor {
    final Map<String, dynamic> descriptor = <String, dynamic>{};
    if (weight != null)
      descriptor['weight'] = weight;

    if (style != null)
      descriptor['style'] = style;

    descriptor['asset'] = assetUri.path;
    return descriptor;
  }

  @override
  String toString() => '$runtimeType(asset: ${assetUri.path}, weight; $weight, style: $style)';
}

@visibleForTesting
String buildSchemaDir(FileSystem fs) {
  return fs.path.join(
    fs.path.absolute(Cache.flutterRoot), 'packages', 'flutter_tools', 'schema',
  );
}

@visibleForTesting
String buildSchemaPath(FileSystem fs) {
  return fs.path.join(
    buildSchemaDir(fs),
    'pubspec_yaml.json',
  );
}

Future<bool> _validate(Object manifest) async {
  final String schemaPath = buildSchemaPath(fs);

  final String schemaData = fs.file(schemaPath).readAsStringSync();
  final Schema schema = await Schema.createSchema(
      convert.json.decode(schemaData));
  final Validator validator = new Validator(schema);
  if (validator.validate(manifest)) {
    return true;
  } else {
    printStatus('Error detected in pubspec.yaml:', emphasis: true);
    printError(validator.errors.join('\n'));
    return false;
  }
}