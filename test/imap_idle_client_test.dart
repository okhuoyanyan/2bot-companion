import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:bot_companion/services/calendar_mail_extract.dart';
import 'package:bot_companion/services/imap_idle_client.dart';
import 'package:bot_companion/utils/constants.dart';

/// ============================================================================
/// WO-69 · IMAP 装配器 / 解析函数 / 邮件附件提取 单测（全部零 IO 纯逻辑）
/// ============================================================================
/// 对齐 NAS 侧「QQ 邮箱 IMAP 平台真相表」：
///  - 文本搜索键（SUBJECT/TEXT）被 QQ 忽略 → 手机侧必须客户端精筛（本组测试钉死该行为）；
///  - literal 响应可能被 TCP 任意分片 → 装配器必须按字节数判定收满；
///  - flag 落不上 → 客户端只读（无任何 STORE 命令暴露在冻结命令面）。
void main() {
  group('ImapAssembler：literal 字节精确装配', () {
    test('单分片：普通行逐条成单元', () {
      final a = ImapAssembler();
      a.add('* OK [CAPABILITY IMAP4rev1 IDLE] ready\r\n* 5 EXISTS\r\n'.codeUnits);
      final units = a.takeUnits();
      expect(units, hasLength(2));
      expect(units[0].head, '* OK [CAPABILITY IMAP4rev1 IDLE] ready');
      expect(units[1].head, '* 5 EXISTS');
    });

    test('任意分片：按字节逐个喂入仍正确装配', () {
      final a = ImapAssembler();
      final bytes = 'A001 OK LOGIN completed\r\n* 3 EXISTS\r\n'.codeUnits;
      for (final b in bytes) {
        a.add([b]);
      }
      final units = a.takeUnits();
      expect(units, hasLength(2));
      expect(units[0].tag, 'A001');
      expect(units[0].status, 'OK');
      expect(units[1].head, '* 3 EXISTS');
    });

    test('literal 跨分片：FETCH 响应 {n} 未收满不得成单元', () {
      final a = ImapAssembler();
      const literal = 'SUBJECT: X-2BOT-CAL';
      final headLine =
          '* 1 FETCH (UID 869 BODY[HEADER.FIELDS (SUBJECT)] {${literal.length}}\r\n';
      a.add(headLine.codeUnits);
      expect(a.hasUnits, isFalse, reason: 'literal 未收满必须等待');

      a.add('SUBJECT: X-2BOT-CA'.codeUnits);
      expect(a.hasUnits, isFalse, reason: 'literal 仍差 1 字节');

      a.add('L'.codeUnits); // 补满 literal（literal 自身不含 CRLF）
      a.add(')\r\n'.codeUnits);
      final units = a.takeUnits();
      expect(units, hasLength(2));
      expect(units[0].head, headLine.replaceAll('\r\n', ''));
      expect(units[0].literals.single, 'SUBJECT: X-2BOT-CAL');
      expect(units[1].head, ')', reason: 'literal 后的 `)` 是独立行单元');
    });

    test('UTF-8 literal 多字节边界安全（allowMalformed 兜底不抛）', () {
      final a = ImapAssembler();
      final literalBytes = utf8.encode('体检提醒'); // 12 字节
      final head =
          '* 2 FETCH (UID 870 BODY[] {${literalBytes.length}}\r\n';
      a.add(head.codeUnits);
      a.add(literalBytes);
      a.add(')\r\n'.codeUnits);
      final units = a.takeUnits();
      expect(units.first.literals.single, '体检提醒');
    });
  });

  group('客户端精筛与响应解析（QQ 文本搜索键不可用的替代）', () {
    test('subjectMatchesPrefix：前缀命中 / 不命中 / 无 SUBJECT 头', () {
      expect(
        subjectMatchesPrefix('SUBJECT: X-2BOT-CAL-20260927-0930\r\n',
            AppConstants.calSubjectPrefix),
        isTrue,
      );
      expect(
        subjectMatchesPrefix(
            'Subject: X-2BOT-TEL-123456789\r\n', AppConstants.calSubjectPrefix),
        isFalse,
        reason: '遥测件不得误判为日历件',
      );
      expect(
        subjectMatchesPrefix('From: a@b.c\r\n', AppConstants.calSubjectPrefix),
        isFalse,
      );
    });

    test('parseSearchUids 与空 SEARCH', () {
      expect(
        parseSearchUids([const ImapUnit('* SEARCH 869 870 871', [])]),
        [869, 870, 871],
      );
      expect(parseSearchUids([const ImapUnit('* SEARCH', [])]), isEmpty);
    });

    test('parseUidValidity：SELECT 响应提取', () {
      expect(
        parseUidValidity([
          const ImapUnit('* 42 EXISTS', []),
          const ImapUnit('* OK [UIDVALIDITY 1789989266] UIDs valid', []),
        ]),
        1789989266,
      );
      expect(parseUidValidity([const ImapUnit('* OK done', [])]), isNull);
    });

    test('parseHeaderFetchUnit / parseFullFetchUnit：UID 与 literal 提取', () {
      final hdr = parseHeaderFetchUnit(const ImapUnit(
          '* 1 FETCH (UID 869 BODY[HEADER.FIELDS (SUBJECT)] {17}',
          ['SUBJECT: X-2BOT-CAL']));
      expect(hdr!.uid, 869);
      final full =
          parseFullFetchUnit(const ImapUnit('* 2 FETCH (UID 870 BODY[] {5}', ['hello']));
      expect(full!.uid, 870);
      expect(full.raw, 'hello');
      expect(parseHeaderFetchUnit(const ImapUnit('* 3 EXISTS', [])), isNull);
    });
  });

  group('日历邮件附件提取（WO-68-SPEC §7 契约形态）', () {
    test('契约主路径：multipart/mixed + base64 的 calendar.ics（76 字符折行）', () {
      const ics =
          'BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:x\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n';
      final encoded = base64.encode(utf8.encode(ics));
      final buf = StringBuffer();
      for (var i = 0; i < encoded.length; i += 76) {
        final end =
            (i + 76) < encoded.length ? i + 76 : encoded.length;
        buf.write(encoded.substring(i, end));
        buf.write('\r\n');
      }
      final mail = 'From: nas@2bot\r\n'
          'Subject: X-2BOT-CAL-20260927-0930\r\n'
          'MIME-Version: 1.0\r\n'
          'Content-Type: multipart/mixed; boundary="BOUND1"\r\n'
          '\r\n'
          '--BOUND1\r\n'
          'Content-Type: text/plain; charset=utf-8\r\n'
          '\r\n'
          '2BOT 日历投递\r\n'
          '--BOUND1\r\n'
          'Content-Type: text/calendar; charset=utf-8; name=calendar.ics\r\n'
          'Content-Disposition: attachment; filename=calendar.ics\r\n'
          'Content-Transfer-Encoding: base64\r\n'
          '\r\n'
          '${buf.toString()}'
          '--BOUND1--\r\n';
      expect(extractIcsFromMail(mail), ics);
    });

    test('加分路径：quoted-printable（软换行拼接 + =0D=0A 硬换行）', () {
      const mail = 'Content-Type: multipart/mixed; boundary=b2\r\n\r\n'
          '--b2\r\n'
          'Content-Type: text/calendar\r\n'
          'Content-Transfer-Encoding: quoted-printable\r\n'
          '\r\n'
          'BEGIN:VCAL=\r\n'
          'ENDAR=0D=0A\r\n'
          '--b2--\r\n';
      expect(extractIcsFromMail(mail), 'BEGIN:VCALENDAR\r\n');
    });

    test('结构超契约（无 ICS 附件 / 非 multipart 非日历）→ null 不造数据', () {
      const plainMail = 'Content-Type: text/plain\r\n\r\nhello';
      expect(extractIcsFromMail(plainMail), isNull);
      const noIcsMultipart = 'Content-Type: multipart/mixed; boundary=b3\r\n\r\n'
          '--b3\r\n'
          'Content-Type: text/plain\r\n'
          '\r\n'
          'nothing here\r\n'
          '--b3--\r\n';
      expect(extractIcsFromMail(noIcsMultipart), isNull);
      expect(extractIcsFromMail('garbage'), isNull);
    });
  });
}
