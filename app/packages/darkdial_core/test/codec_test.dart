import 'dart:typed_data';

import 'package:darkdial_core/darkdial_core.dart';
import 'package:test/test.dart';

void main() {
  group('pack7', () {
    test('round-trips every length around the group size', () {
      for (var length = 0; length <= 30; length++) {
        final data = [for (var i = 0; i < length; i++) (i * 37 + 200) & 0xFF];
        final packed = pack7(data);
        expect(packed.every((b) => b < 0x80), isTrue, reason: 'length $length');
        expect(unpack7(packed), data, reason: 'length $length');
      }
    });

    test('matches the layout in the specification', () {
      // MSB byte first, bit 0 = first data byte.
      expect(pack7([0x80, 0x01, 0xFF]), [0x05, 0x00, 0x01, 0x7F]);
    });
  });

  test('crc16 is CCITT-FALSE', () {
    expect(crc16('123456789'.codeUnits), 0x29B1);
  });

  group('messages', () {
    test('rotation is a relative CC', () {
      expect(encodeMessage(const Rotation(3)), [0xB0, 0x10, 67]);
      expect(encodeMessage(const Rotation(-3)), [0xB0, 0x10, 61]);
      expect((decodeMessage([0xB0, 0x10, 61]) as Rotation).delta, -3);
      expect(decodeMessage([0xB0, 0x10, 64]), isNull);
      expect(decodeMessage([0xB0, 0x11, 70]), isNull);
    });

    test('identity request and reply use the standard form', () {
      expect(encodeMessage(const IdentityRequest()), [0xF0, 0x7E, 0x7F, 0x06, 0x01, 0xF7]);
      final reply = decodeMessage(encodeMessage(const IdentityReply(1, 0, 4, 2))) as IdentityReply;
      expect([reply.model, reply.fwMajor, reply.fwMinor, reply.fwPatch], [1, 0, 4, 2]);
    });

    test('frame starts with manufacturer, signature and version', () {
      final bytes = encodeMessage(const SlotSelect(5));
      expect(bytes.sublist(0, 6), [0xF0, 0x7D, 0x44, 0x44, 1, 0x02]);
      expect(bytes.last, 0xF7);
    });

    test('hello round-trips', () {
      const hello = Hello(
        major: 1,
        minor: 0,
        fwMajor: 0,
        fwMinor: 1,
        fwPatch: 7,
        serial: [0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0xFF],
        configCrc: 0xBEEF,
      );
      final decoded = decodeMessage(encodeMessage(hello)) as Hello;
      expect(decoded.firmwareVersion, '0.1.7');
      expect(decoded.serialText, 'DEADBEEF00FF');
      expect(decoded.configCrc, 0xBEEF);
    });

    test('config slot keeps umlauts and stays within the SysEx size limit', () {
      const slot = ConfigSlot(
        index: 12,
        paramId: 13,
        iconId: 13,
        bipolar: true,
        color: 0xE5392F,
        label: 'Sättigung',
      );
      final bytes = encodeMessage(slot);
      expect(bytes.length, lessThanOrEqualTo(64));
      expect(bytes.sublist(1, bytes.length - 1).every((b) => b < 0x80), isTrue);
      final decoded = decodeMessage(bytes) as ConfigSlot;
      expect(decoded.label, 'Sättigung');
      expect(decoded.color, 0xE5392F);
      expect(decoded.bipolar, isTrue);
      expect(decoded.index, 12);
    });

    test('over-long label is cut on a character boundary', () {
      const slot = ConfigSlot(index: 0, paramId: 1, iconId: 1, bipolar: false, color: 0, label: 'ääääääääääää');
      final decoded = decodeMessage(encodeMessage(slot)) as ConfigSlot;
      expect(decoded.label, 'ääääääääää');
      expect(encodeMessage(slot).length, lessThanOrEqualTo(64));
    });

    test('value and status round-trip', () {
      final value =
          decodeMessage(encodeMessage(const Value(slot: 3, position: 16383, valid: true, text: '+1.35'))) as Value;
      expect([value.slot, value.position, value.valid, value.text], [3, 16383, true, '+1.35']);
      final status = decodeMessage(encodeMessage(
        const Status(lightroomConnected: true, developActive: false, photoSelected: true, notice: 1),
      )) as Status;
      expect([status.lightroomConnected, status.developActive, status.photoSelected, status.notice],
          [true, false, true, 1]);
    });

    test('time tracking messages round-trip within the size limit', () {
      final start = decodeMessage(encodeMessage(const TimerStart(newJobId))) as TimerStart;
      expect(start.jobId, newJobId);
      expect(decodeMessage(encodeMessage(const TimerStart(70000))), isA<TimerStart>().having((m) => m.jobId, 'id', 70000));
      expect(decodeMessage(encodeMessage(const TimerStop())), isA<TimerStop>());
      expect(decodeMessage(encodeMessage(const JobListRequest())), isA<JobListRequest>());
      expect((decodeMessage(encodeMessage(const JobListBegin(13))) as JobListBegin).count, 13);
      expect(decodeMessage(encodeMessage(const JobListEnd())), isA<JobListEnd>());

      const item = JobItem(index: 2, id: 4000000000, suggested: true, running: false, label: 'Müller Hochzeit 2026 Potsdam');
      final itemBytes = encodeMessage(item);
      expect(itemBytes.length, lessThanOrEqualTo(64));
      final decodedItem = decodeMessage(itemBytes) as JobItem;
      expect([decodedItem.index, decodedItem.id, decodedItem.suggested, decodedItem.running],
          [2, 4000000000, true, false]);
      expect(decodedItem.label, 'Müller Hochzeit 202', reason: 'cut to 20 bytes; ü takes two');

      const state = TimerState(running: true, jobId: 7, elapsedSeconds: 360000, label: '01.10. 14:32 und länger');
      final stateBytes = encodeMessage(state);
      expect(stateBytes.length, lessThanOrEqualTo(64));
      final decodedState = decodeMessage(stateBytes) as TimerState;
      expect([decodedState.running, decodedState.jobId, decodedState.elapsedSeconds], [true, 7, 360000]);

      final result = decodeMessage(encodeMessage(const TimerResult(TimerResult.error, 'Archiviert'))) as TimerResult;
      expect([result.code, result.text], [2, 'Archiviert']);
    });

    test('unknown, foreign and truncated messages decode to null', () {
      expect(decodeMessage([0xF0, 0x7D, 0x44, 0x44, 1, 0x7A, 0xF7]), isNull);
      expect(decodeMessage([0xF0, 0x41, 0x10, 0x00, 0x00, 0xF7]), isNull);
      expect(decodeMessage([0xF0, 0x7D, 0x44, 0x44, 2, 0x02, 0x00, 0x05, 0xF7]), isNull, reason: 'other major');
      expect(decodeMessage([0xF0, 0x7D, 0x44, 0x44, 1, 0x45, 0xF7]), isNull);
      expect(decodeMessage([0x90, 60, 100]), isNull);
    });

    test('config CRC depends on order and content', () {
      const a = ConfigSlot(index: 0, paramId: 3, iconId: 3, bipolar: true, color: 0, label: 'Exposure');
      const b = ConfigSlot(index: 1, paramId: 4, iconId: 4, bipolar: true, color: 0, label: 'Contrast');
      expect(configCrc([a, b]), isNot(configCrc([b, a])));
      expect(configCrc([a, b]), configCrc([a, b]));
    });
  });

  group('MidiStreamParser', () {
    test('splits several messages in one chunk', () {
      final parser = MidiStreamParser();
      final chunk = [...encodeMessage(const Rotation(1)), ...encodeMessage(const SlotFocus(2)), 0xB0, 0x10, 60];
      final messages = parser.add(chunk);
      expect(messages, hasLength(3));
      expect(decodeMessage(messages[1]), isA<SlotFocus>());
      expect((decodeMessage(messages[2]) as Rotation).delta, -4);
    });

    test('joins a SysEx split over chunks and skips real-time bytes', () {
      final parser = MidiStreamParser();
      final bytes = encodeMessage(const SlotSelect(9));
      expect(parser.add(bytes.sublist(0, 4)), isEmpty);
      expect(parser.add([0xF8]), isEmpty);
      final messages = parser.add(bytes.sublist(4));
      expect(messages.single, Uint8List.fromList(bytes));
    });

    test('recovers after an aborted SysEx', () {
      final parser = MidiStreamParser();
      expect(parser.add([0xF0, 0x7D, 0x44]), isEmpty);
      final messages = parser.add([0xB0, 0x10, 65]);
      expect((decodeMessage(messages.single) as Rotation).delta, 1);
    });
  });
}
