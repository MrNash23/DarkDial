import 'package:darkdial_core/darkdial_core.dart';
import 'package:flutter/material.dart';

import '../app_controller.dart';
import 'config_window.dart';

/// What the device does while Lightroom shows the Library: whether the mode
/// is used at all, and what a tap and a double tap do to the photo.
class LibraryWindow extends StatelessWidget {
  const LibraryWindow({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        if (!c.ready) return const Scaffold(body: Center(child: CircularProgressIndicator()));
        final s = c.strings;
        final library = c.config.library;
        final small = Theme.of(context).textTheme.bodySmall;
        void update(LibrarySettings next) => c.setConfig(c.config.copyWith(library: next));

        return Scaffold(
          body: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ListView(
                  key: const Key('library-settings'),
                  padding: const EdgeInsets.all(24),
                  children: [
                    SectionTitle(s.librarySection),
                    Text(s.libraryIntro, style: small),
                    SwitchListTile(
                      key: const Key('library-enabled'),
                      contentPadding: EdgeInsets.zero,
                      title: Text(s.libraryEnabled),
                      value: library.enabled,
                      onChanged: (value) => update(library.copyWith(enabled: value)),
                    ),
                    const Divider(height: 32),
                    _TapAction(
                      controller: c,
                      keyPrefix: 'library-tap',
                      title: s.libraryTap,
                      mark: library.tap,
                      advances: library.tapAdvances,
                      onMark: (mark) => update(library.copyWith(tap: mark)),
                      onAdvances: (value) => update(library.copyWith(tapAdvances: value)),
                    ),
                    const Divider(height: 32),
                    _TapAction(
                      controller: c,
                      keyPrefix: 'library-double-tap',
                      title: s.libraryDoubleTap,
                      mark: library.doubleTap,
                      advances: library.doubleTapAdvances,
                      onMark: (mark) => update(library.copyWith(doubleTap: mark)),
                      onAdvances: (value) => update(library.copyWith(doubleTapAdvances: value)),
                    ),
                    const SizedBox(height: 12),
                    Text(s.libraryUndoHint, style: small),
                    const Divider(height: 32),
                    SectionTitle(s.libraryKnob),
                    Text(s.libraryKnobHint, style: small),
                  ],
                ),
              ),
              const VerticalDivider(width: 1),
              SizedBox(
                width: 340,
                child: ListView(
                  padding: const EdgeInsets.all(20),
                  children: [PreviewSection(controller: c)],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// One of the two actions: what it marks, and whether the next photo follows.
class _TapAction extends StatelessWidget {
  const _TapAction({
    required this.controller,
    required this.keyPrefix,
    required this.title,
    required this.mark,
    required this.advances,
    required this.onMark,
    required this.onAdvances,
  });

  final AppController controller;
  final String keyPrefix;
  final String title;
  final LibraryMark mark;
  final bool advances;
  final void Function(LibraryMark mark) onMark;
  final void Function(bool value) onAdvances;

  @override
  Widget build(BuildContext context) {
    final s = controller.strings;
    final enabled = controller.config.library.enabled;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionTitle(title),
        Row(
          children: [
            SizedBox(width: 90, child: Text(s.libraryAction)),
            Expanded(
              child: DropdownButton<LibraryMark>(
                key: Key(keyPrefix),
                value: mark,
                isExpanded: true,
                onChanged: enabled ? (value) => onMark(value ?? mark) : null,
                items: [
                  for (final option in LibraryMark.values)
                    DropdownMenuItem(value: option, child: Text(s.libraryMark(option))),
                ],
              ),
            ),
          ],
        ),
        CheckboxListTile(
          key: Key('$keyPrefix-advances'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: Text(s.libraryAdvance),
          value: advances && mark != LibraryMark.none,
          onChanged: enabled && mark != LibraryMark.none ? (value) => onAdvances(value ?? false) : null,
        ),
      ],
    );
  }
}
