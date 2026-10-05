// Fails when dart-apitool reports a breaking change against the latest release
// that tool/api/semver_waivers.txt does not accept.
//
//   dart-apitool diff --old pub://cometchat_chat_uikit/<latest> --new ./ \
//     --version-check-mode fully --no-set-exit-on-version-check-failure \
//     --report-format json --report-file-path api-diff.json
//   dart run tool/api_semver_gate.dart api-diff.json
//
// dart-apitool's own verdict cannot be the gate on its own: it has no way to
// accept a reviewed exception, so one justified change would block every
// release. This reads its report instead and fails only on what nobody has
// signed off. See tool/api/README.md.
import 'dart:convert';
import 'dart:io';

const _waiversFile = 'tool/api/semver_waivers.txt';

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('usage: dart run tool/api_semver_gate.dart <report.json>');
    exit(2);
  }
  final report =
      jsonDecode(File(args.single).readAsStringSync()) as Map<String, dynamic>;
  final waivers = _readWaivers();

  final changes = <_Change>[];
  void walk(Map<String, dynamic> node, String where) {
    final code = node['changeCode'] as String?;
    if (code != null) {
      changes.add(_Change(code, node['changeDescription'] as String, where));
    }
    final label = node['label'] as String?;
    final here = code == null && label != null && label != 'BREAKING CHANGES'
        ? label
        : where;
    for (final child in (node['children'] as List?) ?? const []) {
      walk(child as Map<String, dynamic>, here);
    }
  }

  final root = (report['report'] as Map<String, dynamic>)['breakingChanges'];
  walk(root as Map<String, dynamic>, '');

  final used = <String>{};
  final blocking = <_Change>[];
  for (final change in changes) {
    if (waivers.containsKey(change.key)) {
      used.add(change.key);
    } else {
      blocking.add(change);
    }
  }
  final stale = waivers.keys.where((k) => !used.contains(k)).toList();

  final version = report['version'] as Map<String, dynamic>;
  final out = StringBuffer()
    ..writeln('## API semver gate')
    ..writeln()
    ..writeln(
      'Against ${version['old']} on pub.dev: ${changes.length} breaking '
      'change(s), ${changes.length - blocking.length} waived, '
      '${blocking.length} not waived. dart-apitool alone would ask for '
      '${version['needed']}.',
    );
  if (blocking.isNotEmpty) {
    out
      ..writeln()
      ..writeln(
        'Not waived — restore the API, deprecate instead of removing, '
        'or add a reviewed line to $_waiversFile:',
      )
      ..writeln();
    for (final c in blocking) {
      out.writeln(
        '- `${c.code}` ${c.where.isEmpty ? '' : '${c.where}: '}'
        '${c.description}',
      );
    }
  }
  if (stale.isNotEmpty) {
    out
      ..writeln()
      ..writeln('Waivers that matched nothing (delete them):')
      ..writeln();
    for (final k in stale) {
      out.writeln('- `$k`');
    }
  }
  stdout.write(out);
  final summary = Platform.environment['GITHUB_STEP_SUMMARY'];
  if (summary != null && summary.isNotEmpty) {
    File(summary).writeAsStringSync(out.toString(), mode: FileMode.append);
  }
  exit(blocking.isEmpty ? 0 : 1);
}

/// Waiver key → reason. A key is `<code>|<description>`.
Map<String, String> _readWaivers() {
  final waivers = <String, String>{};
  for (final raw in File(_waiversFile).readAsLinesSync()) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final parts = line.split('|');
    if (parts.length < 3 || parts[2].trim().isEmpty) {
      stderr.writeln(
        '$_waiversFile: every waiver needs a code, a description '
        'and a reason: $line',
      );
      exit(2);
    }
    waivers['${parts[0].trim()}|${parts[1].trim()}'] = parts
        .sublist(2)
        .join('|');
  }
  return waivers;
}

class _Change {
  _Change(this.code, this.description, this.where);

  final String code;
  final String description;
  final String where;

  String get key => '$code|$description';
}
