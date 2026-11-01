import 'package:flutter/material.dart';
import 'package:guide/l10n/generated/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/settings.dart';
import 'router.dart';
import 'theme.dart';

/// Widest the app content is allowed to grow before it is centered as a
/// phone-width column instead of being stretched across a desktop window.
///
/// The mobile layout is designed for a phone, so on a large browser window
/// the app keeps the same composition it has on a device rather than
/// spreading the card/sheet edge-to-edge (which is what a plain responsive
/// stretch would do). Tablets and small windows stay full-bleed.
const double _kMaxAppWidth = 560;

class GuideApp extends ConsumerWidget {
  const GuideApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final mode = switch (settings.themeMode) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    return MaterialApp.router(
      title: 'Guide',
      debugShowCheckedModeBanner: false,
      locale: settings.locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: mode,
      routerConfig: goRouter,
      builder: (context, child) => _PhoneWidthFrame(child: child),
    );
  }
}

/// Centers the app in a phone-width column on wide browser windows.
///
/// Below [_kMaxAppWidth] this is a pass-through, so the layout on a phone,
/// tablet, or narrow browser is exactly the mobile layout (no change). On a
/// desktop window the same layout is centered rather than stretched; the
/// [MediaQuery] is clamped so descendants (SafeArea, sheets, map controls)
/// still measure the column they actually occupy.
class _PhoneWidthFrame extends StatelessWidget {
  const _PhoneWidthFrame({required this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final media = MediaQuery.of(context);
        final width = constraints.maxWidth;
        if (child == null || width <= _kMaxAppWidth) {
          return child ?? const SizedBox.shrink();
        }
        final height = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : media.size.height;
        return ColoredBox(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Center(
            child: SizedBox(
              width: _kMaxAppWidth,
              height: height,
              child: MediaQuery(
                data: media.copyWith(
                  size: Size(_kMaxAppWidth, height),
                  padding: EdgeInsets.zero,
                  viewPadding: EdgeInsets.zero,
                ),
                child: ClipRect(child: child),
              ),
            ),
          ),
        );
      },
    );
  }
}
