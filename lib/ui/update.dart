import 'package:flutter/material.dart' hide Card;

import '../app/updater.dart';
import 'lcars.dart';

/// Offers a newer GitHub release and shows the download; see [Updater].
class UpdateDialog extends StatelessWidget {
  const UpdateDialog({super.key, required this.release});
  final ReleaseInfo release;

  /// Shows the prompt for [release] on top of whatever is on screen.
  static Future<void> show(BuildContext context, ReleaseInfo release) => showDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => UpdateDialog(release: release),
  );

  @override
  Widget build(BuildContext context) {
    final u = Updater.shared;
    return ListenableBuilder(
      listenable: u,
      builder: (context, _) => AlertDialog(
        backgroundColor: LCARS.panel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: LCARS.orange, width: 2),
        ),
        title: Text('NEW BUILD AVAILABLE', style: LCARS.font(18, color: LCARS.orange)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${release.label} is on GitHub Releases. You have ${u.installedVersion} (build ${u.installedCode}).', style: LCARS.body),
            if (release.notes.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                release.notes,
                style: LCARS.label.copyWith(color: LCARS.peach),
                maxLines: 6,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            if (u.downloading) ...[
              const SizedBox(height: 14),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(value: u.progress, minHeight: 10, backgroundColor: LCARS.gray.withValues(alpha: 0.3), color: LCARS.gold),
              ),
              const SizedBox(height: 6),
              Text('Downloading ${(u.progress * 100).round()}%', style: LCARS.label),
            ] else if (u.downloaded != null) ...[
              const SizedBox(height: 8),
              Text('Downloaded and ready to install.', style: LCARS.label.copyWith(color: LCARS.green)),
            ],
            if (u.error != null) ...[const SizedBox(height: 10), Text(u.error!, style: LCARS.label.copyWith(color: LCARS.alert))],
          ],
        ),
        actions: [
          if (!u.downloading)
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('LATER', style: LCARS.font(13, color: LCARS.gray)),
            ),
          if (!u.downloading && u.error != null && u.error!.contains('different key'))
            TextButton(
              onPressed: u.installAnyway,
              child: Text('OPEN INSTALLER ANYWAY', style: LCARS.font(13, color: LCARS.peach)),
            ),
          if (!u.downloading)
            LcarsButton(
              u.downloaded != null ? 'Install' : 'Download & install',
              icon: Icons.system_update,
              expand: false,
              height: 36,
              onPressed: () async {
                final ok = await u.downloadAndInstall(release: release);
                if (ok && context.mounted) Navigator.pop(context);
              },
            ),
        ],
      ),
    );
  }
}

/// Checks GitHub on launch and whenever the app returns to the foreground, and shows
/// [UpdateDialog] when a newer build exists. Wrap the first screen with it; it draws nothing.
class UpdateCheck extends StatefulWidget {
  const UpdateCheck({super.key, required this.child});
  final Widget child;
  @override
  State<UpdateCheck> createState() => _UpdateCheckState();
}

class _UpdateCheckState extends State<UpdateCheck> with WidgetsBindingObserver {
  bool _showing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    final u = Updater.shared;
    final already = u.available;
    final release = await u.checkAutomatically();
    // Prompt once per build found; a resume that finds the same build stays quiet.
    if (release == null || !mounted || _showing || (already != null && already.versionCode == release.versionCode)) return;
    _showing = true;
    await UpdateDialog.show(context, release);
    _showing = false;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
