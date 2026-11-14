/// A small Android Studio Logcat-style query evaluator.
///
/// Terms are ANDed. Supported fields are tag, package, process, message, and
/// level. Prefix a term with `-` to exclude it, or use `field~:pattern` for a
/// regular expression. Unqualified terms search the tag and message.
class LogQuery {
  LogQuery(String source, {this.useRegex = false})
    : terms = _parseTerms(source, useRegex);

  final bool useRegex;
  final List<LogQueryTerm> terms;

  bool get isEmpty => terms.isEmpty;
}

class LogQueryTerm {
  const LogQueryTerm({
    required this.field,
    required this.value,
    required this.negated,
    required this.regex,
    this.compiledRegex,
  });

  final String? field;
  final String value;
  final bool negated;
  final bool regex;
  final RegExp? compiledRegex;

  bool matches(String candidate) {
    final matched = regex
        ? compiledRegex?.hasMatch(candidate) ?? false
        : candidate.toLowerCase().contains(value.toLowerCase());
    return negated ? !matched : matched;
  }
}

List<LogQueryTerm> _parseTerms(String source, bool useRegex) {
  final tokens = RegExp(r'''(?:[^\s"']+|"[^"]*"|'[^']*')+''')
      .allMatches(source)
      .map((m) => m.group(0)!)
      .toList(growable: false);
  final terms = <LogQueryTerm>[];

  for (var token in tokens) {
    if (token == '&') continue;
    var negated = token.startsWith('-');
    if (negated) token = token.substring(1);

    String? field;
    var regex = useRegex;
    final separator = token.indexOf(':');
    if (separator > 0) {
      var fieldText = token.substring(0, separator).toLowerCase();
      if (fieldText.endsWith('~')) {
        fieldText = fieldText.substring(0, fieldText.length - 1);
        regex = true;
      }
      if (const {'tag', 'package', 'process', 'message', 'level'}.contains(
        fieldText,
      )) {
        field = fieldText;
        token = token.substring(separator + 1);
      }
    }

    if ((token.startsWith('"') && token.endsWith('"')) ||
        (token.startsWith("'") && token.endsWith("'"))) {
      token = token.substring(1, token.length - 1);
    }
    if (token.isEmpty) continue;

    RegExp? compiled;
    if (regex) {
      try {
        compiled = RegExp(token, caseSensitive: false);
      } on FormatException {
        // Invalid regexes deliberately match no entries.
      }
    }
    terms.add(
      LogQueryTerm(
        field: field,
        value: token,
        negated: negated,
        regex: regex,
        compiledRegex: compiled,
      ),
    );
  }
  return terms;
}
