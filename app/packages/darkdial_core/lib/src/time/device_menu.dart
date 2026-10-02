/// The time tracking menu shown on the device. The service builds the pages
/// and carries out what is chosen; the device only displays a page and reports
/// the selected line (PROTOCOL.md 1.7).
library;

import '../midi_codec.dart';
import '../param_def.dart';
import '../params.g.dart';
import 'database.dart';
import 'time_tracker.dart';

/// One page as sent to the device.
class MenuPage {
  const MenuPage(this.title, this.items);
  final String title;
  final List<MenuItem> items;
}

/// What a selection led to: another page, or the menu is finished with a
/// result for the device to confirm.
class MenuOutcome {
  const MenuOutcome.page(MenuPage this.page) : result = null;
  const MenuOutcome.done(TimerResult this.result) : page = null;

  final MenuPage? page;
  final TimerResult? result;
}

sealed class _Action {
  const _Action();
}

class _Stop extends _Action {
  const _Stop();
}

class _StartJob extends _Action {
  const _StartJob(this.jobId);
  final int jobId;
}

class _NewJob extends _Action {
  const _NewJob(this.clientId);
  final int? clientId;
}

class _NewClient extends _Action {
  const _NewClient();
}

class _OpenClients extends _Action {
  const _OpenClients();
}

class _OpenClient extends _Action {
  const _OpenClient(this.clientId);
  final int clientId;
}

class _Back extends _Action {
  const _Back();
}

/// Closing is done by the device itself (flag on the item).
class _Close extends _Action {
  const _Close();
}

/// Where the menu is: the start page, the client list, or one client.
enum _Level { root, clients, client }

class DeviceMenu {
  DeviceMenu(this.tracker, this.language);

  /// Jobs offered directly on the start page besides the suggestion.
  static const int recentJobs = 3;

  /// Lines per page; the device holds 16.
  static const int maxItems = 16;

  final TimeTracker tracker;
  Language language;

  _Level _level = _Level.root;
  int? _clientId;
  List<_Action> _actions = const [];
  bool open = false;

  String _text(String key) => kTimerTexts[key]![language.index];

  /// The start page; called when the device opens the menu.
  MenuPage start() {
    open = true;
    _level = _Level.root;
    _clientId = null;
    return _build();
  }

  void close() => open = false;

  /// The current page again, after something changed underneath it.
  MenuPage current() => _build();

  /// Carries out the line at [index] of the page last built.
  MenuOutcome select(int index) {
    if (index < 0 || index >= _actions.length) return MenuOutcome.page(_build());
    final action = _actions[index];
    try {
      switch (action) {
        case _Stop():
          tracker.stop();
          return _done(TimerResult.stopped);
        case _StartJob(:final jobId):
          tracker.start(jobId, origin: 'device');
          return _done(TimerResult.started);
        case _NewJob(:final clientId):
          tracker.startNew(origin: 'device', clientId: clientId);
          return _done(TimerResult.started);
        case _NewClient():
          tracker.startNewClient(origin: 'device');
          return _done(TimerResult.started);
        case _OpenClients():
          _level = _Level.clients;
        case _OpenClient(:final clientId):
          _level = _Level.client;
          _clientId = clientId;
        case _Back():
          _level = _level == _Level.client ? _Level.clients : _Level.root;
        case _Close():
          open = false;
      }
    } on TimeTrackingError catch (error) {
      open = false;
      final german = language == Language.de;
      final text = switch (error.message) {
        'archived' => german ? 'Archiviert' : 'Archived',
        _ => german ? 'Unbekannt' : 'Unknown',
      };
      return MenuOutcome.done(TimerResult(TimerResult.error, text));
    }
    return MenuOutcome.page(_build());
  }

  MenuOutcome _done(int code) {
    open = false;
    return MenuOutcome.done(TimerResult(code));
  }

  MenuPage _build() {
    final items = <MenuItem>[];
    final actions = <_Action>[];
    void add(_Action action, String icon, String label,
        {bool highlighted = false, bool running = false, bool submenu = false, bool closes = false}) {
      if (items.length >= maxItems) return;
      items.add(MenuItem(
        index: items.length,
        icon: kTimerIcons[icon]!,
        label: label,
        highlighted: highlighted,
        running: running,
        submenu: submenu,
        closes: closes,
      ));
      actions.add(action);
    }

    final runningId = tracker.running?.job.id;
    void addJob(Job job, {bool highlighted = false}) => add(_StartJob(job.id), 'stopwatch', tracker.displayLabel(job),
        highlighted: highlighted, running: job.id == runningId);

    String title;
    switch (_level) {
      case _Level.root:
        title = _text('title');
        if (runningId != null) add(const _Stop(), 'stop', _text('stop'), running: true);
        final suggested = tracker.suggestion;
        if (suggested != null) addJob(suggested, highlighted: true);
        for (final job in tracker.jobs().where((j) => j.id != suggested?.id).take(recentJobs)) {
          addJob(job);
        }
        if (tracker.clients().isNotEmpty) add(const _OpenClients(), 'client', _text('clients'), submenu: true);
        add(const _NewJob(null), 'plus', _text('newJob'));
        add(const _NewClient(), 'plus', _text('newClient'));
        add(const _Close(), 'close', _text('close'), closes: true);
      case _Level.clients:
        title = _text('clients');
        // Keep room for "back".
        for (final client in tracker.clients().take(maxItems - 1)) {
          add(_OpenClient(client.id), 'client', tracker.clientLabel(client, word: _text('client')), submenu: true);
        }
        add(const _Back(), 'back', _text('back'));
      case _Level.client:
        final client = _clientId == null ? null : tracker.db.client(_clientId!);
        if (client == null) {
          // The client vanished while the menu was open.
          _level = _Level.clients;
          return _build();
        }
        title = tracker.clientLabel(client, word: _text('client'));
        // Keep room for "new job" and "back".
        for (final job in tracker.jobsOf(client.id).take(maxItems - 2)) {
          addJob(job);
        }
        add(_NewJob(client.id), 'plus', _text('newJob'));
        add(const _Back(), 'back', _text('back'));
    }
    _actions = actions;
    return MenuPage(title, items);
  }
}
