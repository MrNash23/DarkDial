/// A serial port on macOS through the C library (termios), just enough for
/// the bootloader: raw mode, a baud rate, reads with a timeout, writes, and
/// the DTR/RTS lines. Blocking calls: use it in a background isolate.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

final DynamicLibrary _libc = DynamicLibrary.process();

final int Function(Pointer<Utf8>, int) _open =
    _libc.lookupFunction<Int32 Function(Pointer<Utf8>, Int32), int Function(Pointer<Utf8>, int)>('open');
final int Function(int) _close = _libc.lookupFunction<Int32 Function(Int32), int Function(int)>('close');
final int Function(int, Pointer<Uint8>, int) _read =
    _libc.lookupFunction<IntPtr Function(Int32, Pointer<Uint8>, Size), int Function(int, Pointer<Uint8>, int)>('read');
final int Function(int, Pointer<Uint8>, int) _write =
    _libc.lookupFunction<IntPtr Function(Int32, Pointer<Uint8>, Size), int Function(int, Pointer<Uint8>, int)>('write');
final int Function(int, Pointer<Uint8>) _tcgetattr =
    _libc.lookupFunction<Int32 Function(Int32, Pointer<Uint8>), int Function(int, Pointer<Uint8>)>('tcgetattr');
final int Function(int, int, Pointer<Uint8>) _tcsetattr = _libc
    .lookupFunction<Int32 Function(Int32, Int32, Pointer<Uint8>), int Function(int, int, Pointer<Uint8>)>('tcsetattr');
final void Function(Pointer<Uint8>) _cfmakeraw =
    _libc.lookupFunction<Void Function(Pointer<Uint8>), void Function(Pointer<Uint8>)>('cfmakeraw');
final int Function(Pointer<Uint8>, int) _cfsetspeed =
    _libc.lookupFunction<Int32 Function(Pointer<Uint8>, UnsignedLong), int Function(Pointer<Uint8>, int)>('cfsetspeed');
final int Function(int) _tcdrain = _libc.lookupFunction<Int32 Function(Int32), int Function(int)>('tcdrain');
final int Function(int, int, Pointer<Int32>) _ioctlInt = _libc.lookupFunction<
    Int32 Function(Int32, UnsignedLong, VarArgs<(Pointer<Int32>,)>), int Function(int, int, Pointer<Int32>)>('ioctl');
final int Function(int, int) _ioctlPlain =
    _libc.lookupFunction<Int32 Function(Int32, UnsignedLong), int Function(int, int)>('ioctl');
final int Function(Pointer<Uint8>, int, int) _poll =
    _libc.lookupFunction<Int32 Function(Pointer<Uint8>, Uint32, Int32), int Function(Pointer<Uint8>, int, int)>('poll');

// macOS values.
const int _oRdwr = 0x2;
const int _oNonblock = 0x4;
const int _oNoctty = 0x20000;
const int _tcsanow = 0;
const int _tiocexcl = 0x2000740D;
const int _tiocmbis = 0x8004746C;
const int _tiocmbic = 0x8004746B;
const int _tiocmDtr = 0x2;
const int _tiocmRts = 0x4;
const int _pollin = 0x1;
// struct termios: c_cflag is the third 8-byte field; CLOCAL | CREAD keep the
// port usable without a modem.
const int _cflagOffset = 16;
const int _clocal = 0x8000;
const int _cread = 0x800;

class SerialError implements Exception {
  SerialError(this.message);
  final String message;
  @override
  String toString() => 'SerialError: $message';
}

class PosixSerialPort {
  PosixSerialPort._(this.name, this._fd);

  final String name;
  final int _fd;
  bool _closed = false;

  /// Serial ports of USB devices with a CDC interface; the ESP32 shows up
  /// as one, both running and in its bootloader.
  static List<String> usbModemPorts() {
    final dev = Directory('/dev');
    if (!dev.existsSync()) return const [];
    return [
      for (final entry in dev.listSync())
        if (entry.path.startsWith('/dev/cu.usbmodem')) entry.path,
    ]..sort();
  }

  /// Opens [name] raw at [baud], DTR and RTS as given.
  static PosixSerialPort open(String name, {int baud = 115200, bool dtr = false, bool rts = false}) {
    final path = name.toNativeUtf8();
    final fd = _open(path, _oRdwr | _oNoctty | _oNonblock);
    calloc.free(path);
    if (fd < 0) throw SerialError('cannot open $name');
    final port = PosixSerialPort._(name, fd);
    // Nobody else may open the port while we hold it: a second reader (a
    // serial monitor, say) would take the bootloader's answers away.
    _ioctlPlain(fd, _tiocexcl);
    final attrs = calloc<Uint8>(128); // struct termios is 72 bytes on macOS
    try {
      if (_tcgetattr(fd, attrs) != 0) throw SerialError('not a serial port: $name');
      _cfmakeraw(attrs);
      final cflag = (attrs + _cflagOffset).cast<Uint64>();
      cflag.value = cflag.value | _clocal | _cread;
      _cfsetspeed(attrs, baud);
      if (_tcsetattr(fd, _tcsanow, attrs) != 0) throw SerialError('cannot configure $name');
    } catch (_) {
      port.close();
      rethrow;
    } finally {
      calloc.free(attrs);
    }
    port.setSignals(dtr: dtr, rts: rts);
    return port;
  }

  void setSignals({required bool dtr, required bool rts}) {
    final bits = calloc<Int32>();
    try {
      bits.value = _tiocmDtr;
      _ioctlInt(_fd, dtr ? _tiocmbis : _tiocmbic, bits);
      bits.value = _tiocmRts;
      _ioctlInt(_fd, rts ? _tiocmbis : _tiocmbic, bits);
    } finally {
      calloc.free(bits);
    }
  }

  void write(List<int> bytes) {
    final buffer = calloc<Uint8>(bytes.length);
    try {
      buffer.asTypedList(bytes.length).setAll(0, bytes);
      var sent = 0;
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (sent < bytes.length) {
        final n = _write(_fd, buffer + sent, bytes.length - sent);
        if (n > 0) {
          sent += n;
        } else if (DateTime.now().isAfter(deadline)) {
          throw SerialError('write to $name timed out');
        } else {
          sleep(const Duration(milliseconds: 1));
        }
      }
      _tcdrain(_fd);
    } finally {
      calloc.free(buffer);
    }
  }

  /// What arrived, waiting up to [timeout] for the first byte.
  Uint8List read(Duration timeout) {
    final fds = calloc<Uint8>(8); // struct pollfd { int fd; short events; short revents; }
    final buffer = calloc<Uint8>(4096);
    try {
      fds.cast<Int32>().value = _fd;
      (fds + 4).cast<Int16>().value = _pollin;
      final ready = _poll(fds, 1, timeout.inMilliseconds.clamp(0, 60000));
      if (ready <= 0) return Uint8List(0);
      final n = _read(_fd, buffer, 4096);
      if (n <= 0) {
        // Readable but nothing to read: the device went away.
        if (n == 0) throw SerialError('$name is gone');
        return Uint8List(0);
      }
      return Uint8List.fromList(buffer.asTypedList(n));
    } finally {
      calloc.free(fds);
      calloc.free(buffer);
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _close(_fd);
  }
}
