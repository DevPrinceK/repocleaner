import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

class AnalysisResult {
  AnalysisResult({required this.unusedLibFiles, required this.unusedAssets});

  final List<String> unusedLibFiles;
  final List<String> unusedAssets;

  String toJsonString() {
    return const JsonEncoder.withIndent('  ').convert({
      'unusedLibFiles': unusedLibFiles,
      'unusedAssets': unusedAssets,
    });
  }
}

class ProjectAnalyzer {
  ProjectAnalyzer({
    required this.projectRoot,
    required this.includeGenerated,
    required this.excludeGlobs,
  });

  final Directory projectRoot;
  final bool includeGenerated;
  final List<String> excludeGlobs;

  Future<AnalysisResult> analyze() async {
    final libDir = Directory(p.join(projectRoot.path, 'lib'));
    if (!libDir.existsSync()) {
      return AnalysisResult(unusedLibFiles: const [], unusedAssets: const []);
    }

    final pubspecFile = File(p.join(projectRoot.path, 'pubspec.yaml'));
    final pubspec = pubspecFile.existsSync() ? loadYaml(pubspecFile.readAsStringSync()) as YamlMap : YamlMap();
    final packageName = pubspec['name']?.toString();

    final allLibFiles = _listFiles(libDir, (f) => f.path.endsWith('.dart'));

    final filteredLibFiles = allLibFiles.where((f) => _includeFile(f)).toList();
    final libPaths = filteredLibFiles.map((f) => p.normalize(p.relative(f.path, from: projectRoot.path))).toSet();

    final importsMap = <String, Set<String>>{}; // file -> referenced lib file paths (normalized, relative to project root)

    for (final file in filteredLibFiles) {
      final content = file.readAsStringSync();
      final references = _extractLibReferences(
        content: content,
        filePath: p.relative(file.path, from: projectRoot.path),
        packageName: packageName,
      );
      importsMap[p.normalize(p.relative(file.path, from: projectRoot.path))] = references
          .where((r) => libPaths.contains(r))
          .toSet();
    }

    // Reverse usage: which files are referenced by others
    final referencedByOthers = <String, int>{};
    for (final libPath in libPaths) {
      referencedByOthers[libPath] = 0;
    }
    importsMap.forEach((from, tos) {
      for (final to in tos) {
        referencedByOthers[to] = (referencedByOthers[to] ?? 0) + 1;
      }
    });

    final unusedLibFiles = referencedByOthers.entries
        .where((e) => e.value == 0)
        .map((e) => e.key)
        .toList()
      ..sort();

    // Assets
    final declaredAssets = _collectDeclaredAssets(pubspec);
    final assetsToScan = declaredAssets.isNotEmpty
        ? declaredAssets
        : _fallbackAssets();

    final libContents = filteredLibFiles.map((f) => f.readAsStringSync()).join('\n');
    final usedAssets = <String>{};
    for (final asset in assetsToScan) {
      // Look for exact path occurrence with forward slashes
      if (libContents.contains(asset)) {
        usedAssets.add(asset);
      }
    }

    final unusedAssets = assetsToScan.where((a) => !usedAssets.contains(a)).toList()..sort();

    return AnalysisResult(unusedLibFiles: unusedLibFiles, unusedAssets: unusedAssets);
  }

  bool _includeFile(FileSystemEntity fse) {
    if (fse is! File) return false;
    final rel = p.relative(fse.path, from: projectRoot.path);

    // Exclude by glob(s)
    for (final glob in excludeGlobs) {
      if (_matchesGlob(rel, glob)) return false;
    }

    if (!includeGenerated) {
      final base = p.basename(rel);
      if (base.endsWith('.g.dart') ||
          base.endsWith('.freezed.dart') ||
          base.endsWith('.gr.dart') ||
          base.endsWith('.gen.dart') ||
          base.endsWith('.config.dart')) {
        return false;
      }
    }
    return true;
  }

  Set<String> _extractLibReferences({
    required String content,
    required String filePath,
    required String? packageName,
  }) {
    final references = <String>{};
    final importExportPart = RegExp(r'''^\s*(import|export|part)\s+["']([^"']+)["'];?''', multiLine: true);
    for (final m in importExportPart.allMatches(content)) {
      final kind = m.group(1)!;
      final uri = m.group(2)!;
      if (uri.startsWith('dart:')) continue;
      if (uri.startsWith('package:')) {
        final pkgAndPath = uri.substring('package:'.length);
        final firstSlash = pkgAndPath.indexOf('/');
        if (firstSlash <= 0) continue;
        final pkg = pkgAndPath.substring(0, firstSlash);
        final rest = pkgAndPath.substring(firstSlash + 1);
        if (packageName != null && pkg == packageName) {
          references.add(p.normalize(p.join('lib', rest)));
        }
        continue;
      }
      if (uri.startsWith('file://')) {
        // Not typical; ignore
        continue;
      }
      // Relative to current file directory
      final baseDir = p.dirname(filePath);
      final resolved = p.normalize(p.join(baseDir, uri));
      references.add(resolved);
    }

    return references;
  }

  List<File> _listFiles(Directory dir, bool Function(File) where) {
    final result = <File>[];
    final lister = dir.listSync(recursive: true, followLinks: false);
    for (final entity in lister) {
      if (entity is File) {
        if (where(entity)) result.add(entity);
      }
    }
    return result;
  }

  List<String> _collectDeclaredAssets(YamlMap pubspec) {
    final flutter = pubspec['flutter'];
    if (flutter is! YamlMap) return const [];
    final assets = flutter['assets'];
    if (assets is! YamlList) return const [];

    final collected = <String>[];
    for (final entry in assets) {
      if (entry is! String) continue;
      final normalized = p.normalize(entry);
      final abs = p.join(projectRoot.path, normalized);
      final entity = FileSystemEntity.typeSync(abs);
      if (entity == FileSystemEntityType.directory) {
        // Recurse directory and collect all files
        final dir = Directory(abs);
        if (!dir.existsSync()) continue;
        final files = dir
            .listSync(recursive: true)
            .whereType<File>()
            .map((f) => p.normalize(p.relative(f.path, from: projectRoot.path)))
            .toList();
        collected.addAll(files);
      } else if (entity == FileSystemEntityType.file) {
        collected.add(p.normalize(p.relative(abs, from: projectRoot.path)));
      } else {
        // If path does not exist but is a directory-like path ending with '/'
        if (normalized.endsWith('/')) {
          final maybeDir = Directory(abs);
          if (maybeDir.existsSync()) {
            final files = maybeDir
                .listSync(recursive: true)
                .whereType<File>()
                .map((f) => p.normalize(p.relative(f.path, from: projectRoot.path)))
                .toList();
            collected.addAll(files);
          }
        }
      }
    }

    // Keep only files under assets-like folders by convention
    return collected
        .where((pRel) => !_isHiddenPath(pRel))
        .toSet()
        .toList();
  }

  List<String> _fallbackAssets() {
    final assetsDir = Directory(p.join(projectRoot.path, 'assets'));
    if (!assetsDir.existsSync()) return const [];
    final files = assetsDir
        .listSync(recursive: true)
        .whereType<File>()
        .map((f) => p.normalize(p.relative(f.path, from: projectRoot.path)))
        .where((rel) => !_isHiddenPath(rel))
        .toList();
    return files;
  }

  bool _matchesGlob(String path, String glob) {
    // Very small glob: supports **, *, and ?
    final regex = _globToRegExp(glob);
    return RegExp(regex).hasMatch(path);
  }

  String _globToRegExp(String pattern) {
    // Simple and safe conversion supporting **, *, and ?
    final escaped = pattern.replaceAllMapped(
      RegExp(r'([.\\+\^\$\{\}\(\)\|\[\]])'),
      (m) => '\\${m[1]}',
    );
    var s = escaped.replaceAll('**', '__DOUBLE_STAR__');
    s = s.replaceAll('*', '[^/]*');
    s = s.replaceAll('__DOUBLE_STAR__', '.*');
    s = s.replaceAll('?', '.');
    return '^' + s + r'$';
  }

  // _simpleGlobToRegExp no longer needed; using _globToRegExp
  // kept intentionally minimal
  
  bool _isHiddenPath(String rel) {
    final parts = p.split(rel);
    return parts.any((part) => part.startsWith('.'));
  }
}