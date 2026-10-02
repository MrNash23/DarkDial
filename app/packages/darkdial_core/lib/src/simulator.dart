/// A Darkdial in software. [DeviceModel] is the same state machine the
/// firmware runs (firmware/darkdial/src/core/device.*); [SimulatedDevice] puts
/// it behind the real MIDI wire format so the service cannot tell it from
/// hardware.
library;

import 'dart:async';
import 'dart:typed_data';

import 'device_session.dart';
import 'midi_codec.dart';
import 'params.g.dart';

enum DeviceMode { select, edit }

class SlotValue {
  const SlotValue({this.position = 0, this.valid = false, this.text = ''});
  final int position;
  final bool valid;
  final String text;
}

/// State machine of the device: carousel, edit mode, configuration transfer,
/// and the time tracking menu behind the long press.
class DeviceModel {
  DeviceModel() {
    _loadDefaults();
  }

  static const Duration heartbeatTimeout = Duration(seconds: 5);
  static const Duration noticeTime = Duration(milliseconds: 1200);

  /// Without input for this long the display shows the logo.
  static const Duration idleAfter = Duration(minutes: 3);

  List<ConfigSlot> slots = [];
  List<SlotValue> values = [];
  DeviceMode mode = DeviceMode.select;
  int index = 0;
  Status status = const Status(lightroomConnected: false, developActive: false, photoSelected: false);

  /// False until a Status arrives, and again when the heartbeat stops.
  bool serviceConnected = false;

  /// Angle the picture is turned by, and the one being tried out with the knob.
  int rotation = 0;
  int _adjustAngle = 0;
  bool adjustingRotation = false;
  int get displayAngle => adjustingRotation ? _adjustAngle : rotation;

  void _endRotation(bool save) {
    if (adjustingRotation && save) rotation = _adjustAngle;
    adjustingRotation = false;
    emit(DisplayAngle(rotation));
    onChanged();
  }

  /// What the service said about the Library; inactive in Develop.
  Library library = const Library();

  /// True while Lightroom shows the Library and the knob browses the photos.
  bool get libraryActive => serviceConnected && library.active;

  // Time tracking.
  bool menuOpen = false;
  int menuIndex = 0;

  /// The page shown; empty until the service has sent one.
  String menuTitle = '';
  List<MenuItem> menu = [];
  int _menuPage = 0;
  bool timerRunning = false;
  int timerJobId = 0;
  String timerLabel = '';
  int _timerBaseSeconds = 0;
  DateTime _timerBaseAt = DateTime.now();

  /// True while the logo is shown because nobody used the device for
  /// [idleAfter]. The next input only brings the display back.
  bool idle = false;
  Timer? _idleTimer;

  /// The confirmation shown briefly after start or stop, null when none.
  TimerResult? notice;
  Timer? _noticeTimer;

  List<ConfigSlot>? _incoming;
  int _incomingCount = 0;
  List<MenuItem>? _incomingItems;
  MenuBegin? _incomingMenu;

  /// Messages the device wants to send; set by the owner.
  void Function(DeviceMessage message) emit = (_) {};

  /// Called after every state change, for repainting.
  void Function() onChanged = () {};

  void _loadDefaults() {
    final defaults = kParams.where((p) => p.defaultActive).toList();
    slots = [
      for (var i = 0; i < defaults.length; i++)
        ConfigSlot(
          index: i,
          paramId: defaults[i].id,
          iconId: defaults[i].icon,
          bipolar: defaults[i].bipolar,
          color: defaults[i].color ?? 0,
          label: defaults[i].en,
        ),
    ];
    values = List.filled(slots.length, const SlotValue());
  }

  /// Seconds of the running entry, counted on since the last TimerState.
  int get timerSeconds =>
      timerRunning ? _timerBaseSeconds + DateTime.now().difference(_timerBaseAt).inSeconds : 0;

  /// Notes an input and restarts the idle countdown. True if the input was
  /// used up by bringing the display back.
  bool _wake() {
    _idleTimer?.cancel();
    _idleTimer = Timer(idleAfter, () {
      idle = true;
      onChanged();
    });
    if (!idle) return false;
    idle = false;
    onChanged();
    return true;
  }

  /// Turns the knob by [detents].
  void rotate(int detents) {
    if (detents == 0) return;
    if (_wake()) return;
    if (adjustingRotation) {
      _adjustAngle = (_adjustAngle + detents * 5) % 360;
      emit(DisplayAngle(_adjustAngle, adjusting: true));
      onChanged();
      return;
    }
    if (menuOpen) {
      if (menu.isNotEmpty) menuIndex = (menuIndex + detents) % menu.length;
      onChanged();
      return;
    }
    if (libraryActive) {
      emit(Rotation(detents.clamp(-63, 63)));
      return;
    }
    if (slots.isEmpty) return;
    if (mode == DeviceMode.select) {
      index = (index + detents) % slots.length;
      emit(SlotFocus(index));
      onChanged();
    } else {
      emit(Rotation(detents.clamp(-63, 63)));
    }
  }

  /// Knob click. While the service offers the Library mode it switches
  /// between Library and Develop; otherwise it is the same as a tap.
  void click() {
    if (!idle && adjustingRotation) {
      _wake();
      _endRotation(true);
      return;
    }
    if (!idle && !menuOpen && serviceConnected && (library.active || library.knobToggles)) {
      _wake();
      emit(const LibraryAction(LibraryAction.toggleModule));
      return;
    }
    _select();
  }

  /// A click on what is shown: selects a slot or leaves it, chooses a menu line.
  void _select() {
    if (_wake()) return;
    if (adjustingRotation) {
      _endRotation(true);
      return;
    }
    if (menuOpen) {
      _menuAction();
      return;
    }
    if (slots.isEmpty) return;
    if (mode == DeviceMode.select) {
      mode = DeviceMode.edit;
      emit(SlotSelect(index));
    } else {
      mode = DeviceMode.select;
      emit(SlotLeave(index));
    }
    onChanged();
  }

  /// Tap on the display: the tap action in the Library, otherwise a click.
  void tap() {
    if (!libraryActive || menuOpen || idle) {
      _select();
      return;
    }
    _wake();
    if (library.tapEnabled) emit(const LibraryAction(LibraryAction.tap));
  }

  /// Double tap on the display: in edit mode, reset the slot to its default;
  /// in the Library, the double-tap action.
  void doubleTap() {
    if (_wake()) return;
    if (menuOpen || adjustingRotation) return;
    if (libraryActive) {
      if (library.doubleTapEnabled) emit(const LibraryAction(LibraryAction.doubleTap));
      return;
    }
    if (mode != DeviceMode.edit || slots.isEmpty) return;
    emit(SlotReset(index));
  }

  /// Long press on the knob: opens the time tracking menu from any state, or
  /// closes it without change.
  void longPress() {
    if (_wake()) return;
    if (adjustingRotation) return;
    if (menuOpen) {
      menuOpen = false;
      emit(const MenuClosed());
    } else {
      menuOpen = true;
      menuIndex = 0;
      menuTitle = '';
      menu = [];
      notice = null;
      emit(const MenuOpen());
    }
    onChanged();
  }

  /// Click in the menu: the service decides what the line does and answers
  /// with another page or a result. Only "close" is handled here.
  void _menuAction() {
    if (!serviceConnected || menu.isEmpty) return;
    final item = menu[menuIndex];
    if (item.closes) {
      menuOpen = false;
      emit(const MenuClosed());
      onChanged();
    } else {
      emit(MenuSelect(_menuPage, menuIndex));
    }
  }

  void heartbeatLost() {
    serviceConnected = false;
    timerRunning = false;
    library = const Library();
    adjustingRotation = false;
    if (menuOpen) {
      menu = [];
      menuIndex = 0;
    }
    onChanged();
  }

  void dispose() {
    _noticeTimer?.cancel();
    _idleTimer?.cancel();
  }

  /// Handles a message from the service.
  void handle(DeviceMessage message, {List<int> serial = const [0, 0, 0, 0, 0, 0]}) {
    switch (message) {
      case IdentityRequest():
        emit(const IdentityReply(1, 0, 2, 0));
      case HelloRequest():
        emit(Hello(
          major: protocolMajor,
          minor: protocolMinor,
          fwMajor: 0,
          fwMinor: 2,
          fwPatch: 0,
          serial: serial,
          configCrc: configCrc(slots),
        ));
      case ConfigBegin(:final slotCount):
        if (slotCount < 1 || slotCount > maxSlots) {
          _incoming = null;
          emit(const ConfigAck(2, 0));
        } else {
          _incoming = [];
          _incomingCount = slotCount;
        }
      case ConfigSlot():
        final incoming = _incoming;
        if (incoming == null) return;
        if (message.index != incoming.length || incoming.length >= _incomingCount) {
          _incoming = null;
          emit(const ConfigAck(3, 0));
        } else {
          incoming.add(message);
        }
      case ConfigEnd(:final crc):
        final incoming = _incoming;
        _incoming = null;
        if (incoming == null || incoming.length != _incomingCount) {
          emit(const ConfigAck(3, 0));
          return;
        }
        final actual = configCrc(incoming);
        if (actual != crc) {
          emit(ConfigAck(1, actual));
          return;
        }
        // Stay on the same parameter if it is still there.
        final previous = slots.isEmpty ? -1 : slots[index].paramId;
        slots = incoming;
        values = List.filled(slots.length, const SlotValue());
        final kept = slots.indexWhere((s) => s.paramId == previous);
        index = kept < 0 ? 0 : kept;
        if (kept < 0 && mode == DeviceMode.edit) mode = DeviceMode.select;
        emit(ConfigAck(0, actual));
        onChanged();
      case Value():
        if (message.slot < values.length) {
          values[message.slot] = SlotValue(position: message.position, valid: message.valid, text: message.text);
          onChanged();
        }
      case Status():
        status = message;
        serviceConnected = true;
        onChanged();
      case MenuBegin():
        _incomingMenu = message.count <= maxMenuItems ? message : null;
        _incomingItems = [];
      case MenuItem():
        final begin = _incomingMenu;
        final incoming = _incomingItems;
        if (begin == null || incoming == null) return;
        if (message.index != incoming.length || incoming.length >= begin.count) {
          _incomingMenu = null;
        } else {
          incoming.add(message);
        }
      case MenuEnd():
        final begin = _incomingMenu;
        final incoming = _incomingItems;
        _incomingMenu = null;
        if (begin == null || incoming == null || incoming.length != begin.count) return; // keep the page shown
        if (!menuOpen) return;
        // A refreshed page of the same title keeps the line; a new page starts where it says.
        final samePage = begin.title == menuTitle && menu.isNotEmpty;
        _menuPage = begin.page;
        menuTitle = begin.title;
        menu = incoming;
        if (!samePage) menuIndex = begin.selected;
        if (menuIndex >= menu.length) menuIndex = 0;
        onChanged();
      case TimerState():
        timerRunning = message.running;
        timerJobId = message.jobId;
        timerLabel = message.label;
        _timerBaseSeconds = message.elapsedSeconds;
        _timerBaseAt = DateTime.now();
        onChanged();
      case SlotGoto(:final slot):
        if (menuOpen || slot >= slots.length) return;
        if (mode == DeviceMode.edit && index == slot) return;
        if (mode == DeviceMode.edit) emit(SlotLeave(index));
        index = slot;
        mode = DeviceMode.edit;
        emit(SlotSelect(index));
        onChanged();
      case Library():
        library = message;
        onChanged();
      case DisplayRotation(:final mode, :final degrees):
        switch (mode) {
          case DisplayRotation.begin:
            if (!adjustingRotation) {
              adjustingRotation = true;
              _adjustAngle = rotation;
              menuOpen = false;
            }
            emit(DisplayAngle(_adjustAngle, adjusting: true));
            onChanged();
          case DisplayRotation.save:
            _endRotation(true);
          case DisplayRotation.set:
            adjustingRotation = true;
            _adjustAngle = degrees % 360;
            _endRotation(true);
          case DisplayRotation.cancel:
            _endRotation(false);
          default:
            emit(DisplayAngle(displayAngle, adjusting: adjustingRotation));
        }
      case TimerResult():
        // The action is done: the menu closes and the result is shown briefly.
        menuOpen = false;
        notice = message;
        _noticeTimer?.cancel();
        _noticeTimer = Timer(noticeTime, () {
          notice = null;
          onChanged();
        });
        onChanged();
      default:
        break;
    }
  }
}

/// [DeviceModel] behind an in-process MIDI connection.
class SimulatedDevice implements MidiConnection {
  SimulatedDevice({this.serial = const [0x02, 0x00, 0x51, 0x4D, 0x00, 0x01]}) {
    model.emit = (message) {
      if (_opened && !_input.isClosed) _input.add(encodeMessage(message));
    };
  }

  final DeviceModel model = DeviceModel();
  final List<int> serial;
  final MidiStreamParser _parser = MidiStreamParser();
  StreamController<Uint8List> _input = StreamController<Uint8List>();
  Timer? _heartbeat;
  bool _opened = false;

  @override
  String get name => 'Darkdial (Simulator)';

  @override
  Stream<Uint8List> get input => _input.stream;

  /// Makes the device usable for a new session, like plugging it in again.
  void open() {
    if (_input.isClosed || _input.hasListener) _input = StreamController<Uint8List>();
    _opened = true;
  }

  @override
  void send(Uint8List message) {
    if (!_opened) return;
    for (final raw in _parser.add(message)) {
      final decoded = decodeMessage(raw);
      if (decoded == null) continue;
      if (decoded is Status) {
        _heartbeat?.cancel();
        _heartbeat = Timer(DeviceModel.heartbeatTimeout, model.heartbeatLost);
      }
      model.handle(decoded, serial: serial);
    }
  }

  @override
  Future<void> close() async {
    _opened = false;
    _heartbeat?.cancel();
    model.dispose();
    model.heartbeatLost();
    if (!_input.isClosed) await _input.close();
  }
}

/// Transport that offers exactly one [SimulatedDevice].
class SimulatedTransport implements MidiTransport {
  SimulatedTransport(this.device);

  final SimulatedDevice device;
  final StreamController<MidiConnection> _connections = StreamController<MidiConnection>();

  @override
  Stream<MidiConnection> get connections => _connections.stream;

  @override
  Future<void> start() async {
    device.open();
    _connections.add(device);
  }

  @override
  Future<void> dispose() async {
    await device.close();
    await _connections.close();
  }
}
