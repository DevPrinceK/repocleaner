# flutter_unused_finder

CLI tool to list:
- Dart files under `lib/` that are not referenced by any other `lib/` file (via `import`, `export`, or `part`).
- Flutter assets that are declared in `pubspec.yaml` (or under `assets/` if none declared) but never referenced anywhere in `lib/`.

## Install

Inside the tool directory:

```bash
dart pub get
```

Optionally activate globally (from this folder):

```bash
dart pub global activate --source path .
```

## Usage

Run from a Flutter project root:

```bash
dart run flutter_unused_finder -p .
```

Options:
- `-p, --project <path>`: Project root (default `.`)
- `--include-generated`: Include generated files such as `*.g.dart`
- `--exclude <glob>`: Exclude glob(s). Can be repeated.
- `--json`: Output JSON

Notes:
- A lib file is considered "used" if any other lib file references it via `import`, `export`, or `part` (relative or `package:<this_pkg>/...`). Entry points not imported by others will appear as unused by design.
- Asset references are detected by simple string matching of the full asset path. Dynamic or computed asset paths will not be detected.