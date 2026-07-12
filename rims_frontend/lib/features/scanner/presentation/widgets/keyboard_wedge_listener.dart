import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

final class KeyboardWedgeListener extends StatefulWidget {
  const KeyboardWedgeListener({
    required this.child,
    required this.onBarcode,
    this.enabled = true,
    this.interKeyTimeout = const Duration(milliseconds: 80),
    super.key,
  });

  final Widget child;
  final ValueChanged<String> onBarcode;
  final bool enabled;
  final Duration interKeyTimeout;

  @override
  State<KeyboardWedgeListener> createState() => _KeyboardWedgeListenerState();
}

final class _KeyboardWedgeListenerState extends State<KeyboardWedgeListener> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'keyboard-wedge');
  final StringBuffer _buffer = StringBuffer();
  Timer? _resetTimer;

  @override
  void didUpdateWidget(covariant KeyboardWedgeListener oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.enabled && widget.enabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusNode.requestFocus();
      });
    } else if (oldWidget.enabled && !widget.enabled) {
      _clear();
      _focusNode.unfocus();
    }
  }

  @override
  void dispose() {
    _resetTimer?.cancel();
    _focusNode.dispose();
    super.dispose();
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (!widget.enabled || event is! KeyDownEvent || _editableOwnsFocus()) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      final barcode = _buffer.toString();
      _clear();
      if (barcode.isNotEmpty) widget.onBarcode(barcode);
      return barcode.isEmpty ? KeyEventResult.ignored : KeyEventResult.handled;
    }
    final character = event.character;
    if (character == null || character.length != 1) {
      return KeyEventResult.ignored;
    }
    final code = character.codeUnitAt(0);
    if (code < 0x20 || code > 0x7e) return KeyEventResult.ignored;
    _buffer.write(character);
    _resetTimer?.cancel();
    _resetTimer = Timer(widget.interKeyTimeout, _clear);
    return KeyEventResult.handled;
  }

  bool _editableOwnsFocus() {
    final context = FocusManager.instance.primaryFocus?.context;
    return context?.widget is EditableText ||
        context?.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  void _clear() {
    _resetTimer?.cancel();
    _resetTimer = null;
    _buffer.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      autofocus: widget.enabled,
      onKeyEvent: _handleKey,
      child: widget.child,
    );
  }
}
