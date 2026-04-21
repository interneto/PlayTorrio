import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/stream_source.dart';

/// Talks to nexvid.online's `/api/stream` endpoint to obtain direct
/// HLS / MP4 stream URLs from their server-scraped sources.
///
/// Provider catalogue (Greek alias -> source id, type, rank):
///   Alpha   febbox             source 1000   HLS + MP4 (direct shegu.net)
///   Gamma   02moviedownloader  source  900   multi-quality MP4 map
///
/// NOTE: `streammafia` was removed from nexvid.online on ~Nov 2024.
/// `pobreflix` was dropped on our side because its stream URLs route
/// through `oneproxy.1x2.space` → `nexvid.online/api/hls-proxy`, and
/// that proxy chain returns 403 unpredictably (Cloudflare / per-IP rate
/// limit). FebBox already covers every quality tier, so pobreflix was
/// just noise. Re-add it if nexvid ever exposes it as a direct URL.
///
/// The newer sources they added (zxcstream, cinesrc, vidking, vidfast,
/// videasy, vidsync, vidlink, peachify) are embed-only iframes and do
/// not work through `/api/stream` — they all return HTTP 400.
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
    ['02moviedownloader', 'NexVid Gamma (02movie)'],
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

    // Default playback headers (used when the upstream didn't supply any —
    // and when we route through NexVid's /api/hls-proxy, which enforces a
    // nexvid.online Referer server-side).
    final Map<String, String> nexvidProxyHeaders = {
      'Referer': '$_baseUrl/',
      'User-Agent': headers['User-Agent']!,
    };

    // ── type: 'hls' → single playlist URL, wrap via /api/hls-proxy ────
    if (type == 'hls') {
      final original = (data['playlist'] ?? data['url'] ?? '').toString();
      if (original.isEmpty) return null;
      final proxied = _wrapHlsProxy(original, upstreamHeaders);
      final src = StreamSource(
        url: proxied,
        title: '$label · HLS',
        type: 'video',
        headers: nexvidProxyHeaders,
      );
      return NexVidResult(
        sourceId: sourceId,
        primaryUrl: proxied,
        headers: nexvidProxyHeaders,
        streamSources: [src],
      );
    }

    // ── type: 'file' → Map<quality, {url, headers}> (direct upstream) ─
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
        final perQualityHeaders = _toStringMap((e.value as Map)['headers']);
        // Per-quality headers carry the exact UA the upstream expects
        // (e.g. 02moviedownloader requires a Chromium-on-Linux UA).
        // Fall back to the source-level upstream headers, then to ours.
        final effective = perQualityHeaders.isNotEmpty
            ? perQualityHeaders
            : (upstreamHeaders.isNotEmpty ? upstreamHeaders : nexvidProxyHeaders);
        return StreamSource(
          url: (e.value['url'] as String).toString(),
          title: '$label · ${e.key}p',
          type: 'video',
          headers: effective,
        );
      }).toList();
      return NexVidResult(
        sourceId: sourceId,
        primaryUrl: list.first.url,
        headers: list.first.headers ?? nexvidProxyHeaders,
        streamSources: list,
      );
    }

    // ── No `type` field → new FebBox shape: qualities is a List of
    //    { url, quality, label } with direct HLS URLs on hls.shegu.net.
    //    These don't need the nexvid hls-proxy — they're already signed.
    final rawQualities = data['qualities'];
    if (rawQualities is List && rawQualities.isNotEmpty) {
      final shegu = <StreamSource>[];
      // Direct shegu.net URLs — pass the upstream UA/Referer if provided,
      // otherwise send a Chrome-desktop UA (what the website uses).
      final directHeaders = upstreamHeaders.isNotEmpty
          ? upstreamHeaders
          : {
              'User-Agent': headers['User-Agent']!,
              'Referer': 'https://www.febbox.com/',
            };
      // Preserve API-provided order but boost 4K/2160 first, then numeric desc.
      int rankFor(String q) {
        final s = q.toLowerCase().trim();
        if (s == '4k' || s.contains('2160')) return 2160;
        if (s == '2k' || s.contains('1440')) return 1440;
        if (s.contains('1080')) return 1080;
        if (s.contains('720')) return 720;
        if (s.contains('480')) return 480;
        if (s.contains('360')) return 360;
        return int.tryParse(RegExp(r'\d+').stringMatch(s) ?? '') ?? 0;
      }
      final entries = rawQualities
          .whereType<Map>()
          .where((m) => (m['url'] ?? '').toString().isNotEmpty)
          .toList()
        ..sort((a, b) => rankFor(b['quality']?.toString() ?? '')
            .compareTo(rankFor(a['quality']?.toString() ?? '')));
      for (final q in entries) {
        final url = q['url'].toString();
        final quality = (q['quality'] ?? q['label'] ?? '').toString();
        shegu.add(StreamSource(
          url: url,
          title: quality.isEmpty ? label : '$label · $quality',
          type: 'video',
          headers: directHeaders,
        ));
      }
      if (shegu.isEmpty) return null;
      return NexVidResult(
        sourceId: sourceId,
        primaryUrl: shegu.first.url,
        headers: shegu.first.headers ?? nexvidProxyHeaders,
        streamSources: shegu,
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
