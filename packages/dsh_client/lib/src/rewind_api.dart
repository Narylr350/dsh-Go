/// dsh-rewind-plugin 0.24.1's authenticated HTTP contract. The plugin, not
/// the client, owns cancellation, context replacement and append-only storage.
library;

import 'dart:convert';

import 'carrier.dart';
import 'errors.dart';
import 'session_api.dart';

class RewindPreview {
  const RewindPreview({required this.headSeq, required this.text, required this.hasAttachments});
  final int headSeq;
  final String text;
  final bool hasAttachments;
}

extension RewindActions on DshClient {
  /// Relay carriers do not expose arbitrary plugin HTTP routes.
  Future<bool> rewindAvailable() async {
    if (carrier is! DshHttpCarrier) return false;
    try {
      final response = await connection.get('/api/dsh-rewind/v1/health', timeout: const Duration(seconds: 3));
      if (response.statusCode != 200) return false;
      final body = jsonDecode(response.text);
      return body is Map && body['ok'] == true && body['value'] is Map && body['value']['contract'] == 1;
    } on DshException {
      return false;
    } on FormatException {
      return false;
    }
  }

  Future<RewindPreview> previewRewind(String sessionId, int seq) async {
    final value = await _rewindRequest('preview', {'sessionId': sessionId, 'seq': seq});
    final withdraw = value['withdraw'];
    if (value['headSeq'] is! int ||
        withdraw is! Map ||
        withdraw['text'] is! String ||
        withdraw['attachments'] is! List) {
      throw const DshProtocolException('Invalid rewind preview');
    }
    return RewindPreview(
      headSeq: value['headSeq'] as int,
      text: withdraw['text'] as String,
      hasAttachments: (withdraw['attachments'] as List).isNotEmpty,
    );
  }

  Future<void> commitRewind(String sessionId, int seq, int headSeq) async {
    // 不重试有副作用的请求；headSeq 由服务端核对，期间有新消息就拒绝提交。
    final value = await _rewindRequest('commit', {
      'sessionId': sessionId,
      'seq': seq,
      'headSeq': headSeq,
      'mode': 'conversation',
    });
    final conversation = value['conversation'];
    if (conversation is! Map || conversation['rewound'] != true) {
      throw const DshProtocolException('Rewind was not confirmed by the host');
    }
  }

  Future<Map<String, Object?>> _rewindRequest(String method, Map<String, Object?> body) async {
    if (carrier is! DshHttpCarrier) throw const DshProtocolException('Rewind requires an HTTP host connection');
    final response = await connection.postJson(
      '/api/dsh-rewind/v1/$method',
      body,
      timeout: const Duration(seconds: 30),
    );
    // 这是插件自己的 JSON 协议，不是 Typert 的 client-request RPC envelope。
    final decoded = jsonDecode(response.text);
    if (decoded is Map && decoded['ok'] == false) throw DshRemoteException.fromJson(decoded['error']);
    if (response.statusCode != 200) throw DshHttpException(response.statusCode, 'Rewind request failed');
    if (decoded is! Map || decoded['ok'] != true || decoded['value'] is! Map) {
      throw const DshProtocolException('Invalid rewind response');
    }
    return Map<String, Object?>.from(decoded['value'] as Map);
  }
}
