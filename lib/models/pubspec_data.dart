/// Data models for parsed pubspec.yaml and pubspec.lock data.

class PubspecData {
  const PubspecData({
    required this.name,
    this.version,
    this.description,
    required this.sdkConstraints,
    required this.dependencies,
    required this.devDependencies,
  });

  final String name;
  final String? version;
  final String? description;
  final SdkConstraints sdkConstraints;
  final Map<String, DependencyInfo> dependencies;
  final Map<String, DependencyInfo> devDependencies;

  Map<String, dynamic> toJson() => {
        'name': name,
        if (version != null) 'version': version,
        if (description != null) 'description': description,
        'sdkConstraints': sdkConstraints.toJson(),
        'dependencies':
            dependencies.map((key, value) => MapEntry(key, value.toJson())),
        'devDependencies':
            devDependencies.map((key, value) => MapEntry(key, value.toJson())),
      };
}

class SdkConstraints {
  const SdkConstraints({
    this.dartSdk,
    this.flutterSdk,
  });

  final String? dartSdk;
  final String? flutterSdk;

  Map<String, dynamic> toJson() => {
        if (dartSdk != null) 'dartSdk': dartSdk,
        if (flutterSdk != null) 'flutterSdk': flutterSdk,
      };
}

class DependencyInfo {
  const DependencyInfo({
    required this.name,
    this.versionConstraint,
    this.resolvedVersion,
    required this.source,
    this.repositoryUrl,
    this.isDev = false,
    this.isTransitive = false,
  });

  final String name;
  final String? versionConstraint;
  final String? resolvedVersion;
  final String source;
  final String? repositoryUrl;
  final bool isDev;
  final bool isTransitive;

  Map<String, dynamic> toJson() => {
        'name': name,
        if (versionConstraint != null) 'versionConstraint': versionConstraint,
        if (resolvedVersion != null) 'resolvedVersion': resolvedVersion,
        'source': source,
        if (repositoryUrl != null) 'repositoryUrl': repositoryUrl,
        'isDev': isDev,
        'isTransitive': isTransitive,
      };
}

class LockfileData {
  const LockfileData({
    required this.packages,
  });

  final Map<String, LockfilePackage> packages;

  Map<String, dynamic> toJson() => {
        'packages':
            packages.map((key, value) => MapEntry(key, value.toJson())),
      };
}

class LockfilePackage {
  const LockfilePackage({
    required this.name,
    required this.version,
    required this.source,
    this.description,
    required this.dependency,
  });

  final String name;
  final String version;
  final String source;
  final String? description;
  final Map<String, String> dependency;

  Map<String, dynamic> toJson() => {
        'name': name,
        'version': version,
        'source': source,
        if (description != null) 'description': description,
        'dependency': dependency,
      };
}
