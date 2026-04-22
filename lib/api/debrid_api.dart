import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

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

  Future<List<DebridFile>> resolveRealDebrid(String magnet) async {
    final token = await getRDAccessToken();
    if (token == null) throw Exception("Real-Debrid not logged in");

    final headers = {'Authorization': 'Bearer $token'};

    // 1. Add Magnet
    final addRes = await http.post(
      Uri.parse('https://api.real-debrid.com/rest/1.0/torrents/addMagnet'),
      headers: headers,
      body: {'magnet': magnet},
    );
    
    if (addRes.statusCode != 201) throw Exception("Failed to add magnet to RD");
    final torrentId = json.decode(addRes.body)['id'];

    // 2. Select all files
    await http.post(
      Uri.parse('https://api.real-debrid.com/rest/1.0/torrents/selectFiles/$torrentId'),
      headers: headers,
      body: {'files': 'all'},
    );

    // 3. Poll for status
    Map<String, dynamic>? info;
    int attempts = 0;
    while (attempts < 20) {
      final infoRes = await http.get(
        Uri.parse('https://api.real-debrid.com/rest/1.0/torrents/info/$torrentId'),
        headers: headers,
      );
      info = json.decode(infoRes.body);
      if (info!['status'] == 'downloaded') break;
      if (info['status'] == 'error' || info['status'] == 'dead') throw Exception("RD Download failed");
      
      await Future.delayed(const Duration(seconds: 3));
      attempts++;
    }

    if (info!['status'] != 'downloaded') throw Exception("RD Download timed out");

    // 4. Unrestrict links
    List<DebridFile> resolvedFiles = [];
    final List links = info['links'];
    for (final link in links) {
      final unRes = await http.post(
        Uri.parse('https://api.real-debrid.com/rest/1.0/unrestrict/link'),
        headers: headers,
        body: {'link': link},
      );
      final data = json.decode(unRes.body);
      resolvedFiles.add(DebridFile(
        filename: data['filename'],
        filesize: data['filesize'],
        downloadUrl: data['download'],
      ));
    }

    return resolvedFiles;
  }

  // --- TorBox Flow ---

  Future<void> saveTorBoxKey(String key) async {
    await _storage.write(key: 'torbox_api_key', value: key, aOptions: _aOptions);
  }

  Future<String?> getTorBoxKey() async {
    return await _safeRead('torbox_api_key');
  }

  Future<List<DebridFile>> resolveTorBox(String magnet) async {
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

    // 3. Get Redirect Permalinks
    List<DebridFile> resolvedFiles = [];
    final List files = info!['files'];
    for (final file in files) {
      final permalink = 'https://api.torbox.app/v1/api/torrents/requestdl?token=$apiKey&torrent_id=$torrentId&file_id=${file['id']}&redirect=true';
      resolvedFiles.add(DebridFile(
        filename: file['name'],
        filesize: file['size'],
        downloadUrl: permalink,
      ));
    }

    return resolvedFiles;
  }
}
