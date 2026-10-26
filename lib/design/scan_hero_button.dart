import 'package:flutter/material.dart';

import 'scan_tokens.dart';

/// The 40 dp accent pill — the app's only primary-action shape.
///
/// Press-scale and the busy state live here so the crop stage and the review
/// stage cannot drift apart: both hand off through the same control.
class ScanHeroButton extends StatefulWidget {
  const ScanHeroButton({
    super.key,
    required this.label,
    required this.onTap,
    this.busy = false,
    this.busyLabel,
    this.leading,
    this.trailing,
  });

  final String label;
  final VoidCallback? onTap;

  /// Shows a spinner in place of [leading] and [busyLabel] in place of [label].
  final bool busy;
  final String? busyLabel;

  /// 24 dp glyph or progress indicator before the label.
  final Widget? leading;

  /// 18 dp glyph after the label, e.g. the crop stage's chevron.
  final Widget? trailing;

  @override
  State<ScanHeroButton> createState() => _ScanHeroButtonState();
}

class _ScanHeroButtonState extends State<ScanHeroButton> {
  bool _pressed = false;

  String get _label =>
      widget.busy ? (widget.busyLabel ?? widget.label) : widget.label;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null && !widget.busy;
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.label,
      child: AnimatedScale(
        scale: _pressed ? 0.98 : 1,
        duration: ScanMotion.fast,
        curve: ScanMotion.curve,
        child: SizedBox(
          height: ScanSize.heroHeight,
          child: Material(
            color: enabled ? ScanColor.accent : ScanColor.disabled,
            borderRadius: BorderRadius.circular(ScanRadius.hero),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              // The pill itself owns the press, so the scale never fights the
              // ink ripple for the gesture.
              onTap: enabled ? widget.onTap : null,
              onTapDown: enabled
                  ? (_) => setState(() => _pressed = true)
                  : null,
              onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
              onTapCancel: enabled
                  ? () => setState(() => _pressed = false)
                  : null,
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.busy)
                      const Padding(
                        padding: EdgeInsets.only(right: ScanSpace.xs),
                        child: SizedBox(
                          width: ScanSize.iconSmall,
                          height: ScanSize.iconSmall,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: ScanColor.gray0,
                          ),
                        ),
                      )
                    else if (widget.leading != null) ...[
                      widget.leading!,
                      const SizedBox(width: ScanSpace.xs),
                    ],
                    Text(
                      _label,
                      style: const TextStyle(
                        fontSize: ScanType.body,
                        fontWeight: FontWeight.w500,
                        color: ScanColor.gray0,
                      ),
                    ),
                    if (!widget.busy && widget.trailing != null) ...[
                      const SizedBox(width: ScanSpace.xs),
                      widget.trailing!,
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
