import 'package:flutter/material.dart';

/// 桌面窗口下把内容约束为居中的竖屏"手机舞台"，保证演示效果
/// 与设计稿（9:19 竖屏）一致；窗口较小时直接铺满。
class PhoneStage extends StatelessWidget {
  const PhoneStage({super.key, required this.child});

  final Widget child;

  static const double _aspect = 9 / 19.3;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth <= 500) {
          return child;
        }
        double h = constraints.maxHeight;
        double w = h * _aspect;
        if (w > constraints.maxWidth) {
          w = constraints.maxWidth;
          h = w / _aspect;
        }
        return ColoredBox(
          color: Colors.black,
          child: Center(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(28),
              child: SizedBox(width: w, height: h, child: child),
            ),
          ),
        );
      },
    );
  }
}
