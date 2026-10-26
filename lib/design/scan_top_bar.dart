import 'package:flutter/material.dart';

import 'scan_tokens.dart';

/// The 71.5 dp "My Scans" bar: flat, no shadow, centred 17 sp title.
///
/// Measured on a 384 dp viewport: the bar
/// is 201 px (71.5 dp) tall beneath the status bar, sits on the same #FAFAFA
/// surface as the list, and carries a 32 dp leading glyph inset 16 dp.
class ScanListTopBar extends StatelessWidget {
  const ScanListTopBar({
    super.key,
    required this.title,
    this.leading,
    this.trailing,
    this.titleColor = ScanColor.gray11,
  });

  final String title;
  final Widget? leading;
  final Widget? trailing;
  final Color titleColor;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: ScanSize.appBarHeight,
      child: Stack(
        children: [
          Center(
            child: Semantics(
              header: true,
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: ScanType.appBar,
                  fontWeight: FontWeight.w500,
                  color: titleColor,
                  height: 1.2,
                ),
              ),
            ),
          ),
          if (leading != null)
            Positioned(
              left: ScanSpace.xxs,
              top: 0,
              bottom: 0,
              child: Center(child: leading),
            ),
          if (trailing != null)
            Positioned(
              right: ScanSpace.xxs,
              top: 0,
              bottom: 0,
              child: Center(child: trailing),
            ),
        ],
      ),
    );
  }
}

/// A 48 dp flat icon action, matching the bar's affordances.
///
/// The glyph is 24 dp inside a 48 dp target — the app's only touch rhythm
/// (see [ScanSize.touch]).
class ScanBarAction extends StatelessWidget {
  const ScanBarAction({
    super.key,
    required this.icon,
    required this.onPressed,
    required this.semanticLabel,
    this.color = ScanColor.gray9,
    this.size = ScanSize.icon,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String semanticLabel;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: semanticLabel,
      child: SizedBox(
        width: ScanSize.touch,
        height: ScanSize.touch,
        child: InkResponse(
          onTap: onPressed,
          radius: 24,
          containedInkWell: true,
          highlightShape: BoxShape.circle,
          child: Icon(
            icon,
            size: size,
            color: enabled ? color : color.withValues(alpha: 0.38),
          ),
        ),
      ),
    );
  }
}
