/// Application-wide constants for wcat.
library;

/// Maximum number of lines kept in memory buffer to prevent unbounded growth.
const int kMaxLines = 8000;

/// Android log levels in ascending order of severity.
const List<String> kLevels = ['V', 'D', 'I', 'W', 'E', 'F'];

/// Human-readable names for each severity level.
const Map<String, String> kLevelNames = {
  'V': 'Verbose',
  'D': 'Debug',
  'I': 'Info',
  'W': 'Warn',
  'E': 'Error',
  'F': 'Assert',
};
