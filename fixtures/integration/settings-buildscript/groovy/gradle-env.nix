# This file is generated by gradle2nix.
#
# Example usage (e.g. in default.nix):
#
#     with (import <nixpkgs> {});
#     let
#       buildGradle = callPackage ./gradle-env.nix {};
#     in
#       buildGradle {
#         envSpec = ./gradle-env.json;
#
#         src = ./.;
#
#         gradleFlags = [ "installDist" ];
#
#         installPhase = ''
#           mkdir -p $out
#           cp -r app/build/install/myproject $out
#         '';
#       }

{ stdenv, buildEnv, fetchurl, gradleGen, writeText, writeTextDir, callPackage }:

{ envSpec
, pname ? null
, version ? null
, enableParallelBuilding ? true
, gradleFlags ? [ "build" ]
, gradlePackage ? null
, enableDebug ? false
, ... } @ args:

let
  inherit (builtins)
    attrValues concatStringsSep filter fromJSON match replaceStrings sort;

  inherit (stdenv.lib)
    assertMsg concatMapStringsSep groupBy' hasSuffix last mapAttrs
    mapAttrsToList optionalString readFile removeSuffix unique versionAtLeast
    versionOlder;

  mkDep = depSpec: stdenv.mkDerivation {
    inherit (depSpec) name;

    src = fetchurl {
      inherit (depSpec) urls sha256;
    };

    phases = "installPhase";

    installPhase = ''
      mkdir -p $out/${depSpec.path}
      ln -s $src $out/${depSpec.path}/${depSpec.name}
    '';
  };

  mkModuleMetadata = deps:
    let
      ids = filter
        (id: id.type == "pom")
        (map (dep: dep.id) deps);

      modules = groupBy'
        (meta: id:
          let
            isNewer = versionOlder meta.latest id.version;
            isNewerRelease =
              !(hasSuffix "-SNAPSHOT" id.version) &&
              versionOlder meta.release id.version;
          in {
            groupId = id.group;
            artifactId = id.name;
            latest = if isNewer then id.version else meta.latest;
            release = if isNewerRelease then id.version else meta.release;
            versions = meta.versions ++ [id.version];
          }
        )
        {
          latest = "";
          release = "";
          versions = [];
        }
        (id: "${replaceStrings ["."] ["/"] id.group}/${id.name}/maven-metadata.xml")
        ids;

    in
      attrValues (mapAttrs (path: meta:
        let
          versions' = sort versionOlder (unique meta.versions);
        in
          with meta; writeTextDir path ''
            <?xml version="1.0" encoding="UTF-8"?>
            <metadata modelVersion="1.1">
              <groupId>${groupId}</groupId>
              <artifactId>${artifactId}</artifactId>
              <versioning>
                ${optionalString (latest != "") "<latest>${latest}</latest>"}
                ${optionalString (release != "") "<release>${release}</release>"}
                <versions>
                  ${concatMapStringsSep "\n    " (v: "<version>${v}</version>") versions'}
                </versions>
              </versioning>
            </metadata>
          ''
      ) modules);

  mkSnapshotMetadata = deps:
    let
      snapshotDeps = filter (dep: dep ? build && dep ? timestamp) deps;

      modules = groupBy'
        (meta: dep:
          let
            id = dep.id;
            isNewer = dep.build > meta.buildNumber;
            # Timestamp values can be bogus, e.g. jitpack.io
            updated = if (match "[0-9]{8}\.[0-9]{6}" dep.timestamp) != null
                      then replaceStrings ["."] [""] dep.timestamp
                      else "";
          in {
            groupId = id.group;
            artifactId = id.name;
            version = id.version;
            timestamp = if isNewer then dep.timestamp else meta.timestamp;
            buildNumber = if isNewer then dep.build else meta.buildNumber;
            lastUpdated = if isNewer then updated else meta.lastUpdated;
            versions = meta.versions or [] ++ [{
              classifier = id.classifier or "";
              extension = id.extension;
              value = "${removeSuffix "-SNAPSHOT" id.version}-${dep.timestamp}-${toString dep.build}";
              updated = updated;
            }];
          }
        )
        {
          timestamp = "";
          buildNumber = -1;
          lastUpdated = "";
        }
        (dep: "${replaceStrings ["."] ["/"] dep.id.group}/${dep.id.name}/${dep.id.version}/maven-metadata.xml")
        snapshotDeps;

      mkSnapshotVersion = version: ''
        <snapshotVersion>
          ${optionalString (version.classifier != "") "<classifier>${version.classifier}</classifier>"}
          <extension>${version.extension}</extension>
          <value>${version.value}</value>
          ${optionalString (version.updated != "") "<updated>${version.updated}</updated>"}
        </snapshotVersion>
      '';

    in
      attrValues (mapAttrs (path: meta:
        with meta; writeTextDir path ''
          <?xml version="1.0" encoding="UTF-8"?>
          <metadata modelVersion="1.1">
            <groupId>${groupId}</groupId>
            <artifactId>${artifactId}</artifactId>
            <version>${version}</version>
            <versioning>
              <snapshot>
                ${optionalString (timestamp != "") "<timestamp>${timestamp}</timestamp>"}
                ${optionalString (buildNumber != -1) "<buildNumber>${toString buildNumber}</buildNumber>"}
              </snapshot>
              ${optionalString (lastUpdated != "") "<lastUpdated>${lastUpdated}</lastUpdated>"}
              <snapshotVersions>
                ${concatMapStringsSep "\n    " mkSnapshotVersion versions}
              </snapshotVersions>
            </versioning>
          </metadata>
        ''
      ) modules);

  mkRepo = project: type: deps: buildEnv {
    name = "${project}-gradle-${type}-env";
    paths = map mkDep deps ++ mkModuleMetadata deps ++ mkSnapshotMetadata deps;
  };

  mkInitScript = projectSpec: gradle:
    let
      repos = mapAttrs (mkRepo projectSpec.name) projectSpec.dependencies;
      hasDependencies = mapAttrs (type: deps: deps != []) projectSpec.dependencies;
    in
      assert (assertMsg (hasDependencies.settings -> versionAtLeast gradle.version "6.0") ''
        Project `${projectSpec.name}' has settings script dependencies, such as settings
        plugins, which are not supported by gradle2nix for Gradle versions prior to 6.0.

        Potential remedies:
        - Pass `--gradle-version=<version>' to the gradle2nix command.
        - Patch the `settings.gradle[.kts]' file to remove script dependencies.
      '');

      writeText "init.gradle" ''
        static def offlineRepo(RepositoryHandler repositories, String env, String path) {
            repositories.clear()
            repositories.maven {
                name "Nix''${env.capitalize()}MavenOffline"
                url path
                metadataSources {
                    it.gradleMetadata()
                    it.mavenPom()
                    it.artifact()
                }
            }
            repositories.ivy {
                name "Nix''${env.capitalize()}IvyOffline"
                url path
                layout "maven"
                metadataSources {
                    it.gradleMetadata()
                    it.ivyDescriptor()
                    it.artifact()
                }
            }
        }

        ${optionalString (hasDependencies.settings && (versionAtLeast gradle.version "6.0")) ''
          gradle.beforeSettings {
              offlineRepo(it.buildscript.repositories, "settings", "${repos.settings}")
          }
        ''}

        ${optionalString (hasDependencies.plugin) ''
          gradle.settingsEvaluated {
              offlineRepo(it.pluginManagement.repositories, "plugin", "${repos.plugin}")
          }
        ''}

        ${optionalString (hasDependencies.buildscript) ''
          gradle.projectsLoaded {
              allprojects {
                  buildscript {
                      offlineRepo(repositories, "buildscript", "${repos.buildscript}")
                  }
              }
          }
        ''}

        ${optionalString (hasDependencies.project) ''
          gradle.projectsLoaded {
              allprojects {
                  offlineRepo(repositories, "project", "${repos.project}")
              }
          }
        ''}
      '';

  mkGradle = gradleSpec:
    callPackage (gradleGen { inherit (gradleSpec) nativeVersion version sha256; }) { };

  mkProjectEnv = projectSpec: rec {
    inherit (projectSpec) name path version;
    gradle = args.gradlePackage or mkGradle projectSpec.gradle;
    initScript = mkInitScript projectSpec gradle;
  };

  gradleEnv = mapAttrs
    (_: p: mkProjectEnv p)
    (fromJSON (readFile envSpec));

  projectEnv = gradleEnv."";
  pname = args.pname or projectEnv.name;
  version = args.version or projectEnv.version;

  buildProject = env: flags: ''
    gradle --offline --no-daemon --no-build-cache \
      --info --full-stacktrace --warning-mode=all \
      ${optionalString enableParallelBuilding "--parallel"} \
      ${optionalString enableDebug "-Dorg.gradle.debug=true"} \
      --init-script ${env.initScript} \
      ${optionalString (env.path != "") ''-p "${env.path}"''} \
      ${concatStringsSep " " flags}
  '';

  buildIncludedProjects =
    concatStringsSep "\n" (mapAttrsToList
      (_: env: buildProject env [ "build" ])
      (removeAttrs gradleEnv [ "" ]));

  buildRootProject = buildProject projectEnv gradleFlags;

in stdenv.mkDerivation (args // {

  inherit pname version;

  nativeBuildInputs = (args.nativeBuildInputs or []) ++ [ projectEnv.gradle ];

  buildPhase = args.buildPhase or ''
    runHook preBuild

    (
    set -x

    # use the init script here
    TMPHOME=$(mktemp -d)
    mkdir -p $TMPHOME/init.d
    cp ${projectEnv.initScript} $TMPHOME/init.d

    export "GRADLE_USER_HOME=$TMPHOME"
    ${buildIncludedProjects}
    ${buildRootProject}
    )

    runHook postBuild
  '';

  dontStrip = true;
})
