import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/stream_source.dart';

/// Talks to nexvid.online's `/api/stream` endpoint to obtain direct
/// HLS / MP4 stream URLs from their server-scraped sources.
///
/// Provider catalogue (Greek alias -> source id, type, rank):
///   Alpha   febbox             source 1000   (requires FebBox cookie)
///   Beta    pobreflix          source  950   HLS
///   Gamma   02moviedownloader  source  900   multi-quality MP4 map
///   Delta   streammafia        source  850   HLS
///
/// Embed-only providers (Epsilon..Omega) are NOT handled here — they are
/// plain iframe URLs and belong in [StreamProviders].
class NexVidService {
  static const String _baseUrl = 'https://nexvid.online';
  static const Duration _timeout = Duration(seconds: 25);

  /// FebBox session cookie / token (required for the Alpha source).
  /// Provided by the user; embedded here as a personal credential.
  static const String febBoxToken =
      'eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJpYXQiOjE3NjE3NjM0MDEsIm5iZiI6MTc2MTc2MzQwMSwiZXhwIjoxNzkyODY3NDIxLCJkYXRhIjp7InVpZCI6MTEwMTg2NCwidG9rZW4iOiJlNWZmNmU0MjIxOTFlOTJiOWI3NDQyMGMyYWVlMGYxZCJ9fQ.K7JGiNOBSP1F2t9Ds0HuUgTpkEKO5YOapEgcD6eF_BI';

  /// Sources to try, in descending rank order.
  /// Each entry: (sourceId, displayName).
  static const List<List<String>> sources = [
    ['febbox', 'NexVid Alpha (FebBox)'],
    ['pobreflix', 'NexVid Beta (Pobreflix)'],
    ['02moviedownloader', 'NexVid Gamma (02movie)'],
    ['streammafia', 'NexVid Delta (StreamMafia)'],
  ];

  /// Result returned by [extract].
  ///
  /// [primaryUrl] is the URL the player should start on.
  /// [streamSources] is a list of every quality / language available
  /// (so the player's source picker can show them all).
  /// [headers] must be replayed on every segment fetch for HLS sources.
  Future<NexVidResult?> extract({
    required String tmdbId,
    required String title,
    required String year,
    required bool isMovie,
    int? season,
    int? episode,
  }) async {
    // Fire all sources in parallel so we get every working stream,
    // not just the first hit.
    final futures = sources.map((entry) {
      final id = entry[0];
      final label = entry[1];
      return _fetchSource(
        sourceId: id,
        label: label,
        tmdbId: tmdbId,
        title: title,
        year: year,
        isMovie: isMovie,
        season: season,
        episode: episode,
      ).catchError((Object e) {
        debugPrint('[NexVid] $id error: $e');
        return null;
      });
    }).toList();

    final results = await Future.wait(futures);

    final allSources = <StreamSource>[];
    String? primaryUrl;
    Map<String, String>? primaryHeaders;
    String? primarySourceId;

    // Preserve rank order (sources list is already in rank order).
    for (var i = 0; i < results.length; i++) {
      final r = results[i];
      if (r == null || r.streamSources.isEmpty) continue;
      allSources.addAll(r.streamSources);
      // First non-null result (highest rank) wins as the auto-play pick.
      if (primaryUrl == null) {
        primaryUrl = r.primaryUrl;
        primaryHeaders = r.headers;
        primarySourceId = r.sourceId;
      }
    }

    if (allSources.isEmpty || primaryUrl == null) return null;

    debugPrint(
      '[NexVid] Aggregated ${allSources.length} streams across '
      '${results.where((r) => r != null && r.streamSources.isNotEmpty).length} sources',
    );

    return NexVidResult(
      sourceId: primarySourceId!,
      primaryUrl: primaryUrl,
      headers: primaryHeaders!,
      streamSources: allSources,
    );
  }

  Future<NexVidResult?> _fetchSource({
    required String sourceId,
    required String label,
    required String tmdbId,
    required String title,
    required String year,
    required bool isMovie,
    int? season,
    int? episode,
  }) async {
    final params = <String, String>{
      'tmdbId': tmdbId,
      'mediaType': isMovie ? 'movie' : 'show',
      'title': title,
      'year': year,
      'source': sourceId,
    };
    if (!isMovie) {
      params['season'] = (season ?? 1).toString();
      params['episode'] = (episode ?? 1).toString();
    }
    if (sourceId == 'febbox') {
      params['febboxToken'] = febBoxToken;
    }

    final uri = Uri.parse(
      '$_baseUrl/api/stream',
    ).replace(queryParameters: params);

    final headers = <String, String>{
      'Accept': 'application/json, */*',
      'Referer': '$_baseUrl/',
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
      if (sourceId == 'febbox') 'x-febbox-cookie': febBoxToken,
    };

    debugPrint('[NexVid] GET $uri');
    final response = await http.get(uri, headers: headers).timeout(_timeout);
    if (response.statusCode != 200) {
      debugPrint('[NexVid] $sourceId HTTP ${response.statusCode}');
      return null;
    }

    final Map<String, dynamic> body;
    try {
      body = json.decode(response.body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }

    if (body['success'] != true || body['data'] is! Map) {
      debugPrint('[NexVid] $sourceId no success: ${response.body}');
      return null;
    }

    final data = body['data'] as Map<String, dynamic>;
    final type = data['type']?.toString() ?? '';
    final upstreamHeaders = _toStringMap(data['headers']);

    // Replay any upstream headers via NexVid's HLS proxy so segments work.
    Map<String, String> playbackHeaders = {
      'Referer': '$_baseUrl/',
      'User-Agent': headers['User-Agent']!,
    };

    if (type == 'hls') {
      final original = (data['playlist'] ?? data['url'] ?? '').toString();
      if (original.isEmpty) return null;
      final proxied = _wrapHlsProxy(original, upstreamHeaders);
      return NexVidResult(
        sourceId: sourceId,
        primaryUrl: proxied,
        headers: playbackHeaders,
        streamSources: [
          StreamSource(
            url: proxied,
            title: '$label · HLS',
            type: 'video',
          ),
        ],
      );
    }

    if (type == 'file') {
      final qualities = data['qualities'];
      if (qualities is! Map) return null;
      // Sort quality keys numerically descending (2160 -> 360).
      final entries = qualities.entries
          .where((e) => e.value is Map && (e.value['url'] ?? '').toString().isNotEmpty)
          .toList()
        ..sort((a, b) {
          final ai = int.tryParse(a.key.toString()) ?? 0;
          final bi = int.tryParse(b.key.toString()) ?? 0;
          return bi.compareTo(ai);
        });
      if (entries.isEmpty) return null;
      final list = entries.map((e) {
        return StreamSource(
          url: (e.value['url'] as String).toString(),
          title: '$label · ${e.key}p',
          type: 'video',
        );
      }).toList();
      return NexVidResult(
        sourceId: sourceId,
        primaryUrl: list.first.url,
        headers: playbackHeaders,
        streamSources: list,
      );
    }

    return null;
  }

  /// Wrap an HLS playlist URL through NexVid's `/api/hls-proxy` so the
  /// upstream Referer / UA / etc. are added to every segment fetch
  /// without us having to track them ourselves.
  String _wrapHlsProxy(String url, Map<String, String> upstreamHeaders) {
    final params = <String, String>{'url': url};
    if (upstreamHeaders.isNotEmpty) {
      params['headers'] = json.encode(upstreamHeaders);
    }
    return Uri.parse(
      '$_baseUrl/api/hls-proxy',
    ).replace(queryParameters: params).toString();
  }

  Map<String, String> _toStringMap(dynamic v) {
    if (v is! Map) return {};
    final out = <String, String>{};
    v.forEach((k, val) {
      if (val != null) out[k.toString()] = val.toString();
    });
    return out;
  }
}

class NexVidResult {
  final String sourceId;
  final String primaryUrl;
  final Map<String, String> headers;
  final List<StreamSource> streamSources;

  NexVidResult({
    required this.sourceId,
    required this.primaryUrl,
    required this.headers,
    required this.streamSources,
  });
}
