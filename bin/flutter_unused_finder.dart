import 'dart:io';

import 'package:args/args.dart';
import 'package:flutter_unused_finder/src/analyzer.dart';

void main(List<String> arguments) async {
  final parser = ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show usage information')
    ..addOption('project', abbr: 'p', help: 'Path to the Flutter project root', defaultsTo: '.')
    ..addFlag('include-generated', help: 'Include generated files (e.g. *.g.dart) in reports', defaultsTo: false)
    ..addMultiOption('exclude', help: 'Glob(s) to exclude (relative to project root). Can be repeated.')
    ..addFlag('json', help: 'Output results as JSON', defaultsTo: false);

  final argResults = parser.parse(arguments);
  if (argResults['help'] == true) {
    stdout.writeln('Usage: flutter_unused_finder [options]');
    stdout.writeln(parser.usage);
    exit(0);
  }

  final projectPath = argResults['project'] as String;
  final includeGenerated = argResults['include-generated'] as bool;
  final excludes = (argResults['exclude'] as List<String>?) ?? const [];
  final asJson = argResults['json'] as bool;

  final projectDir = Directory(projectPath);
  if (!projectDir.existsSync()) {
    stderr.writeln('Project path not found: $projectPath');
    exit(2);
  }

  final analyzer = ProjectAnalyzer(
    projectRoot: projectDir,
    includeGenerated: includeGenerated,
    excludeGlobs: excludes,
  );

  final result = await analyzer.analyze();

  if (asJson) {
    stdout.writeln(result.toJsonString());
  } else {
    if (result.unusedLibFiles.isEmpty) {
      stdout.writeln('No unused lib files found.');
    } else {
      stdout.writeln('Unused lib files (${result.unusedLibFiles.length}):');
      for (final path in result.unusedLibFiles) {
        stdout.writeln('  - $path');
      }
    }

    stdout.writeln('');

    if (result.unusedAssets.isEmpty) {
      stdout.writeln('No unused assets found.');
    } else {
      stdout.writeln('Unused assets (${result.unusedAssets.length}):');
      for (final path in result.unusedAssets) {
        stdout.writeln('  - $path');
      }
    }
  }
}