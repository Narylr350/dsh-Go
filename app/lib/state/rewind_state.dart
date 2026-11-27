import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'connection_state.dart';

// 每个活跃连接只探测一次；没有插件或中继不支持 HTTP 路由时不显示入口。
final rewindAvailableProvider = FutureProvider.autoDispose<bool>((ref) async {
  final client = ref.watch(activeConnectionProvider.select((connection) => connection.value?.client));
  return client != null && await client.rewindAvailable();
});
