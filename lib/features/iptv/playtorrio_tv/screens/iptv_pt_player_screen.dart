import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:window_manager/window_manager.dart';

import '../data/models.dart';

/// Single source for the IPTV player.
class IptvPlaySource {
  final String url;
  final String label;
  const IptvPlaySource({required this.url, required this.label});
}

class IptvPtPlayerScreen extends StatefulWidget {
  final List<IptvPlaySource> sources;
  final String title;
  final String? subtitle;
  final String? logoUrl;

  const IptvPtPlayerScreen({
    super.key,
    required this.sources,
    required this.title,
    this.subtitle,
    this.logoUrl,
  });

  factory IptvPtPlayerScreen.singleStream({
    Key? key,
    required String url,
    required IptvStream stream,
    String? portalName,
  }) =>
      IptvPtPlayerScreen(
        key: key,
        sources: [IptvPlaySource(url: url, label: portalName ?? 'Source 1')],
        title: stream.name,
        subtitle: portalName,
        logoUrl: stream.icon,
      );

  factory IptvPtPlayerScreen.fromHits({
    Key? key,
    required List<ChannelHit> hits,
    required String title,
    String? logoUrl,
  }) =>
      IptvPtPlayerScreen(
        key: key,
        title: title,
        logoUrl: logoUrl,
        sources: hits
            .asMap()
            .entries
            .map((e) => IptvPlaySource(
                  url: e.value.streamUrl,
                  label: e.value.portal.name.isNotEmpty
                      ? e.value.portal.name
                      : 'Source ${e.key + 1}',
                ))
            .toList(),
      );

  @override
  State<IptvPtPlayerScreen> createState() => _IptvPtPlayerScreenState();
}

class _IptvPtPlayerScreenState extends State<IptvPtPlayerScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  late Player _player;
  late VideoController _controller;

  StreamSubscription? _posSub, _playingSub, _bufferingSub, _errorSub;

  int _sourceIdx = 0;
  bool _playing = false;
  bool _buffering = false;
  bool _userPlayWhenReady = true;
  bool _controlsVisible = true;
  Timer? _hideControlsTimer;

  // Live dot pulse animation
  late AnimationController _livePulseController;
  late Animation<double> _livePulseAnim;

  // Watchdog
  Timer? _watchdog;
  Duration _lastPos = Duration.zero;
  DateTime _lastPosChange = DateTime.now();
  DateTime? _bufferingSince;
  DateTime? _readyNotPlayingSince;

  // Audio
  double _volume = 100.0;
  double _volumeBeforeMute = 100.0;
  bool _muted = false;
  bool _showVolumeSlider = false;
  Timer? _hideVolumeTimer;

  // Fullscreen
  bool _isFullscreen = false;
  bool get _isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);
  bool get _isAndroid => !kIsWeb && Platform.isAndroid;
  bool get _isIOS => !kIsWeb && Platform.isIOS;

  // Retry state
  int _retryAttempt = 0;
  DateTime? _lastRecoveryAt;
  DateTime? _pausedAt;
  bool _recoveryInFlight = false;
  static const Duration _liveRejoinThreshold = Duration(seconds: 2);
  static const Duration _healthyStreakNeeded = Duration(seconds: 8);
  static const int _maxRetries = 8;
  // Tier thresholds (ms)
  static const int _tier2StallMs = 5000; // full recreate
  final List<int> _backoffMs = const [300, 600, 1000, 1500, 2000, 3000, 4000, 5000];

  static const _ua = 'VLC/3.0.20 LibVLC/3.0.20';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _livePulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _livePulseAnim = Tween<double>(begin: 0.4, end: 1.0).animate(
      CurvedAnimation(parent: _livePulseController, curve: Curves.easeInOut),
    );

    _initChrome();
    WakelockPlus.enable();

    _player = Player(
      configuration: const PlayerConfiguration(
        bufferSize: 8 * 1024 * 1024, // 8MB — smaller = less initial buffering
        logLevel: MPVLogLevel.warn,
      ),
    );
    _controller = VideoController(_player);
    _bind();
    _applyMpvTunables();
    _openCurrent();
    _startWatchdog();
    _scheduleHideControls();
  }

  Future<void> _applyMpvTunables() async {
    try {
      final p = _player.platform;
      if (p is! NativePlayer) return;

      // ── Hardware decoding (platform-specific) ─────────────────────────────
      // Android: mediacodec — the only hw decoder that works with media_kit's
      //   Surface-based renderer. auto-safe on Android often falls back to SW.
      // iOS: videotoolbox — Apple's HW decode API.
      // Desktop: auto-safe — tries hw but never crashes if unavailable.
      if (_isAndroid) {
        await p.setProperty('hwdec', 'mediacodec');
      } else if (_isIOS) {
        await p.setProperty('hwdec', 'videotoolbox');
      } else {
        await p.setProperty('hwdec', 'auto-safe');
      }

      // ── Low-latency profile ───────────────────────────────────────────────
      // mpv's built-in profile sets: audio-buffer=0, vd-lavc-threads=1,
      // cache-pause=no, fflags=+nobuffer, video-latency-hacks=yes,
      // stream-buffer-size=4k. Activating it first, then we override below.
      await p.setProperty('profile', 'low-latency');

      // ── Video sync ────────────────────────────────────────────────────────
      // display-resample: smooth frame pacing tied to display refresh rate.
      // Reduces judder on Xtream H.264/H.265 streams with bad timestamps.
      await p.setProperty('video-sync', 'display-resample');

      // ── Live demux ────────────────────────────────────────────────────────
      // live=1 tells libavformat this is a live stream — changes timestamp
      // handling so it doesn't try to seek to "beginning" on reconnect.
      // probesize/analyzeduration: enough to detect codec params on junk
      // Xtream encoders without taking forever to start.
      await p.setProperty(
        'demuxer-lavf-o',
        'live=1,'
            'fflags=+nobuffer+discardcorrupt,'
            'probesize=1000000,'
            'analyzeduration=1000000',
      );

      // ── Cache: NONE for live ───────────────────────────────────────────────
      // For live IPTV, a large cache causes mpv to try to fill it before
      // starting playback → the initial "buffering forever" problem.
      // No cache = start playing as soon as the first keyframe arrives.
      await p.setProperty('cache', 'no');
      await p.setProperty('cache-pause', 'no');
      await p.setProperty('cache-pause-initial', 'no');

      // ── Network ───────────────────────────────────────────────────────────
      await p.setProperty('network-timeout', '10'); // fail fast → watchdog takes over
      await p.setProperty('rtsp-transport', 'tcp');
      await p.setProperty('user-agent', _ua);
      await p.setProperty('hls-bitrate', 'max');

      // ── Keep-open: don't quit on EOF / brief drop ────────────────────────
      await p.setProperty('keep-open', 'yes');
      await p.setProperty('keep-open-pause', 'no');

      // ── FFmpeg reconnect knobs ────────────────────────────────────────────
      await p.setProperty(
        'stream-lavf-o',
        'reconnect=1,'
            'reconnect_at_eof=1,'
            'reconnect_streamed=1,'
            'reconnect_delay_max=3,'
            'reconnect_on_network_error=1,'
            'reconnect_on_http_error=4xx\\,5xx',
      );
    } catch (e) {
      debugPrint('[IPTV Player] tunables error: $e');
    }
  }

  Future<void> _initChrome() async {
    _isFullscreen = false;
  }

  Future<void> _toggleFullscreen() async {
    if (_isDesktop) {
      try {
        final isFull = await windowManager.isFullScreen();
        if (isFull) {
          await windowManager.setFullScreen(false);
          if (await windowManager.isMaximized()) await windowManager.unmaximize();
        } else {
          if (await windowManager.isMaximized()) await windowManager.unmaximize();
          await windowManager.setFullScreen(true);
        }
        if (mounted) setState(() => _isFullscreen = !isFull);
      } catch (_) {}
    } else {
      final goFull = !_isFullscreen;
      await SystemChrome.setEnabledSystemUIMode(
        goFull ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
      );
      await SystemChrome.setPreferredOrientations(
        goFull
            ? [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
            : DeviceOrientation.values,
      );
      if (mounted) setState(() => _isFullscreen = goFull);
    }
    _scheduleHideControls();
  }

  void _bind() {
    _posSub = _player.stream.position.listen((pos) {
      if (!mounted) return;
      if (pos != _lastPos) {
        _lastPos = pos;
        _lastPosChange = DateTime.now();
      }
    });

    _playingSub = _player.stream.playing.listen((p) {
      if (!mounted) return;
      setState(() => _playing = p);
      if (p) {
        _readyNotPlayingSince = null;
      } else if (_userPlayWhenReady) {
        _readyNotPlayingSince ??= DateTime.now();
      }
    });

    _bufferingSub = _player.stream.buffering.listen((b) {
      if (!mounted) return;
      setState(() => _buffering = b);
      if (b) {
        _bufferingSince ??= DateTime.now();
      } else {
        _bufferingSince = null;
      }
    });

    _errorSub = _player.stream.error.listen((err) {
      final msg = err.toString();
      final lower = msg.toLowerCase();
      // Benign errors — don't trigger recovery
      if (lower.contains('cannot seek') ||
          lower.contains('force-seekable') ||
          lower.contains("expected '=' and a value") ||
          lower.contains('live=1')) {
        return;
      }
      debugPrint('[IPTV Player] error: $msg');
      _triggerRecovery(reason: 'error: $msg');
    });
  }

  Future<void> _openCurrent() async {
    final src = widget.sources[_sourceIdx];
    try {
      await _player.open(
        Media(src.url, httpHeaders: const {'User-Agent': _ua}),
      );
      await _player.play();
      _userPlayWhenReady = true;
      _pausedAt = null;
      _lastPos = Duration.zero;
      _lastPosChange = DateTime.now();
    } catch (e) {
      _triggerRecovery(reason: 'open failed: $e');
    }
  }

  void _startWatchdog() {
    // Poll every 500ms — twice as fast as before for quicker reaction
    _watchdog = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;
      final now = DateTime.now();

      // ── Healthy streak → reset retry counter ──────────────────────────────
      if (_retryAttempt > 0 &&
          _playing &&
          !_buffering &&
          _lastRecoveryAt != null &&
          now.difference(_lastRecoveryAt!) > _healthyStreakNeeded) {
        debugPrint('[Watchdog] healthy — resetting retries');
        _retryAttempt = 0;
        _lastRecoveryAt = null;
      }

      // ── Detector 1: buffering stall ───────────────────────────────────────
      if (_userPlayWhenReady && _bufferingSince != null) {
        final stalledMs = now.difference(_bufferingSince!).inMilliseconds;
        if (stalledMs > _tier2StallMs) {
          _triggerRecovery(reason: 'buffering > ${_tier2StallMs}ms');
          return;
        }
      }

      // ── Detector 2: position frozen while playing ─────────────────────────
      if (_playing) {
        final frozenMs = now.difference(_lastPosChange).inMilliseconds;
        if (frozenMs > _tier2StallMs) {
          _triggerRecovery(reason: 'position frozen > ${_tier2StallMs}ms');
          return;
        }
      }

      // ── Detector 3: should play but not playing ───────────────────────────
      if (_userPlayWhenReady &&
          !_playing &&
          _readyNotPlayingSince != null &&
          now.difference(_readyNotPlayingSince!).inMilliseconds > _tier2StallMs) {
        _triggerRecovery(reason: 'not playing > ${_tier2StallMs}ms');
      }
    });
  }

  Future<void> _triggerRecovery({required String reason}) async {
    if (_recoveryInFlight) return;
    final now = DateTime.now();
    // Throttle: don't trigger again within 1s of last recovery
    if (_lastRecoveryAt != null &&
        now.difference(_lastRecoveryAt!).inMilliseconds < 1000) {
      return;
    }

    _recoveryInFlight = true;
    _lastRecoveryAt = now;
    debugPrint('[Watchdog] recovery #${_retryAttempt + 1}: $reason');

    try {
      // ── Source exhausted → give up ────────────────────────────────────────
      if (_retryAttempt >= _maxRetries) {
        if (_sourceIdx < widget.sources.length - 1) {
          _sourceIdx++;
          _retryAttempt = 0;
          debugPrint('[Watchdog] rotating to source $_sourceIdx');
          await _openCurrent();
        }
        // If no more sources, just stop — watchdog keeps running if user retries
        return;
      }

      _retryAttempt++;
      final delayIdx = (_retryAttempt - 1).clamp(0, _backoffMs.length - 1);
      await Future.delayed(Duration(milliseconds: _backoffMs[delayIdx]));

      if (_retryAttempt <= 3) {
        // ── Tier 1: fast stop → open ─────────────────────────────────────
        // Skipping seek(Duration.zero) — pointless on live, causes noisy errors
        try {
          await _player.stop();
        } catch (_) {}
        try {
          await _player.open(
            Media(widget.sources[_sourceIdx].url,
                httpHeaders: const {'User-Agent': _ua}),
          );
          await _player.play();
        } catch (_) {}
      } else {
        // ── Tier 2: full player recreate ─────────────────────────────────
        await _disposePlayer();
        _player = Player(
          configuration: const PlayerConfiguration(
            bufferSize: 8 * 1024 * 1024,
            logLevel: MPVLogLevel.warn,
          ),
        );
        _controller = VideoController(_player);
        _bind();
        await _applyMpvTunables();
        try {
          await _player.open(
            Media(widget.sources[_sourceIdx].url,
                httpHeaders: const {'User-Agent': _ua}),
          );
          await _player.play();
        } catch (e) {
          debugPrint('[Watchdog] recreate open failed: $e');
        }
        if (mounted) setState(() {});
      }

      _bufferingSince = null;
      _readyNotPlayingSince = null;
      _lastPos = Duration.zero;
      _lastPosChange = DateTime.now();
    } finally {
      _recoveryInFlight = false;
    }
  }

  Future<void> _disposePlayer() async {
    await _posSub?.cancel();
    await _playingSub?.cancel();
    await _bufferingSub?.cancel();
    await _errorSub?.cancel();
    try {
      await _player.dispose();
    } catch (_) {}
  }

  void _switchSource(int idx) async {
    if (idx == _sourceIdx) return;
    setState(() {
      _sourceIdx = idx;
      _retryAttempt = 0;
    });
    await _openCurrent();
  }

  void _scheduleHideControls() {
    _hideControlsTimer?.cancel();
    _hideControlsTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted) return;
      setState(() => _controlsVisible = false);
    });
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleHideControls();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _livePulseController.dispose();
    _watchdog?.cancel();
    _hideControlsTimer?.cancel();
    _hideVolumeTimer?.cancel();
    _disposePlayer();
    WakelockPlus.disable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    if (_isDesktop) {
      Future.microtask(() async {
        try {
          if (await windowManager.isFullScreen()) {
            await windowManager.setFullScreen(false);
          }
          if (await windowManager.isMaximized()) {
            await windowManager.unmaximize();
          }
        } catch (_) {}
      });
    }
    super.dispose();
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggleControls,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Video surface
            Center(
              child: Video(
                controller: _controller,
                fit: BoxFit.contain,
                controls: NoVideoControls,
              ),
            ),

            // Buffering shimmer overlay (replaces banner chip)
            if (_buffering) _buildBufferingOverlay(),

            // Controls overlay (top bar + bottom pill)
            AnimatedOpacity(
              duration: const Duration(milliseconds: 200),
              opacity: _controlsVisible ? 1 : 0,
              child: IgnorePointer(
                ignoring: !_controlsVisible,
                child: _buildControls(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Buffering shimmer ──────────────────────────────────────────────────────

  Widget _buildBufferingOverlay() {
    return Positioned.fill(
      child: Center(
        child: _GlassCard(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 18),
          borderRadius: 40,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation(
                    Colors.white.withValues(alpha: 0.9),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Text(
                'Connecting…',
                style: GoogleFonts.dmSans(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Controls ───────────────────────────────────────────────────────────────

  Widget _buildControls() {
    return Column(
      children: [
        // Top bar
        _buildTopBar(),
        const Spacer(),
        // Bottom pill
        Padding(
          padding: const EdgeInsets.only(bottom: 32, left: 20, right: 20),
          child: _buildBottomPill(),
        ),
      ],
    );
  }

  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 8, 0),
      child: ClipRRect(
        borderRadius: const BorderRadius.only(
          bottomLeft: Radius.circular(20),
          bottomRight: Radius.circular(20),
        ),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            padding: const EdgeInsets.fromLTRB(8, 12, 16, 12),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.35),
              border: Border(
                bottom: BorderSide(
                  color: Colors.white.withValues(alpha: 0.08),
                  width: 0.5,
                ),
              ),
            ),
            child: SafeArea(
              bottom: false,
              child: Row(
                children: [
                  // Back button
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(50),
                      onTap: () => Navigator.of(context).maybePop(),
                      child: const Padding(
                        padding: EdgeInsets.all(8),
                        child: Icon(Icons.arrow_back_ios_new_rounded,
                            color: Colors.white, size: 20),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),

                  // Logo
                  if ((widget.logoUrl ?? '').isNotEmpty) ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.network(
                        widget.logoUrl!,
                        width: 34,
                        height: 34,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
                    ),
                    const SizedBox(width: 10),
                  ],

                  // Title + subtitle
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.dmSans(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.2,
                          ),
                        ),
                        if ((widget.subtitle ?? '').isNotEmpty)
                          Text(
                            widget.subtitle!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.dmSans(
                              color: Colors.white54,
                              fontSize: 12,
                              fontWeight: FontWeight.w400,
                            ),
                          ),
                      ],
                    ),
                  ),

                  const SizedBox(width: 12),

                  // Live dot
                  _LiveDot(pulse: _livePulseAnim),

                  const SizedBox(width: 8),

                  // Fullscreen (top-right)
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(50),
                      onTap: _toggleFullscreen,
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Icon(
                          _isFullscreen
                              ? Icons.fullscreen_exit_rounded
                              : Icons.fullscreen_rounded,
                          color: Colors.white,
                          size: 22,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBottomPill() {
    return _GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      borderRadius: 50,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Play/Pause
          _PillButton(
            icon: _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            size: 30,
            onTap: () async {
              if (_playing) {
                _userPlayWhenReady = false;
                _pausedAt = DateTime.now();
                await _player.pause();
              } else {
                _userPlayWhenReady = true;
                final pausedFor = _pausedAt == null
                    ? Duration.zero
                    : DateTime.now().difference(_pausedAt!);
                _pausedAt = null;
                if (pausedFor >= _liveRejoinThreshold) {
                  await _openCurrent();
                } else {
                  await _player.play();
                }
              }
              _scheduleHideControls();
            },
          ),

          const SizedBox(width: 4),

          // Reload
          _PillButton(
            icon: Icons.replay_rounded,
            size: 22,
            onTap: () async {
              _retryAttempt = 0;
              await _openCurrent();
              _scheduleHideControls();
            },
          ),

          const SizedBox(width: 4),

          // Volume
          _PillButton(
            icon: _muted || _volume == 0
                ? Icons.volume_off_rounded
                : (_volume < 40
                    ? Icons.volume_down_rounded
                    : Icons.volume_up_rounded),
            size: 22,
            onTap: _toggleMute,
            onLongPress: () {
              setState(() => _showVolumeSlider = !_showVolumeSlider);
              _scheduleHideVolumeSlider();
              _scheduleHideControls();
            },
          ),

          // Volume slider
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
            child: SizedBox(
              width: _showVolumeSlider ? 120 : 0,
              child: ClipRect(
                child: Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      activeTrackColor: Colors.white,
                      inactiveTrackColor: Colors.white24,
                      thumbColor: Colors.white,
                      overlayColor: Colors.white12,
                      trackHeight: 2.5,
                      thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 6),
                    ),
                    child: Slider(
                      value: _volume.clamp(0.0, 100.0),
                      min: 0,
                      max: 100,
                      onChanged: (v) {
                        setState(() {
                          _volume = v;
                          _muted = v == 0;
                        });
                        _player.setVolume(v);
                        _scheduleHideVolumeSlider();
                        _scheduleHideControls();
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),

          if (widget.sources.length > 1) ...[
            const SizedBox(width: 4),
            // Divider
            Container(
              width: 1,
              height: 22,
              color: Colors.white.withValues(alpha: 0.15),
            ),
            const SizedBox(width: 4),
            // Source picker
            _PillButton(
              icon: Icons.swap_horiz_rounded,
              size: 22,
              onTap: _showSourcePicker,
              label: widget.sources[_sourceIdx].label,
            ),
          ],
        ],
      ),
    );
  }

  void _toggleMute() {
    setState(() {
      if (_muted || _volume == 0) {
        _muted = false;
        _volume = _volumeBeforeMute > 0 ? _volumeBeforeMute : 100.0;
      } else {
        _volumeBeforeMute = _volume;
        _muted = true;
        _volume = 0;
      }
      _showVolumeSlider = true;
    });
    _player.setVolume(_volume);
    _scheduleHideVolumeSlider();
    _scheduleHideControls();
  }

  void _scheduleHideVolumeSlider() {
    _hideVolumeTimer?.cancel();
    _hideVolumeTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      setState(() => _showVolumeSlider = false);
    });
  }

  void _showSourcePicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => _SourcePickerSheet(
        sources: widget.sources,
        activeIdx: _sourceIdx,
        onSelect: (i) {
          Navigator.of(ctx).pop();
          _switchSource(i);
        },
      ),
    );
  }
}

// ── Live dot ───────────────────────────────────────────────────────────────────

class _LiveDot extends StatelessWidget {
  final Animation<double> pulse;
  const _LiveDot({required this.pulse});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedBuilder(
          animation: pulse,
          builder: (_, _) => Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: Colors.redAccent.withValues(alpha: pulse.value),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.red.withValues(alpha: pulse.value * 0.6),
                  blurRadius: 4,
                  spreadRadius: 1,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 5),
        Text(
          'LIVE',
          style: GoogleFonts.dmMono(
            color: Colors.white70,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.2,
          ),
        ),
      ],
    );
  }
}

// ── Glass card ─────────────────────────────────────────────────────────────────

class _GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final double borderRadius;

  const _GlassCard({
    required this.child,
    required this.padding,
    this.borderRadius = 24,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(borderRadius),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.15),
              width: 0.8,
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

// ── Pill button ────────────────────────────────────────────────────────────────

class _PillButton extends StatelessWidget {
  final IconData icon;
  final double size;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final String? label;

  const _PillButton({
    required this.icon,
    required this.size,
    required this.onTap,
    this.onLongPress,
    this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(50),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white, size: size),
              if (label != null) ...[
                const SizedBox(width: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 90),
                  child: Text(
                    label!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.dmSans(
                      color: Colors.white70,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ── Source picker sheet ────────────────────────────────────────────────────────

class _SourcePickerSheet extends StatelessWidget {
  final List<IptvPlaySource> sources;
  final int activeIdx;
  final ValueChanged<int> onSelect;

  const _SourcePickerSheet({
    required this.sources,
    required this.activeIdx,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
        left: 16,
        right: 16,
        top: 16,
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.72),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
              border: Border(
                top: BorderSide(
                  color: Colors.white.withValues(alpha: 0.12),
                  width: 0.8,
                ),
              ),
            ),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 12),
                  Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Row(
                      children: [
                        Text(
                          'Sources',
                          style: GoogleFonts.dmSans(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            '${sources.length}',
                            style: GoogleFonts.dmMono(
                              color: Colors.white54,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.sizeOf(context).height * 0.45,
                    ),
                    child: ListView.builder(
                      shrinkWrap: true,
                      padding: const EdgeInsets.only(
                          bottom: 16, left: 12, right: 12),
                      itemCount: sources.length,
                      itemBuilder: (_, i) {
                        final s = sources[i];
                        final active = i == activeIdx;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Material(
                            color: Colors.transparent,
                            child: InkWell(
                              borderRadius: BorderRadius.circular(16),
                              onTap: () => onSelect(i),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 14),
                                decoration: BoxDecoration(
                                  color: active
                                      ? Colors.white.withValues(alpha: 0.12)
                                      : Colors.white.withValues(alpha: 0.04),
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                    color: active
                                        ? Colors.white.withValues(alpha: 0.25)
                                        : Colors.transparent,
                                    width: 0.8,
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 8,
                                      height: 8,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: active
                                            ? Colors.white
                                            : Colors.white24,
                                      ),
                                    ),
                                    const SizedBox(width: 14),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            s.label,
                                            style: GoogleFonts.dmSans(
                                              color: active
                                                  ? Colors.white
                                                  : Colors.white70,
                                              fontWeight: active
                                                  ? FontWeight.w600
                                                  : FontWeight.w400,
                                              fontSize: 14,
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            s.url,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: GoogleFonts.dmMono(
                                              color: Colors.white30,
                                              fontSize: 10,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    if (active)
                                      const Icon(Icons.check_rounded,
                                          color: Colors.white, size: 18),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}