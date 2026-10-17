import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

const _kPresetsKey = 'wcat.filter_presets';

class FilterPreset {
  const FilterPreset({
    required this.name,
    required this.package,
    required this.search,
    required this.minLevel,
    required this.useRegex,
  });

  final String name;
  final String package;
  final String search;
  final String minLevel;
  final bool useRegex;

  Map<String, dynamic> toJson() => {
        'name': name,
        'package': package,
        'search': search,
        'minLevel': minLevel,
        'useRegex': useRegex,
      };

  factory FilterPreset.fromJson(Map<String, dynamic> j) => FilterPreset(
        name: j['name'] as String,
        package: j['package'] as String? ?? '',
        search: j['search'] as String? ?? '',
        minLevel: j['minLevel'] as String? ?? 'V',
        useRegex: j['useRegex'] as bool? ?? false,
      );
}

Future<List<FilterPreset>> loadFilterPresets() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(_kPresetsKey);
  if (raw == null) return [];

  try {
    final list = jsonDecode(raw) as List;
    return list
        .map((e) => FilterPreset.fromJson(e as Map<String, dynamic>))
        .toList();
  } catch (_) {
    return [];
  }
}

Future<void> saveFilterPresets(List<FilterPreset> presets) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(
    _kPresetsKey,
    jsonEncode(presets.map((p) => p.toJson()).toList()),
  );
}
