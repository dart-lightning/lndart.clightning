import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:cln_plugin/src/icln_plugin_base.dart';
import 'package:cln_plugin/src/json_rpc/error.dart';
import 'package:cln_plugin/src/json_rpc/request.dart';
import 'package:cln_plugin/src/json_rpc/response.dart';
import 'package:cln_plugin/src/rpc_method/builtin/get_manifest.dart';
import 'package:cln_plugin/src/rpc_method/builtin/init.dart';
import 'package:cln_plugin/src/rpc_method/rpc_command.dart';
import 'package:cln_plugin/src/rpc_method/types/option.dart';

/// UnixSocket plugin implementation is the default plugin API used to
/// develop custom plugin for core lightning in dart.
class Plugin implements CLNPlugin {
  /// All the rpc method that the plugin expose.
  HashMap<String, RPCCommand> rpcMethods = HashMap();

  /// All the rpc call where the plugin is subscribed.
  List<String> subscriptions = [];

  /// The option that the plugin use to configure itself
  /// from the user setting.
  Map<String, Option> options = {};

  /// All the hooks where the plugin is subscribed.
  Set<String> hooks = {};

  /// Featurebis that this plugin will enable when is running
  HashMap<String, Object> features = HashMap();

  /// Mark the plugin as dynamic means that can be ran when
  /// core lightning is already running, if false the plugin can
  /// not be run without stop core lightning
  bool dynamic;

  /// All the notification where the plugin is subscribed.
  HashMap<String, RPCCommand> notifications = HashMap();

  /// plugin configuration that contains all the information
  /// that core lightning send to us.
  Map<String, Object> configuration = {};

  Plugin({this.dynamic = false});

  @override
  void registerFeature({required String name, required String value}) {
    features[name] = value;
  }

  @override
  void registerOption(
      {required String name,
      required String type,
      required String def,
      required String description,
      required bool deprecated}) {
    options[name] = Option(
        name: name,
        type: type,
        def: def,
        description: description,
        deprecated: deprecated);
  }

  @override
  void registerRPCMethod(
      {required String name,
      required String usage,
      required String description,
      required Future<Map<String, Object>> Function(Plugin, Map<String, Object>)
          callback}) {
    rpcMethods[name] = RPCCommand(
        name: name, usage: usage, description: description, callback: callback);
  }

  @override
  void registerSubscriptions({required String event}) {
    subscriptions.add(event);
  }

  @override
  void registerHook({required String name}) {
    hooks.add(name);
  }

  @override
  void registerNotification(
      {required String event,
      required Future<Map<String, Object>> Function(Plugin, Map<String, Object>)
          onEvent}) {
    notifications["event"] =
        RPCCommand(name: "", usage: "", description: "", callback: onEvent);
  }

  /// get manifest method used to communicate the plugin configuration
  /// to core lightning.
  Future<Map<String, Object>> getManifest(
      Plugin plugin, Map<String, Object> request) {
    // TODO: add some unit test to check if the format it is correct!
    var response = HashMap<String, Object>();
    response["options"] =
        plugin.options.values.map((opt) => opt.toMap()).toList();
    response["rpcmethods"] = plugin.rpcMethods.values
        .where((rpc) => rpc.name != "init" && rpc.name != "getmanifest")
        .map((rpc) => rpc.toMap())
        .toList();
    response["subscriptions"] = plugin.subscriptions;
    response["hooks"] = plugin.hooks.toList();
    response["notifications"] = [];
    response["dynamic"] = plugin.dynamic;

    return Future.value(response);
  }

  /// init method used to answer to configure the plugin with the core lightning
  /// configuration.
  Future<Map<String, Object>> init(Plugin plugin, Map<String, Object> request) {
    // TODO: store the configuration inside the plugin (it is inside the request)
    var opts = request['options'] as Map;
    opts.forEach((optsName, optValue) => options[optsName]!.value = optValue);
    configuration = request['configuration'] as Map<String, Object>;
    // TODO: get the option value inside the request and assign it to the options in some way!
    return Future.value({});
  }

  // init plugin used to register the rpc method required by the plugin
  // life cycle
  void configurePlugin() {
    rpcMethods["getmanifest"] =
        GetManifest(callback: (Plugin plugin, Map<String, Object> request) {
      return getManifest(plugin, request);
    });
    rpcMethods["init"] = InitMethod(
        callback: (Plugin plugin, Map<String, Object> request) =>
            init(plugin, request));
  }

  Future<Map<String, Object>> _call(
      String name, Map<String, Object> request) async {
    if (rpcMethods.containsKey(name)) {
      var method = rpcMethods[name]!;
      return await method.call(this, request);
    }
    throw Exception("Method with name $name not found!");
  }

  void log({required String level, required String message}) {
    var result = HashMap<String, Object>();
    result["level"] = level;
    result["message"] = message;
    stdout.write(jsonEncode(Response(id: 40, result: result).toJson()));
  }

  @override
  getOpt({required String key}) {
    return options[key]?.value;
  }

  @override
  void start() async {
    configurePlugin();
    try {
      String? messageSocket;

      /// TODO move this in async way
      while ((messageSocket = stdin.readLineSync()) != null) {
        // Already checked is stdin is not null, why trim and check again??
        if (messageSocket!.trim().isEmpty) {
          continue;
        }
        var jsonRequest = Request.fromJson(jsonDecode(messageSocket));
        try {
          HashMap<String, Object> param;
          if (jsonRequest.params is Map) {
            param = HashMap<String, Object>.from(jsonRequest.params);
          } else {
            param = HashMap();
          }
          var result = await _call(jsonRequest.method, param);
          var response = Response(id: jsonRequest.id, result: result).toJson();
          stdout.write(jsonEncode(response));
        } catch (ex) {
          var response = Response(
                  id: jsonRequest.id,
                  error: Error(code: -1, message: ex.toString()))
              .toJson();
          stdout.write(jsonEncode(response));
        }
      }
    } catch (error, stacktrace) {
      stderr.write(stacktrace);
      stderr.write(error);
    }
  }
}
