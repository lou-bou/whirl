import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kit/kit.dart';

import 'store.dart';

/// Typed calls to the Whirl API (server/index.js). All go through kit's [ApiClient]: the
/// Cloudflare Access service token on every request, no redirects, failures classified.
class WhirlApi {
  WhirlApi(this._c);
  final ApiClient _c;

  /// There is no health route: the data itself proves the right server answered.
  static const healthPath = '/api/data';
  static bool isHealthy(dynamic json) => json is Map && json['projects'] is List && json['categories'] is List;

  Future<Json> data() async {
    final json = await _c.get('/api/data');
    if (!isHealthy(json)) {
      throw const ApiException(ApiFailure.badResponse, 'The server sent something unexpected.');
    }
    return Map<String, Object?>.from(json as Map);
  }

  /// Replays one queued change.
  Future<Object?> send(QueuedOp op) => switch (op.method) {
    'POST' => _c.post('/api${op.path}', body: op.body),
    'PATCH' => _c.patch('/api${op.path}', body: op.body),
    'DELETE' => _c.delete('/api${op.path}'),
    _ => throw ArgumentError(op.method),
  };

  Future<void> addCategory(String name) => _c.post('/api/categories', body: {'name': name});
  Future<void> renameCategory(String id, String name) => _c.patch('/api/categories/$id', body: {'name': name});
  Future<void> deleteCategory(String id) => _c.delete('/api/categories/$id');
}

final whirlApiProvider = Provider<WhirlApi>((ref) => WhirlApi(ref.watch(apiClientProvider)));

/// The server turned the request down for good (src/offline.js RejectedError): a 4xx other
/// than Cloudflare Access refusing the token. Anything else (no connection, a 5xx, Cloudflare's
/// error page, an answer that isn't the API) is worth trying again later.
bool isRefusal(ApiException e) =>
    e.kind != ApiFailure.accessDenied && e.kind != ApiFailure.notConfigured && e.status >= 400 && e.status < 500;
