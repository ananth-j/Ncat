import 'package:shared_preferences/shared_preferences.dart';

import 'palette.dart';

const _kThemeChoiceKey = 'wcat.theme_choice';

Future<AppThemeChoice> loadThemeChoice() async {
  final prefs = await SharedPreferences.getInstance();
  return switch (prefs.getString(_kThemeChoiceKey)) {
    'light' => AppThemeChoice.light,
    'darkModern' => AppThemeChoice.darkModern,
    'vsDark' => AppThemeChoice.vsDark,
    _ => AppThemeChoice.system,
  };
}

Future<void> saveThemeChoice(AppThemeChoice choice) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_kThemeChoiceKey, choice.name);
}
