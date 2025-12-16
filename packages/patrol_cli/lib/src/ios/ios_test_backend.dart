import 'dart:convert';
import 'dart:io' show Process;

import 'package:dispose_scope/dispose_scope.dart';
import 'package:file/file.dart';
import 'package:glob/glob.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' show join;
import 'package:patrol_cli/src/base/exceptions.dart';
import 'package:patrol_cli/src/base/logger.dart';
import 'package:patrol_cli/src/base/process.dart';
import 'package:patrol_cli/src/crossplatform/app_options.dart';
import 'package:patrol_cli/src/devices.dart';
import 'package:patrol_log/patrol_log.dart';
import 'package:platform/platform.dart';
import 'package:process/process.dart';

enum BuildMode {
  debug,
  profile,
  release;

  static const _defaultScheme = 'Runner';

  /// Name of this build mode in the Xcode Build Configuration format.
  ///
  /// Flutter build mode name starts with with a lowercase letter, for example
  /// `debug` or `release`.
  ///
  /// Xcode Build Configuration names starts with an uppercase letter, for
  /// example 'Debug' or 'Release'.
  String get xcodeName => name.replaceFirst(name[0], name[0].toUpperCase());

  // It's the same as xcodeName, but let's keep it for clarity.
  /// Name of this build mode as a part of Gradle task name.
  String get androidName => xcodeName;

  String createScheme(String? flavor) {
    if (flavor == null) {
      return _defaultScheme;
    }
    return flavor;
  }

  String createConfiguration(String? flavor) {
    if (flavor == null) {
      return xcodeName;
    }
    return '$xcodeName-$flavor';
  }
}

class IOSTestBackend {
  IOSTestBackend({
    required ProcessManager processManager,
    required Platform platform,
    required FileSystem fs,
    required Directory rootDirectory,
    required DisposeScope parentDisposeScope,
    required Logger logger,
  }) : _processManager = processManager,
       _platform = platform,
       _fs = fs,
       _rootDirectory = rootDirectory,
       _disposeScope = DisposeScope(),
       _logger = logger {
    _disposeScope.disposedBy(parentDisposeScope);
  }

  static const _xcodebuildInterrupted = -15;

  // Environment variable to configure max restart attempts in develop mode
  static const _envMaxRestartAttempts = 'PATROL_IOS_DEVELOP_MAX_RESTARTS';
  static const _defaultMaxRestartAttempts = 10;

  // Environment variable to configure initial backoff delay in milliseconds
  static const _envInitialBackoffMs = 'PATROL_IOS_DEVELOP_INITIAL_BACKOFF_MS';
  static const _defaultInitialBackoffMs = 2000;

  final ProcessManager _processManager;
  final Platform _platform;
  final FileSystem _fs;
  final Directory _rootDirectory;
  final DisposeScope _disposeScope;
  final Logger _logger;

  Future<void> build(IOSAppOptions options) async {
    await _disposeScope.run((scope) async {
      final subject = options.description;
      final task = _logger.task(
        'Building $subject (${options.flutter.buildMode.name})',
      );

      Process process;

      final isRealDevice = !options.simulator;
      final isReleaseMode = options.flutter.buildMode == BuildMode.release;
      if (isRealDevice && !isReleaseMode) {
        throwToolExit(
          'Running on physical iOS devices is possible only in release mode',
        );
      }

      // flutter build ios --config-only

      var flutterBuildKilled = false;
      process = await _processManager.start(
        options.toFlutterBuildInvocation(options.flutter.buildMode),
        runInShell: true,
      );
      scope.addDispose(() {
        process.kill();
        flutterBuildKilled = true; // `flutter build` has exit code 0 on SIGINT
      });
      process.listenStdOut((l) => _logger.info('\t$l')).disposedBy(scope);
      process.listenStdErr((l) => _logger.err('\t$l')).disposedBy(scope);
      var exitCode = await process.exitCode;
      final flutterCommand = options.flutter.command;
      if (exitCode != 0) {
        final cause = '`$flutterCommand build ios` exited with code $exitCode';
        task.fail('Failed to build $subject ($cause)');
        throwToolExit(cause);
      } else if (flutterBuildKilled) {
        final cause = '`$flutterCommand build ios` was interrupted';
        task.fail('Failed to build $subject ($cause)');
        throwToolInterrupted(cause);
      }

      // xcodebuild build-for-testing

      process =
          await _processManager.start(
              options.buildForTestingInvocation(),
              runInShell: true,
              workingDirectory: _rootDirectory.childDirectory('ios').path,
            )
            ..disposedBy(scope);
      process.listenStdOut((l) => _logger.detail('\t$l')).disposedBy(scope);
      process.listenStdErr((l) => _logger.err('\t$l')).disposedBy(scope);
      exitCode = await process.exitCode;
      if (exitCode == 0) {
        task.complete('Completed building $subject');
      } else if (exitCode == _xcodebuildInterrupted) {
        const cause = 'xcodebuild was interrupted';
        task.fail('Failed to execute tests of $subject ($cause)');
        throwToolInterrupted(cause);
      } else {
        final cause = 'xcodebuild exited with code $exitCode';
        task.fail('Failed to build $subject ($cause)');
        throwToolExit(cause);
      }
    });
  }

  /// Executes the tests of the given [options] on the given [device].
  ///
  /// [build] must be called before this method.
  ///
  /// If [interruptible] is true, then no exception is thrown on SIGINT. This is
  /// used for Hot Restart.
  Future<void> execute(
    IOSAppOptions options,
    Device device, {
    bool interruptible = false,
    required bool showFlutterLogs,
    required bool hideTestSteps,
    required bool clearTestSteps,
  }) async {
    await _disposeScope.run((scope) async {
      final patrolLogCommand = device.real
          ? ['idevicesyslog']
          : ['log', 'stream'];

      // Read patrol logs from log stream
      final processLogs =
          await _processManager.start(patrolLogCommand, runInShell: true)
            ..disposedBy(scope);

      final reportPath = resultBundlePath(
        timestamp: DateTime.now().millisecondsSinceEpoch,
      );

      final patrolLogReader =
          PatrolLogReader(
              listenStdOut: processLogs.listenStdOut,
              scope: scope,
              log: _logger.info,
              reportPath: reportPath,
              showFlutterLogs: showFlutterLogs,
              hideTestSteps: hideTestSteps,
              clearTestSteps: clearTestSteps,
            )
            ..listen()
            ..startTimer();

      final subject = '${options.description} on ${device.description}';
      final task = _logger.task('Running $subject');

      final sdkVersion = await getSdkVersion(real: device.real);
      final process =
          await _processManager.start(
              options.testWithoutBuildingInvocation(
                device,
                xcTestRunPath: await xcTestRunPath(
                  real: device.real,
                  scheme: options.scheme,
                  sdkVersion: sdkVersion,
                ),
                resultBundlePath: reportPath,
              ),
              runInShell: true,
              environment: {
                ..._platform.environment,
                'TEST_RUNNER_PATROL_TEST_PORT': options.testServerPort
                    .toString(),
                'TEST_RUNNER_PATROL_APP_PORT': options.appServerPort.toString(),
              },
              workingDirectory: _rootDirectory.childDirectory('ios').path,
            )
            ..disposedBy(_disposeScope);
      process.listenStdOut((l) => _logger.detail('\t$l')).disposedBy(scope);
      process.listenStdErr((l) => _logger.detail('\t$l')).disposedBy(scope);

      final exitCode = await process.exitCode;
      patrolLogReader.stopTimer();
      processLogs.kill();

      // Don't print the summary in develop
      if (!interruptible) {
        _logger.info(patrolLogReader.summary);
      }

      if (exitCode == 0) {
        task.complete('Completed executing $subject');
      } else if (exitCode != 0 && interruptible) {
        task.complete('App shut down on request');
      } else if (exitCode == _xcodebuildInterrupted) {
        const cause = 'xcodebuild was interrupted';
        task.fail('Failed to execute tests of $subject ($cause)');
        throwToolInterrupted(cause);
      } else {
        final cause = 'xcodebuild exited with code $exitCode';
        task.fail('Failed to execute tests of $subject ($cause)');
        throwToolExit(cause);
      }
    });
  }

  /// Executes tests in develop mode with automatic restart on failure.
  ///
  /// This method wraps [execute] and adds restart logic specifically for
  /// `patrol develop` mode. If the xcodebuild process exits with an error
  /// (such as "test runner timed out"), it will automatically restart the
  /// test runner to keep the develop session alive.
  ///
  /// The number of restart attempts and backoff delay can be configured via
  /// environment variables:
  /// - PATROL_IOS_DEVELOP_MAX_RESTARTS (default: 10)
  /// - PATROL_IOS_DEVELOP_INITIAL_BACKOFF_MS (default: 2000)
  Future<void> executeDevelop(
    IOSAppOptions options,
    Device device, {
    required bool showFlutterLogs,
    required bool hideTestSteps,
    required bool clearTestSteps,
  }) async {
    final maxRestarts = int.tryParse(
      _platform.environment[_envMaxRestartAttempts] ?? '',
    ) ?? _defaultMaxRestartAttempts;

    final initialBackoffMs = int.tryParse(
      _platform.environment[_envInitialBackoffMs] ?? '',
    ) ?? _defaultInitialBackoffMs;

    var attemptCount = 0;
    var currentBackoffMs = initialBackoffMs;

    while (attemptCount <= maxRestarts) {
      try {
        attemptCount++;
        
        if (attemptCount > 1) {
          _logger.warn(
            'Restarting iOS test runner (attempt $attemptCount/${maxRestarts + 1})',
          );
          _logger.detail('Waiting ${currentBackoffMs}ms before restart...');
          await Future<void>.delayed(Duration(milliseconds: currentBackoffMs));
          
          // Exponential backoff with cap at 30 seconds
          currentBackoffMs = (currentBackoffMs * 1.5).toInt();
          if (currentBackoffMs > 30000) {
            currentBackoffMs = 30000;
          }
        } else {
          _logger.detail(
            'Starting iOS test runner in develop mode '
            '(max restarts: $maxRestarts, initial backoff: ${initialBackoffMs}ms)',
          );
        }

        await _executeWithErrorCapture(
          options,
          device,
          showFlutterLogs: showFlutterLogs,
          hideTestSteps: hideTestSteps,
          clearTestSteps: clearTestSteps,
        );

        // If we reach here, the session completed successfully or was interrupted
        _logger.detail('iOS test runner session ended');
        break;
      } catch (e) {
        if (attemptCount > maxRestarts) {
          _logger.err(
            'iOS test runner failed after $attemptCount attempts. Giving up.',
          );
          _logger.err('Error: $e');
          rethrow;
        }
        
        _logger.warn(
          'iOS test runner exited unexpectedly: $e',
        );
        _logger.info(
          'Will attempt to restart (attempt ${attemptCount + 1}/${maxRestarts + 1})',
        );
      }
    }
  }

  /// Internal helper that executes tests and captures errors for restart logic.
  Future<void> _executeWithErrorCapture(
    IOSAppOptions options,
    Device device, {
    required bool showFlutterLogs,
    required bool hideTestSteps,
    required bool clearTestSteps,
  }) async {
    final errorMessages = <String>[];
    
    await _disposeScope.run((scope) async {
      final patrolLogCommand = device.real
          ? ['idevicesyslog']
          : ['log', 'stream'];

      // Read patrol logs from log stream
      final processLogs =
          await _processManager.start(patrolLogCommand, runInShell: true)
            ..disposedBy(scope);

      final reportPath = resultBundlePath(
        timestamp: DateTime.now().millisecondsSinceEpoch,
      );

      final patrolLogReader =
          PatrolLogReader(
              listenStdOut: processLogs.listenStdOut,
              scope: scope,
              log: _logger.info,
              reportPath: reportPath,
              showFlutterLogs: showFlutterLogs,
              hideTestSteps: hideTestSteps,
              clearTestSteps: clearTestSteps,
            )
            ..listen()
            ..startTimer();

      final subject = '${options.description} on ${device.description}';
      final task = _logger.task('Running $subject');

      final sdkVersion = await getSdkVersion(real: device.real);
      final process =
          await _processManager.start(
              options.testWithoutBuildingInvocation(
                device,
                xcTestRunPath: await xcTestRunPath(
                  real: device.real,
                  scheme: options.scheme,
                  sdkVersion: sdkVersion,
                ),
                resultBundlePath: reportPath,
              ),
              runInShell: true,
              environment: {
                ..._platform.environment,
                'TEST_RUNNER_PATROL_TEST_PORT': options.testServerPort
                    .toString(),
                'TEST_RUNNER_PATROL_APP_PORT': options.appServerPort.toString(),
              },
              workingDirectory: _rootDirectory.childDirectory('ios').path,
            )
            ..disposedBy(_disposeScope);
      
      // Capture stdout for error detection
      process.listenStdOut((l) {
        _logger.detail('\t$l');
        errorMessages.add(l);
      }).disposedBy(scope);
      
      // Capture stderr for error detection
      process.listenStdErr((l) {
        _logger.detail('\t$l');
        errorMessages.add(l);
      }).disposedBy(scope);

      final exitCode = await process.exitCode;
      patrolLogReader.stopTimer();
      processLogs.kill();

      // In develop mode, check if the runner timed out or failed
      if (exitCode != 0) {
        final errorOutput = errorMessages.join('\n');
        
        // Check for specific timeout errors that indicate restart should be attempted
        final isTimeoutError = errorOutput.contains('test runner timed out') ||
            errorOutput.contains('encountered an error') ||
            errorOutput.contains('Lost connection') ||
            errorOutput.contains('connection refused');
        
        if (isTimeoutError) {
          task.fail('iOS test runner timed out or lost connection');
          throw Exception(
            'iOS test runner timed out or lost connection (exit code: $exitCode)',
          );
        }
        
        // For other non-zero exit codes in develop mode, just complete
        task.complete('App shut down (exit code: $exitCode)');
      } else {
        task.complete('Completed executing $subject');
      }
    });
  }

  /// Uninstalls the app under test and the test runner from [device].
  ///
  /// [flavor] is required to infer the test runner bundle ID.
  Future<void> uninstall({
    required String appId,
    required String? flavor,
    required Device device,
  }) async {
    if (device.real) {
      // uninstall from iOS device
      await _processManager.run([
        'ideviceinstaller',
        ...['--udid', device.id],
        ...['--uninstall', appId],
      ], runInShell: true);
    } else {
      // uninstall from iOS simulator
      await _processManager.run([
        'xcrun',
        'simctl',
        'uninstall',
        device.id,
        appId,
      ], runInShell: true);
    }

    // See rationale: https://github.com/leancodepl/patrol/issues/1094
    final appIdWithoutFlavor = stripFlavorFromAppId(appId, flavor);
    final testApp = '$appIdWithoutFlavor.RunnerUITests.xctrunner';

    if (device.real) {
      // uninstall from iOS device
      await _processManager.run([
        'ideviceinstaller',
        ...['--udid', device.id],
        ...['--uninstall', testApp],
      ], runInShell: true);
    } else {
      // uninstall from iOS simulator
      await _processManager.run([
        'xcrun',
        'simctl',
        'uninstall',
        device.id,
        testApp,
      ], runInShell: true);
    }
  }

  /// Removes [flavor] from the end of [appId].
  ///
  /// Assumes that [appId] and [flavor] are separated by a dot.
  @visibleForTesting
  String stripFlavorFromAppId(String appId, String? flavor) {
    if (flavor == null) {
      return appId;
    }

    final idx = appId.indexOf('.$flavor');

    if (idx == -1) {
      return appId;
    }

    return appId.substring(0, idx);
  }

  // TODO: The path should be joined using platform-specific separator.
  // https://github.com/leancodepl/patrol/issues/1980
  Future<String> xcTestRunPath({
    required bool real,
    required String scheme,
    required String sdkVersion,
    bool absolutePath = true,
  }) async {
    final targetPlatform = real ? 'iphoneos' : 'iphonesimulator';
    final glob = Glob('${scheme}_*$targetPlatform$sdkVersion*.xctestrun');

    var root = 'build/ios_integ/Build/Products';
    if (absolutePath) {
      root = '${_rootDirectory.absolute.path}/$root';
    }
    _logger.detail('Looking for .xctestrun matching ${glob.pattern} at $root');
    final files = await glob.listFileSystem(_fs, root: root).toList();
    if (files.isEmpty) {
      final cause = 'No .xctestrun file was found at $root';
      throwToolExit(cause);
    }

    _logger.detail(
      'Found ${files.length} match(es), the first one will be used',
    );
    for (final file in files) {
      _logger.detail('Found ${file.absolute.path}');
    }

    if (absolutePath) {
      return files.first.absolute.path;
    }
    return files.first.path;
  }

  /// [timestamp] (milliseconds since UNIX epoch) is required for the generation
  /// of unique path for the results bundle.
  String resultBundlePath({required int timestamp}) {
    return _fs
        .file(
          join(_rootDirectory.path, 'build', 'ios_results_$timestamp.xcresult'),
        )
        .absolute
        .path;
  }

  Future<String> getSdkVersion({required bool real}) async {
    // See the versions yourself:
    //
    // $ xcodebuild -showsdks -json | jq '.[] | {sdkVersion, platform} | select(.platform=="iphoneos")'
    // $ xcodebuild -showsdks -json | jq '.[] | {sdkVersion, platform} | select(.platform=="iphonesimulator")'

    final processResult = await _processManager.run([
      'xcodebuild',
      '-showsdks',
      '-json',
    ], runInShell: true);

    String? sdkVersion;
    String? platform;
    final jsonOutput = jsonDecode(processResult.stdOut) as List<dynamic>;
    for (final sdkJson in jsonOutput) {
      final sdk = sdkJson as Map<String, dynamic>;
      if (real && sdk['platform'] == 'iphonesimulator') {
        sdkVersion = sdk['sdkVersion'] as String;
        platform = sdk['platform'] as String;
        break;
      }

      if (!real && sdk['platform'] == 'iphonesimulator') {
        sdkVersion = sdk['sdkVersion'] as String;
        platform = sdk['platform'] as String;
        break;
      }
    }

    if (sdkVersion == null) {
      throw Exception('xcodebuild: could not find SDK version');
    }

    _logger.detail('Assuming SDK version $sdkVersion for $platform');
    return sdkVersion;
  }

  Future<String> getInstalledAppsEnvVariable(String deviceId) async {
    final processResult = await _processManager.run([
      'xcrun',
      'simctl',
      'listapps',
      deviceId,
    ], runInShell: true);

    const lineSplitter = LineSplitter();
    final ids = lineSplitter
        .convert(processResult.stdOut)
        .where((line) => line.contains('CFBundleIdentifier ='))
        .map((e) => e.substring(e.indexOf('"') + 1, e.lastIndexOf('"')))
        .toList();

    return jsonEncode(ids);
  }
}
