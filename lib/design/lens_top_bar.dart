import 'package:flutter/material.dart';

import 'lens_tokens.dart';

/// The 71.5 dp "My Scans" bar: flat, no shadow, centred 17 sp title.
///
/// Measured from `com.microsoft.office.officelens` on a 384 dp viewport: the bar
/// is 201 px (71.5 dp) tall beneath the status bar, sits on the same #FAFAFA
/// surface as the list, and carries a 32 dp leading glyph inset 16 dp.
class LensListTopBar extends StatelessWidget {
  const LensListTopBar({
    super.key,
    required this.title,
    this.leading,
    this.trailing,
    this.titleColor = LensColor.gray11,
  });

  final String title;
  final Widget? leading;
  final Widget? trailing;
  final Color titleColor;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: LensSize.appBarHeight,
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
                  fontSize: LensType.appBar,
                  fontWeight: FontWeight.w500,
                  color: titleColor,
                  height: 1.2,
                ),
              ),
            ),
          ),
          if (leading != null)
            Positioned(
              left: LensSpace.xxs,
              top: 0,
              bottom: 0,
              child: Center(child: leading),
            ),
          if (trailing != null)
            Positioned(
              right: LensSpace.xxs,
              top: 0,
              bottom: 0,
              child: Center(child: trailing),
            ),
        ],
      ),
    );
  }
}

/// A 48 dp flat icon action, matching Lens's bar affordances.
///
/// The glyph is 24 dp inside a 48 dp target — the app's only touch rhythm
/// (see [LensSize.touch]).
class LensBarAction extends StatelessWidget {
  const LensBarAction({
    super.key,
    required this.icon,
    required this.onPressed,
    required this.semanticLabel,
    this.color = LensColor.gray9,
    this.size = LensSize.icon,
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
        width: LensSize.touch,
        height: LensSize.touch,
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
