import 'package:flutter/material.dart';

import 'features/logcat/pages/logcat_page.dart';
import 'src/palette.dart';
import 'src/theme_pref.dart';

/// Root application widget configuring themes and initial routes.
class LogcatApp extends StatefulWidget {
  const LogcatApp({super.key});

  @override
  State<LogcatApp> createState() => _LogcatAppState();
}

class _LogcatAppState extends State<LogcatApp> {
  AppThemeChoice _themeChoice = AppThemeChoice.system;
  bool _userChangedTheme = false;

  @override
  void initState() {
    super.initState();
    loadThemeChoice().then((choice) {
      if (mounted && !_userChangedTheme) setState(() => _themeChoice = choice);
    });
  }

  void _setThemeChoice(AppThemeChoice choice) {
    _userChangedTheme = true;
    setState(() => _themeChoice = choice);
    saveThemeChoice(choice);
  }

  @override
  Widget build(BuildContext context) {
    final darkPalette =
        _themeChoice == AppThemeChoice.vsDark
            ? kVsDarkPalette
            : kDarkModernPalette;

    return MaterialApp(
      title: 'ThruWire',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(Brightness.light, kLightPalette),
      darkTheme: buildAppTheme(Brightness.dark, darkPalette),
      themeMode: switch (_themeChoice) {
        AppThemeChoice.system => ThemeMode.system,
        AppThemeChoice.light => ThemeMode.light,
        AppThemeChoice.darkModern || AppThemeChoice.vsDark => ThemeMode.dark,
      },
      home: LogcatPage(
        themeChoice: _themeChoice,
        onThemeChoice: _setThemeChoice,
      ),
    );
  }
}
