import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:phone/core/fake_phone_core.dart';
import 'package:phone/core/phone_core.dart';
import 'package:phone/main.dart';
import 'package:phone/screens/active_call_page.dart';
import 'package:phone/screens/dialer_page.dart';
import 'package:phone/state/phone_controller.dart';

void _setPhoneViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(412, 915);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

void main() {
  testWidgets('unbound launch shows guide and dialpad enters digits', (tester) async {
    _setPhoneViewport(tester);
    await tester.pumpWidget(const SimHubPhoneApp());
    await tester.pumpAndSettle();

    expect(find.text('尚未绑定通话号码'), findsOneWidget);
    expect(find.text('扫码绑定号码'), findsOneWidget);
    expect(find.text('输入电话号码'), findsOneWidget);

    await tester.tap(find.text('1'));
    await tester.tap(find.text('0'));
    await tester.tap(find.text('0'));
    await tester.pump();

    expect(find.text('100'), findsOneWidget);

    await tester.tap(find.byTooltip('退格'));
    await tester.pump();

    expect(find.text('10'), findsOneWidget);
  });

  testWidgets('switches across history and numbers tabs with prominent scan action', (tester) async {
    _setPhoneViewport(tester);
    await tester.pumpWidget(const SimHubPhoneApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('记录'));
    await tester.pumpAndSettle();
    expect(find.textContaining('全部'), findsOneWidget);

    await tester.tap(find.text('号码'));
    await tester.pumpAndSettle();
    expect(find.text('扫码配置号码'), findsOneWidget);
    expect(find.text('连续批量扫码'), findsOneWidget);
    expect(find.text('粘贴配网链接'), findsWidgets);
  });

  testWidgets('incoming active call page shows caller and target bound number', (tester) async {
    _setPhoneViewport(tester);
    final core = FakePhoneCore(
      initialAccounts: const [
        SipAccountConfig(
          username: 'c_us1',
          phoneNumber: '+12025550187',
          domain: 'webrtc.local',
          registrarUri: 'sip:webrtc.local:5061;transport=tls',
          password: 'pw',
          label: '美区主线',
        ),
      ],
    );
    final controller = PhoneController(core: core);
    addTearDown(controller.dispose);
    await controller.start();

    core.simulateIncoming(peer: '+12025550199', ownNumber: '+12025550187');
    await tester.pumpWidget(
      MaterialApp(
        home: ActiveCallPage(controller: controller),
      ),
    );
    await tester.pump();

    expect(find.text('+12025550199'), findsOneWidget);
    expect(find.text('打给本机：+12025550187'), findsOneWidget);
    expect(find.text('美区主线'), findsOneWidget);
  });

  testWidgets('dialer displays and dismisses remote rejection banner', (tester) async {
    _setPhoneViewport(tester);
    final core = FakePhoneCore(
      initialAccounts: const [
        SipAccountConfig(
          username: 'c_us1',
          phoneNumber: '+12025550187',
          domain: 'webrtc.local',
          registrarUri: 'sip:webrtc.local:5061;transport=tls',
          password: 'pw',
          label: '美区主线',
        ),
      ],
    );
    final controller = PhoneController(core: core);
    addTearDown(controller.dispose);
    await controller.start();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DialerPage(controller: controller),
        ),
      ),
    );
    await tester.pump();

    controller.setNumber('9202');
    await controller.dial();
    core.simulateRemoteEnd(code: 486, reason: 'Busy Here');
    await tester.pump();
    await tester.pump();

    expect(find.text('对方正忙或已拒接 · 9202'), findsOneWidget);
    expect(find.text('对方正在通话中或挂断了来电。'), findsOneWidget);
    expect(find.text('重拨'), findsOneWidget);

    await tester.tap(find.byTooltip('关闭提醒'));
    await tester.pump();

    expect(find.text('对方正忙或已拒接 · 9202'), findsNothing);
  });
}
