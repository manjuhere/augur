# Changelog

## 7.0.0

### BREAKING CHANGES
- **Removed `Provider.of<T>()` static method**. Use `context.read<T>()` or `context.watch<T>()` instead.
- **`ChangeNotifierProvider` now requires a `create` parameter**. The `builder` parameter has been removed.
- **Removed `MultiProvider.builder`**. Use the standard `providers` list instead.

### New Features
- Added `context.select<T, R>()` for fine-grained rebuilds
- Improved error messages for missing providers

### Bug Fixes
- Fixed memory leak in `ProxyProvider`

## 6.1.0

### New Features
- Added `Provider.of<T>()` deprecation warning
- Performance improvements for large widget trees

### Bug Fixes
- Fixed issue with nested providers not updating correctly

## 6.0.5

### Bug Fixes
- Fixed null safety issue in `StreamProvider`
- Updated dependencies

## 6.0.0

### BREAKING CHANGES
- **Migrated to null safety**. All APIs now use non-nullable types by default.
- **Renamed `ValueListenableProvider` to `ValueListenableProvider`** (null-safe version)
- **`StreamProvider` now requires an `initialData` parameter**

### New Features
- Full null safety support
- New `context.read<T>()` convenience method
