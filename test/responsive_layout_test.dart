import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chipatala/widgets/authScafold.dart';
import 'package:chipatala/widgets/branding.dart';

void main() {
  Widget buildTestWidget({required Size surfaceSize}) {
    return MediaQuery(
      data: MediaQueryData(size: surfaceSize),
      child: MaterialApp(
        home: AuthScaffold(
          title: 'Test Title',
          subtitle: 'Test Subtitle',
          form: Column(
            children: [
              AppTextField(
                label: 'Email',
                controller: TextEditingController(),
              ),
              const SizedBox(height: 16),
              PrimaryButton(label: 'Submit', onPressed: () {}),
            ],
          ),
          footerLink: const SwitchAuthLink(
            question: "Don't have an account?",
            actionLabel: 'Sign up',
            onTap: _noop,
          ),
        ),
      ),
    );
  }

  testWidgets('AuthScaffold renders correctly on small phone (320x568)', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(buildTestWidget(surfaceSize: const Size(320, 568)));
    await tester.pumpAndSettle();

    expect(find.text('Test Title'), findsOneWidget);
    expect(find.text('Test Subtitle'), findsOneWidget);
    expect(find.text('Submit'), findsOneWidget);
    expect(find.text('JayTech Solutions'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AuthScaffold renders correctly on standard phone (390x844)', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(buildTestWidget(surfaceSize: const Size(390, 844)));
    await tester.pumpAndSettle();

    expect(find.text('Test Title'), findsOneWidget);
    expect(find.text('Test Subtitle'), findsOneWidget);
    expect(find.text('Submit'), findsOneWidget);
    expect(find.text('JayTech Solutions'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AuthScaffold renders correctly on tablet portrait (768x1024)', (tester) async {
    tester.view.physicalSize = const Size(768, 1024);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(buildTestWidget(surfaceSize: const Size(768, 1024)));
    await tester.pumpAndSettle();

    expect(find.text('Test Title'), findsOneWidget);
    expect(find.text('Test Subtitle'), findsOneWidget);
    expect(find.text('Submit'), findsOneWidget);
    expect(find.text('JayTech Solutions'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AuthScaffold renders correctly on desktop widescreen (1920x1080)', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(buildTestWidget(surfaceSize: const Size(1920, 1080)));
    await tester.pumpAndSettle();

    expect(find.text('Tumaini Investments'), findsOneWidget);
    expect(find.text('Point of sale & inventory management'), findsOneWidget);
    expect(find.text('Test Title'), findsOneWidget);
    expect(find.text('Submit'), findsOneWidget);
    expect(find.text('JayTech Solutions'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AuthScaffold renders correctly on short desktop window (1024x500)', (tester) async {
    tester.view.physicalSize = const Size(1024, 500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(buildTestWidget(surfaceSize: const Size(1024, 500)));
    await tester.pumpAndSettle();

    expect(find.text('Tumaini Investments'), findsOneWidget);
    expect(find.text('Test Title'), findsOneWidget);
    expect(find.text('Submit'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

void _noop() {}
