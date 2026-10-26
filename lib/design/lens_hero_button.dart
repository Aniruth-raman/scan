import 'package:flutter/material.dart';

import 'lens_tokens.dart';

/// The 40 dp accent pill — the app's only primary-action shape.
///
/// Press-scale and the busy state live here so the crop stage and the review
/// stage cannot drift apart: both hand off through the same control.
class LensHeroButton extends StatefulWidget {
  const LensHeroButton({
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
  State<LensHeroButton> createState() => _LensHeroButtonState();
}

class _LensHeroButtonState extends State<LensHeroButton> {
  bool _pressed = false;

  String get _label => widget.busy ? (widget.busyLabel ?? widget.label) : widget.label;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null && !widget.busy;
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.label,
      child: AnimatedScale(
        scale: _pressed ? 0.98 : 1,
        duration: LensMotion.fast,
        curve: LensMotion.curve,
        child: SizedBox(
          height: LensSize.heroHeight,
          child: Material(
            color: enabled ? LensColor.accent : LensColor.disabled,
            borderRadius: BorderRadius.circular(LensRadius.hero),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              // The pill itself owns the press, so the scale never fights the
              // ink ripple for the gesture.
              onTap: enabled ? widget.onTap : null,
              onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
              onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
              onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.busy)
                      const Padding(
                        padding: EdgeInsets.only(right: LensSpace.xs),
                        child: SizedBox(
                          width: LensSize.iconSmall,
                          height: LensSize.iconSmall,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: LensColor.gray11,
                          ),
                        ),
                      )
                    else if (widget.leading != null) ...[
                      widget.leading!,
                      const SizedBox(width: LensSpace.xs),
                    ],
                    Text(
                      _label,
                      style: const TextStyle(
                        fontSize: LensType.body,
                        fontWeight: FontWeight.w500,
                        color: LensColor.gray11,
                      ),
                    ),
                    if (!widget.busy && widget.trailing != null) ...[
                      const SizedBox(width: LensSpace.xs),
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
