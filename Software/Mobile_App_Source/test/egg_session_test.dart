import 'package:application_v2/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('classified Day 5-6 eggs are not also in review', () {
    final fertile = EggData()..status = EggStatus.fertile;
    final infertile = EggData()..status = EggStatus.infertile;
    final session = EggSession(
      id: 1,
      timestamp: DateTime(2026, 10, 9),
      fertileCount: 1,
      infertileCount: 1,
      temperature: null,
      humidity: null,
      occupiedSlots: [true, true, true, false],
      slotDays: [5, 6, 4, null],
      analyzedSlots: [0, 1],
      eggData: [fertile, infertile, EggData(), EggData()],
      columnCount: 2,
      rowCount: 2,
    );

    expect(session.analyzedSlotNumbers, [1, 2]);
    expect(session.readyEggCount, 2);
    expect(session.inReviewCount, 1);
    expect(session.waitingForDay5SlotNumbers, [3]);
    expect(session.researchStatusForSlot(0), 'Fertile');
    expect(session.researchStatusForSlot(1), 'Infertile');
    expect(session.researchStatusForSlot(2), 'In review - waiting for Day 5');

    final restored = EggSession.fromJson(session.toJson());
    expect(restored.inReviewCount, 1);
    expect(restored.researchStatusForSlot(0), 'Fertile');
  });

  test('saved verdict remains visible when recorded age is unavailable', () {
    final fertile = EggData()..status = EggStatus.fertile;
    final session = EggSession(
      id: 2,
      timestamp: DateTime(2026, 10, 9),
      fertileCount: 1,
      infertileCount: 0,
      temperature: null,
      humidity: null,
      occupiedSlots: [true],
      slotDays: [null],
      analyzedSlots: [0],
      eggData: [fertile],
      columnCount: 1,
      rowCount: 1,
    );

    expect(session.inReviewCount, 0);
    expect(session.researchStatusForSlot(0), 'Fertile');
  });

  test(
    'eight analyzed eggs show four fertile, four infertile, zero review',
    () {
      final eggs = [
        for (var index = 0; index < 8; index++)
          EggData()
            ..status = index < 4 ? EggStatus.fertile : EggStatus.infertile,
      ];
      final session = EggSession(
        id: 3,
        timestamp: DateTime(2026, 10, 9),
        fertileCount: 4,
        infertileCount: 4,
        temperature: null,
        humidity: null,
        occupiedSlots: List.filled(8, true),
        slotDays: List.filled(8, 6),
        analyzedSlots: List.generate(8, (index) => index),
        eggData: eggs,
        columnCount: 8,
        rowCount: 1,
      );

      expect(session.analyzedSlotCount, 8);
      expect(session.inReviewCount, 0);
      expect(session.researchStatusForSlot(7), 'Infertile');
      expect(EggSession.fromJson(session.toJson()).inReviewCount, 0);
    },
  );
}
