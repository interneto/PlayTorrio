import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../utils/episode_matcher.dart';

class DebridFile {
  final String filename;
  final int filesize;
  final String downloadUrl;

  DebridFile({required this.filename, required this.filesize, required this.downloadUrl});
}

class DebridApi {
  static final DebridApi _instance = DebridApi._internal();
  factory DebridApi() => _instance;
  DebridApi._internal();

  // Use EncryptedSharedPreferences on Android. The default flutter_secure_storage
  // backend on Android stores data with a Keystore-wrapped key that can become
  // unreadable across app restarts (BadPaddingException / null reads), which
  // causes saved tokens to "disappear" until the user logs in again. The
  // EncryptedSharedPreferences backend is the recommended, more reliable option.
  static const _aOptions = AndroidOptions(encryptedSharedPreferences: true);
  final _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  Future<String?> _safeRead(String key) async {
    try {
      return await _storage.read(key: key, aOptions: _aOptions);
    } catch (_) {
      try {
        await _storage.delete(key: key, aOptions: _aOptions);
      } catch (_) {}
      return null;
    }
  }

  // --- Real-Debrid (private API token) ---
  //
  // RD exposes a personal, long-lived API token at
  //   https://real-debrid.com/apitoken
  // which is used directly as `Authorization: Bearer <token>`. This avoids the
  // OAuth device flow (and its 1h access-token expiry) entirely, so the login
  // never silently disappears across restarts.

  static const String _rdTokenKey = 'rd_access_token';

  Future<void> saveRDApiKey(String key) async {
    final trimmed = key.trim();
    if (trimmed.isEmpty) {
      await logoutRD();
      return;
    }
    await _storage.write(key: _rdTokenKey, value: trimmed, aOptions: _aOptions);
  }

  Future<String?> getRDAccessToken() async {
    return await _safeRead(_rdTokenKey);
  }

  /// Verifies the stored token by hitting RD's `/user` endpoint.
  /// Returns the user JSON on success, or null on failure.
  Future<Map<String, dynamic>?> verifyRDApiKey(String key) async {
    final trimmed = key.trim();
    if (trimmed.isEmpty) return null;
    try {
      final res = await http.get(
        Uri.parse('https://api.real-debrid.com/rest/1.0/user'),
        headers: {'Authorization': 'Bearer $trimmed'},
      );
      if (res.statusCode == 200) {
        return json.decode(res.body) as Map<String, dynamic>;
      }
    } catch (_) {}
    return null;
  }

  Future<void> logoutRD() async {
    // Clean up the current key plus any leftovers from the old OAuth flow so
    // upgrading users don't end up with stale credentials.
    for (final key in [
      _rdTokenKey,
      'rd_refresh_token',
      'rd_token_expiry',
      'rd_client_id',
      'rd_client_secret',
    ]) {
      try {
        await _storage.delete(key: key, aOptions: _aOptions);
      } catch (_) {}
    }
  }

  // --- Real-Debrid Flow ---

  /// Adds [magnet] to Real-Debrid, picks the file for the requested
  /// [season]/[episode] (or the largest video for movies / when SE is null),
  /// and unrestricts ONLY that single file.
  ///
  /// Returns a single-element list — the caller should just use
  /// `files.first.downloadUrl`. The `match.first.downloadUrl` /
  /// `files.first.downloadUrl` patterns in older call sites still work
  /// because the only file in the list is the right one.
  Future<List<DebridFile>> resolveRealDebrid(
    String magnet, {
    int? season,
    int? episode,
  }) async {
    final token = await getRDAccessToken();
    if (token == null) throw Exception("Real-Debrid not logged in");

    final headers = {'Authorization': 'Bearer $token'};

    // 1. Add the magnet.
    final addRes = await http.post(
      Uri.parse('https://api.real-debrid.com/rest/1.0/torrents/addMagnet'),
      headers: headers,
      body: {'magnet': magnet},
    );
    if (addRes.statusCode != 201) {
      throw Exception("Failed to add magnet to RD: ${addRes.body}");
    }
    final torrentId = json.decode(addRes.body)['id'] as String;

    // 2. Wait for the file list to be available, then pick the file we want.
    Map<String, dynamic>? info;
    List<dynamic>? rdFiles;
    int attempts = 0;
    while (attempts < 20) {
      final infoRes = await http.get(
        Uri.parse('https://api.real-debrid.com/rest/1.0/torrents/info/$torrentId'),
        headers: headers,
      );
      info = json.decode(infoRes.body) as Map<String, dynamic>;
      final status = info['status'] as String?;
      if (status == 'magnet_error' || status == 'error' || status == 'dead' ||
          status == 'virus') {
        throw Exception("RD rejected magnet (status: $status)");
      }
      rdFiles = (info['files'] as List?) ?? const [];
      if (rdFiles.isNotEmpty) break;
      await Future.delayed(const Duration(seconds: 2));
      attempts++;
    }
    if (rdFiles == null || rdFiles.isEmpty) {
      throw Exception("RD never returned a file list");
    }

    // 3. Pick the file we actually want and select ONLY that one. This
    //    speeds up the "downloaded" status (RD doesn't have to fetch the
    //    rest of the pack) and keeps quota usage minimal.
    final picked = (season != null && episode != null)
        ? EpisodeMatcher.pickEpisode<dynamic>(
            rdFiles,
            season,
            episode,
            name: (f) => (f['path'] as String?) ?? '',
            size: (f) => (f['bytes'] as num?)?.toInt() ?? 0,
          )
        : EpisodeMatcher.pickLargestVideo<dynamic>(
            rdFiles,
            name: (f) => (f['path'] as String?) ?? '',
            size: (f) => (f['bytes'] as num?)?.toInt() ?? 0,
          );
    if (picked == null) {
      throw Exception("No video file found in torrent");
    }
    final pickedId = picked['id'].toString();
    final pickedPath = (picked['path'] as String?) ?? '';
    final pickedSize = (picked['bytes'] as num?)?.toInt() ?? 0;
    debugPrint('[RD] picked file id=$pickedId  path=$pickedPath');

    final selRes = await http.post(
      Uri.parse('https://api.real-debrid.com/rest/1.0/torrents/selectFiles/$torrentId'),
      headers: headers,
      body: {'files': pickedId},
    );
    if (selRes.statusCode != 204 && selRes.statusCode != 202) {
      // Fall back to selecting all if RD rejects single-file selection.
      debugPrint('[RD] single-file select failed (${selRes.statusCode}), falling back to all');
      await http.post(
        Uri.parse('https://api.real-debrid.com/rest/1.0/torrents/selectFiles/$torrentId'),
        headers: headers,
        body: {'files': 'all'},
      );
    }

    // 4. Poll until the file is fully fetched (cached torrents finish almost
    //    immediately).
    attempts = 0;
    while (attempts < 40) {
      final infoRes = await http.get(
        Uri.parse('https://api.real-debrid.com/rest/1.0/torrents/info/$torrentId'),
        headers: headers,
      );
      info = json.decode(infoRes.body) as Map<String, dynamic>;
      final status = info['status'] as String?;
      if (status == 'downloaded') break;
      if (status == 'error' || status == 'dead' || status == 'virus') {
        throw Exception("RD download failed (status: $status)");
      }
      await Future.delayed(const Duration(seconds: 3));
      attempts++;
    }
    if (info!['status'] != 'downloaded') {
      throw Exception("RD download timed out");
    }

    // 5. Unrestrict ONLY the picked file's link.
    final links = (info['links'] as List?) ?? const [];
    if (links.isEmpty) throw Exception("RD returned no links");
    // After single-file selection RD returns exactly one link. After the
    // 'all' fallback we have to find the link matching our picked file by
    // looking at the position of the picked file inside the selected files.
    String? targetLink;
    if (links.length == 1) {
      targetLink = links.first as String;
    } else {
      final selectedFiles = (info['files'] as List)
          .where((f) => (f['selected'] as int?) == 1)
          .toList();
      final idx = selectedFiles.indexWhere((f) => f['id'].toString() == pickedId);
      if (idx >= 0 && idx < links.length) {
        targetLink = links[idx] as String;
      } else {
        targetLink = links.first as String;
      }
    }

    final unRes = await http.post(
      Uri.parse('https://api.real-debrid.com/rest/1.0/unrestrict/link'),
      headers: headers,
      body: {'link': targetLink},
    );
    if (unRes.statusCode != 200) {
      throw Exception("RD unrestrict failed: ${unRes.body}");
    }
    final data = json.decode(unRes.body) as Map<String, dynamic>;
    return [
      DebridFile(
        filename: (data['filename'] as String?) ?? pickedPath.split('/').last,
        filesize: (data['filesize'] as num?)?.toInt() ?? pickedSize,
        downloadUrl: data['download'] as String,
      ),
    ];
  }

  // --- TorBox Flow ---

  Future<void> saveTorBoxKey(String key) async {
    await _storage.write(key: 'torbox_api_key', value: key, aOptions: _aOptions);
  }

  Future<String?> getTorBoxKey() async {
    return await _safeRead('torbox_api_key');
  }

  Future<List<DebridFile>> resolveTorBox(
    String magnet, {
    int? season,
    int? episode,
  }) async {
    final apiKey = await getTorBoxKey();
    if (apiKey == null) throw Exception("TorBox API Key not set");

    final headers = {'Authorization': 'Bearer $apiKey'};

    // 1. Create Torrent
    final createRes = await http.post(
      Uri.parse('https://api.torbox.app/v1/api/torrents/createtorrent'),
      headers: headers,
      body: {'magnet': magnet},
    );
    
    final createData = json.decode(createRes.body);
    if (createData['success'] == false) throw Exception("TorBox failed: ${createData['detail']}");
    
    final torrentId = createData['data']['torrent_id'];

    // 2. Poll status
    Map<String, dynamic>? info;
    int attempts = 0;
    while (attempts < 20) {
      final infoRes = await http.get(
        Uri.parse('https://api.torbox.app/v1/api/torrents/mylist?id=$torrentId&bypass_cache=true'),
        headers: headers,
      );
      final mylist = json.decode(infoRes.body)['data'];
      // TorBox returns a single object if ID is provided
      info = mylist;
      if (info!['download_finished'] == true || info['download_state'] == 'cached') break;
      if (info['download_state'] == 'error') throw Exception("TorBox Download failed");
      
      await Future.delayed(const Duration(seconds: 3));
      attempts++;
    }

    final List rawFiles = (info!['files'] as List?) ?? const [];
    if (rawFiles.isEmpty) throw Exception("TorBox returned no files");

    // 3. Pick the right file (episode match or largest video) instead of
    //    handing the caller all of them. Returns a single-element list so
    //    `files.first.downloadUrl` is always the right URL.
    final picked = (season != null && episode != null)
        ? EpisodeMatcher.pickEpisode<dynamic>(
            rawFiles,
            season,
            episode,
            name: (f) => (f['name'] as String?) ?? '',
            size: (f) => (f['size'] as num?)?.toInt() ?? 0,
          )
        : EpisodeMatcher.pickLargestVideo<dynamic>(
            rawFiles,
            name: (f) => (f['name'] as String?) ?? '',
            size: (f) => (f['size'] as num?)?.toInt() ?? 0,
          );
    if (picked == null) throw Exception("No video file found in torrent");

    final permalink =
        'https://api.torbox.app/v1/api/torrents/requestdl?token=$apiKey'
        '&torrent_id=$torrentId&file_id=${picked['id']}&redirect=true';
    return [
      DebridFile(
        filename: (picked['name'] as String?) ?? 'video',
        filesize: (picked['size'] as num?)?.toInt() ?? 0,
        downloadUrl: permalink,
      ),
    ];
  }
}
