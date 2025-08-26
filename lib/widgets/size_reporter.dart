import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

class SizeReporter extends StatefulWidget {
  const SizeReporter({super.key, required this.child, required this.onHeight});
  final Widget child;
  final void Function(double height) onHeight;

  @override
  State<SizeReporter> createState() => _SizeReporterState();
}

class _SizeReporterState extends State<SizeReporter> {
  final _key = GlobalKey();

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _key.currentContext;
      if (ctx != null) {
        final size = (ctx.findRenderObject() as RenderBox?)?.size;
        if (size != null) widget.onHeight(size.height);
      }
    });
    return Container(key: _key, child: widget.child);
  }
}
