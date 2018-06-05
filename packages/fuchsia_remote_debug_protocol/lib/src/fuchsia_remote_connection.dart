// Copyright 2018 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:process/process.dart';

import 'common/logging.dart';
import 'common/network.dart';
import 'dart/dart_vm.dart';
import 'runners/ssh_command_runner.dart';

final String _ipv4Loopback = InternetAddress.LOOPBACK_IP_V4.address; // ignore: deprecated_member_use

final String _ipv6Loopback = InternetAddress.LOOPBACK_IP_V6.address; // ignore: deprecated_member_use

const ProcessManager _processManager = const LocalProcessManager();

const Duration _kIsolateFindTimeout = const Duration(minutes: 1);

const Duration _kVmPollInterval = const Duration(milliseconds: 1500);

final Logger _log = new Logger('FuchsiaRemoteConnection');

/// A function for forwarding ports on the local machine to a remote device.
///
/// Takes a remote `address`, the target device's port, and an optional
/// `interface` and `configFile`. The config file is used primarily for the
/// default SSH port forwarding configuration.
typedef Future<PortForwarder> PortForwardingFunction(
    String address, int remotePort,
    [String interface, String configFile]);

/// The function for forwarding the local machine's ports to a remote Fuchsia
/// device.
///
/// Can be overwritten in the event that a different method is required.
/// Defaults to using SSH port forwarding.
PortForwardingFunction fuchsiaPortForwardingFunction = _SshPortForwarder.start;

/// Sets [fuchsiaPortForwardingFunction] back to the default SSH port forwarding
/// implementation.
void restoreFuchsiaPortForwardingFunction() {
  fuchsiaPortForwardingFunction = _SshPortForwarder.start;
}

/// An enum specifying a Dart VM's state.
enum DartVmEventType {
  /// The Dart VM has started.
  started,

  /// The Dart VM has stopped.
  ///
  /// This can mean either the host machine cannot be connect to, the VM service
  /// has shut down cleanly, or the VM service has crashed.
  stopped,
}

/// An event regarding the Dart VM.
///
/// Specifies the type of the event (whether the VM has started or has stopped),
/// and contains the service port of the VM as well as a URI to connect to it.
class DartVmEvent {
  DartVmEvent._({this.eventType, this.servicePort, this.uri});

  /// The URI used to connect to the Dart VM.
  final Uri uri;

  /// The type of event regarding this instance of the Dart VM.
  final DartVmEventType eventType;

  /// The port on the host machine that the Dart VM service is/was running on.
  final int servicePort;
}

/// Manages a remote connection to a Fuchsia Device.
///
/// Provides affordances to observe and connect to Flutter views, isolates, and
/// perform actions on the Fuchsia device's various VM services.
///
/// Note that this class can be connected to several instances of the Fuchsia
/// device's Dart VM at any given time.
class FuchsiaRemoteConnection {
  FuchsiaRemoteConnection._(this._useIpV6Loopback, this._sshCommandRunner)
      : _pollDartVms = false;

  bool _pollDartVms;
  final List<PortForwarder> _forwardedVmServicePorts = <PortForwarder>[];
  final SshCommandRunner _sshCommandRunner;
  final bool _useIpV6Loopback;

  /// A mapping of Dart VM ports (as seen on the target machine), to
  /// [PortForwarder] instances mapping from the local machine to the target
  /// machine.
  final Map<int, PortForwarder> _dartVmPortMap = <int, PortForwarder>{};

  /// Tracks stale ports so as not to reconnect while polling.
  final Set<int> _stalePorts = new Set<int>();

  /// A broadcast stream that emits events relating to Dart VM's as they update.
  Stream<DartVmEvent> get onDartVmEvent => _onDartVmEvent;
  Stream<DartVmEvent> _onDartVmEvent;
  final StreamController<DartVmEvent> _dartVmEventController =
      new StreamController<DartVmEvent>();

  /// VM service cache to avoid repeating handshakes across function
  /// calls. Keys a forwarded port to a DartVm connection instance.
  final Map<int, DartVm> _dartVmCache = <int, DartVm>{};

  /// Same as [FuchsiaRemoteConnection.connect] albeit with a provided
  /// [SshCommandRunner] instance.
  @visibleForTesting
  static Future<FuchsiaRemoteConnection> connectWithSshCommandRunner(
      SshCommandRunner commandRunner) async {
    final FuchsiaRemoteConnection connection = new FuchsiaRemoteConnection._(
        isIpV6Address(commandRunner.address), commandRunner);
    await connection._forwardLocalPortsToDeviceServicePorts();

    Stream<DartVmEvent> dartVmStream() {
      Future<Null> listen() async {
        while (connection._pollDartVms) {
          await connection._pollVms();
          await new Future<Null>.delayed(_kVmPollInterval);
        }
        connection._dartVmEventController.close();
      }

      connection._dartVmEventController.onListen = listen;
      return connection._dartVmEventController.stream.asBroadcastStream();
    }

    connection._onDartVmEvent = dartVmStream();
    return connection;
  }

  /// Opens a connection to a Fuchsia device.
  ///
  /// Accepts an `address` to a Fuchsia device, and optionally a `sshConfigPath`
  /// in order to open the associated ssh_config for port forwarding.
  ///
  /// Will throw an [ArgumentError] if `address` is malformed.
  ///
  /// Once this function is called, the instance of [FuchsiaRemoteConnection]
  /// returned will keep all associated DartVM connections opened over the
  /// lifetime of the object.
  ///
  /// At its current state Dart VM connections will not be added or removed over
  /// the lifetime of this object.
  ///
  /// Throws an [ArgumentError] if the supplied `address` is not valid IPv6 or
  /// IPv4.
  ///
  /// Note that if `address` is ipv6 link local (usually starts with fe80::),
  /// then `interface` will probably need to be set in order to connect
  /// successfully (that being the outgoing interface of your machine, not the
  /// interface on the target machine).
  static Future<FuchsiaRemoteConnection> connect(
    String address, [
    String interface = '',
    String sshConfigPath,
  ]) async {
    return await FuchsiaRemoteConnection.connectWithSshCommandRunner(
      new SshCommandRunner(
        address: address,
        interface: interface,
        sshConfigPath: sshConfigPath,
      ),
    );
  }

  /// Closes all open connections.
  ///
  /// Any objects that this class returns (including any child objects from
  /// those objects) will subsequently have its connection closed as well, so
  /// behavior for them will be undefined.
  Future<Null> stop() async {
    for (PortForwarder pf in _forwardedVmServicePorts) {
      // Closes VM service first to ensure that the connection is closed cleanly
      // on the target before shutting down the forwarding itself.
      final DartVm vmService = _dartVmCache[pf.port];
      _dartVmCache[pf.port] = null;
      await vmService?.stop();
      await pf.stop();
    }
    for (PortForwarder pf in _dartVmPortMap.values) {
      final DartVm vmService = _dartVmCache[pf.port];
      _dartVmCache[pf.port] = null;
      await vmService?.stop();
      await pf.stop();
    }
    _dartVmCache.clear();
    _forwardedVmServicePorts.clear();
    _dartVmPortMap.clear();
    _pollDartVms = false;
  }

  /// Returns all Isolates running `main()` as matched by the [Pattern].
  ///
  /// In the current state this is not capable of listening for an
  /// Isolate to start up. The Isolate must already be running.
  Future<List<IsolateRef>> getMainIsolatesByPattern(
    Pattern pattern, [
    Duration timeout = _kIsolateFindTimeout,
  ]) async {
    if (_dartVmPortMap.isEmpty) {
      return null;
    }
    // Accumulate a list of eventual IsolateRef lists so that they can be loaded
    // simultaneously via Future.wait.
    final List<Future<List<IsolateRef>>> isolates =
        <Future<List<IsolateRef>>>[];
    for (PortForwarder fp in _dartVmPortMap.values) {
      final DartVm vmService = await _getDartVm(fp.port);
      isolates.add(vmService.getMainIsolatesByPattern(pattern));
    }
    final Completer<List<IsolateRef>> completer =
        new Completer<List<IsolateRef>>();
    final List<IsolateRef> result =
        await Future.wait(isolates).then((List<List<IsolateRef>> listOfLists) {
      final List<List<IsolateRef>> mutableListOfLists =
          new List<List<IsolateRef>>.from(listOfLists)
            ..retainWhere((List<IsolateRef> list) => list.isNotEmpty);
      // Folds the list of lists into one flat list.
      return mutableListOfLists.fold<List<IsolateRef>>(
        <IsolateRef>[],
        (List<IsolateRef> accumulator, List<IsolateRef> element) {
          accumulator.addAll(element);
          return accumulator;
        },
      );
    });

    // If no VM instance anywhere has this, it's possible it hasn't spun up
    // anywhere.
    //
    // For the time being one Flutter Isolate runs at a time in each VM, so for
    // now this will wait until the timer runs out or a new Dart VM starts that
    // contains the Isolate in question.
    //
    // TODO(awdavies): Set this up to handle multiple Isolates per Dart VM.
    if (result.isEmpty) {
      _log.fine('No instance of the Isolate found. Awaiting new VM startup');
      _onDartVmEvent.listen(
        (DartVmEvent event) async {
          if (event.eventType == DartVmEventType.started) {
            _log.fine('New VM found on port: ${event.servicePort}. Searching '
                'for Isolate: $pattern');
            final DartVm vmService = await _getDartVm(event.uri.port);
            final List<IsolateRef> result =
                await vmService.getMainIsolatesByPattern(pattern);
            if (result.isNotEmpty) {
              completer.complete(result);
            }
          }
        },
      );
    } else {
      completer.complete(result);
    }
    return completer.future.timeout(timeout);
  }

  /// Returns a list of [FlutterView] objects.
  ///
  /// This is run across all connected Dart VM connections that this class is
  /// managing.
  Future<List<FlutterView>> getFlutterViews() async {
    if (_dartVmPortMap.isEmpty) {
      return <FlutterView>[];
    }
    final List<List<FlutterView>> flutterViewLists =
        await _invokeForAllVms<List<FlutterView>>((DartVm vmService) async {
      return await vmService.getAllFlutterViews();
    });
    final List<FlutterView> results = flutterViewLists.fold<List<FlutterView>>(
        <FlutterView>[], (List<FlutterView> acc, List<FlutterView> element) {
      acc.addAll(element);
      return acc;
    });
    return new List<FlutterView>.unmodifiable(results);
  }

  // Calls all Dart VM's, returning a list of results.
  //
  // A side effect of this function is that internally tracked port forwarding
  // will be updated in the event that ports are found to be broken/stale: they
  // will be shut down and removed from tracking.
  Future<List<E>> _invokeForAllVms<E>(
    Future<E> vmFunction(DartVm vmService), [
    bool queueEvents = true,
  ]) async {
    final List<E> result = <E>[];

    // Helper function loop.
    Future<Null> shutDownPortForwarder(PortForwarder pf) async {
      await pf.stop();
      _stalePorts.add(pf.remotePort);
      if (queueEvents) {
        _dartVmEventController.add(new DartVmEvent._(
          eventType: DartVmEventType.stopped,
          servicePort: pf.remotePort,
          uri: _getDartVmUri(pf.port),
        ));
      }
    }

    for (PortForwarder pf in _dartVmPortMap.values) {
      // When raising an HttpException this means that there is no instance of
      // the Dart VM to communicate with.  The TimeoutException is raised when
      // the Dart VM instance is shut down in the middle of communicating.
      try {
        final DartVm service = await _getDartVm(pf.port);
        result.add(await vmFunction(service));
      } on HttpException {
        await shutDownPortForwarder(pf);
      } on TimeoutException {
        await shutDownPortForwarder(pf);
      }
    }
    _stalePorts.forEach(_dartVmPortMap.remove);
    return result;
  }

  Uri _getDartVmUri(int port) {
    // While the IPv4 loopback can be used for the initial port forwarding
    // (see [PortForwarder.start]), the address is actually bound to the IPv6
    // loopback device, so connecting to the IPv4 loopback would fail when the
    // target address is IPv6 link-local.
    final String addr = _useIpV6Loopback
        ? 'http://\[$_ipv6Loopback\]:$port'
        : 'http://$_ipv4Loopback:$port';
    final Uri uri = Uri.parse(addr);
    return uri;
  }

  Future<DartVm> _getDartVm(int port) async {
    if (!_dartVmCache.containsKey(port)) {
      final DartVm dartVm = await DartVm.connect(_getDartVmUri(port));
      _dartVmCache[port] = dartVm;
    }
    return _dartVmCache[port];
  }

  /// Checks for changes in the list of Dart VM instances.
  ///
  /// If there are new instances of the Dart VM, then connections will be
  /// attempted (after clearing out stale connections).
  Future<Null> _pollVms() async {
    await _checkPorts();
    final List<int> servicePorts = await getDeviceServicePorts();
    for (int servicePort in servicePorts) {
      if (!_stalePorts.contains(servicePort) &&
          !_dartVmPortMap.containsKey(servicePort)) {
        _dartVmPortMap[servicePort] = await fuchsiaPortForwardingFunction(
            _sshCommandRunner.address,
            servicePort,
            _sshCommandRunner.interface,
            _sshCommandRunner.sshConfigPath);

        _dartVmEventController.add(new DartVmEvent._(
          eventType: DartVmEventType.started,
          servicePort: servicePort,
          uri: _getDartVmUri(_dartVmPortMap[servicePort].port),
        ));
      }
    }
  }

  /// Runs a dummy heartbeat command on all Dart VM instances.
  ///
  /// Removes any failing ports from the cache.
  Future<Null> _checkPorts([bool queueEvents = true]) async {
    // Filters out stale ports after connecting. Ignores results.
    await _invokeForAllVms<Map<String, dynamic>>(
      (DartVm vmService) async {
        final Map<String, dynamic> res =
            await vmService.invokeRpc('getVersion');
        _log.fine('DartVM version check result: $res');
        return res;
      },
      queueEvents,
    );
  }

  /// Forwards a series of local device ports to the remote device.
  ///
  /// When this function is run, all existing forwarded ports and connections
  /// are reset by way of [stop].
  Future<Null> _forwardLocalPortsToDeviceServicePorts() async {
    await stop();
    final List<int> servicePorts = await getDeviceServicePorts();
    final List<PortForwarder> forwardedVmServicePorts =
        await Future.wait(servicePorts.map((int deviceServicePort) {
      return fuchsiaPortForwardingFunction(
          _sshCommandRunner.address,
          deviceServicePort,
          _sshCommandRunner.interface,
          _sshCommandRunner.sshConfigPath);
    }));

    for (PortForwarder pf in forwardedVmServicePorts) {
      // TODO(awdavies): Handle duplicates.
      _dartVmPortMap[pf.remotePort] = pf;
    }

    // Don't queue events, since this is the initial forwarding.
    await _checkPorts(false);

    _pollDartVms = true;
  }

  /// Gets the open Dart VM service ports on a remote Fuchsia device.
  ///
  /// The method attempts to get service ports through an SSH connection. Upon
  /// successfully getting the VM service ports, returns them as a list of
  /// integers. If an empty list is returned, then no Dart VM instances could be
  /// found. An exception is thrown in the event of an actual error when
  /// attempting to acquire the ports.
  Future<List<int>> getDeviceServicePorts() async {
    // TODO(awdavies): This is using a temporary workaround rather than a
    // well-defined service, and will be deprecated in the near future.
    final List<String> lsOutput =
        await _sshCommandRunner.run('ls /tmp/dart.services');
    final List<int> ports = <int>[];

    // The output of lsOutput is a list of available ports as the Fuchsia dart
    // service advertises. An example lsOutput would look like:
    //
    // [ '31782\n', '1234\n', '11967' ]
    for (String s in lsOutput) {
      final String trimmed = s.trim();
      final int lastSpace = trimmed.lastIndexOf(' ');
      final String lastWord = trimmed.substring(lastSpace + 1);
      if ((lastWord != '.') && (lastWord != '..')) {
        // ignore: deprecated_member_use
        final int value = int.parse(lastWord, onError: (_) => null);
        if (value != null) {
          ports.add(value);
        }
      }
    }
    return ports;
  }
}

/// Defines an interface for port forwarding.
///
/// When a port forwarder is initialized, it is intended to save a port through
/// which a connection is persisted along the lifetime of this object.
///
/// To shut down a port forwarder you must call the [stop] function.
abstract class PortForwarder {
  /// Determines the port which is being forwarded from the local machine.
  int get port;

  /// The destination port on the other end of the port forwarding tunnel.
  int get remotePort;

  /// Shuts down and cleans up port forwarding.
  Future<Null> stop();
}

/// Instances of this class represent a running SSH tunnel.
///
/// The SSH tunnel is from the host to a VM service running on a Fuchsia device.
class _SshPortForwarder implements PortForwarder {
  _SshPortForwarder._(
    this._remoteAddress,
    this._remotePort,
    this._localSocket,
    this._interface,
    this._sshConfigPath,
    this._ipV6,
  );

  final String _remoteAddress;
  final int _remotePort;
  final ServerSocket _localSocket;
  final String _sshConfigPath;
  final String _interface;
  final bool _ipV6;

  @override
  int get port => _localSocket.port;

  @override
  int get remotePort => _remotePort;

  /// Starts SSH forwarding through a subprocess, and returns an instance of
  /// [_SshPortForwarder].
  static Future<_SshPortForwarder> start(String address, int remotePort,
      [String interface, String sshConfigPath]) async {
    final bool isIpV6 = isIpV6Address(address);
    final ServerSocket localSocket = await _createLocalSocket();
    if (localSocket == null || localSocket.port == 0) {
      _log.warning('_SshPortForwarder failed to find a local port for '
          '$address:$remotePort');
      return null;
    }
    // TODO(awdavies): The square-bracket enclosure for using the IPv6 loopback
    // didn't appear to work, but when assigning to the IPv4 loopback device,
    // netstat shows that the local port is actually being used on the IPv6
    // loopback (::1). While this can be used for forwarding to the destination
    // IPv6 interface, it cannot be used to connect to a websocket.
    final String formattedForwardingUrl =
        '${localSocket.port}:$_ipv4Loopback:$remotePort';
    final List<String> command = <String>['ssh'];
    if (isIpV6) {
      command.add('-6');
    }
    if (sshConfigPath != null) {
      command.addAll(<String>['-F', sshConfigPath]);
    }
    final String targetAddress =
        isIpV6 && interface.isNotEmpty ? '$address%$interface' : address;
    const String dummyRemoteCommand = 'date';
    command.addAll(<String>[
      '-nNT',
      '-f',
      '-L',
      formattedForwardingUrl,
      targetAddress,
      dummyRemoteCommand,
    ]);
    _log.fine("_SshPortForwarder running '${command.join(' ')}'");
    // Must await for the port forwarding function to completer here, as
    // forwarding must be completed before surfacing VM events (as the user may
    // want to connect immediately after an event is surfaced).
    final ProcessResult processResult = await _processManager.run(command);
    _log.fine("'${command.join(' ')}' exited with exit code "
        '${processResult.exitCode}');
    if (processResult.exitCode != 0) {
      return null;
    }
    final _SshPortForwarder result = new _SshPortForwarder._(
        address, remotePort, localSocket, interface, sshConfigPath, isIpV6);
    _log.fine('Set up forwarding from ${localSocket.port} '
        'to $address port $remotePort');
    return result;
  }

  /// Kills the SSH forwarding command, then to ensure no ports are forwarded,
  /// runs the SSH 'cancel' command to shut down port forwarding completely.
  @override
  Future<Null> stop() async {
    // Cancel the forwarding request. See [start] for commentary about why this
    // uses the IPv4 loopback.
    final String formattedForwardingUrl =
        '${_localSocket.port}:$_ipv4Loopback:$_remotePort';
    final List<String> command = <String>['ssh'];
    final String targetAddress = _ipV6 && _interface.isNotEmpty
        ? '$_remoteAddress%$_interface'
        : _remoteAddress;
    if (_sshConfigPath != null) {
      command.addAll(<String>['-F', _sshConfigPath]);
    }
    command.addAll(<String>[
      '-O',
      'cancel',
      '-L',
      formattedForwardingUrl,
      targetAddress,
    ]);
    _log.fine(
        'Shutting down SSH forwarding with command: ${command.join(' ')}');
    final ProcessResult result = await _processManager.run(command);
    if (result.exitCode != 0) {
      _log.warning('Command failed:\nstdout: ${result.stdout}'
          '\nstderr: ${result.stderr}');
    }
    _localSocket.close();
  }

  /// Attempts to find an available port.
  ///
  /// If successful returns a valid [ServerSocket] (which must be disconnected
  /// later).
  static Future<ServerSocket> _createLocalSocket() async {
    ServerSocket s;
    try {
      s = await ServerSocket.bind(_ipv4Loopback, 0);
    } catch (e) {
      // Failures are signaled by a return value of 0 from this function.
      _log.warning('_createLocalSocket failed: $e');
      return null;
    }
    return s;
  }
}