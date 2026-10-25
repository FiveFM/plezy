import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Riven's mountain mark, tinted with the ambient icon color like
/// `CatalogSourceLogo`. Kept apart from that widget's table on purpose: its
/// key is `CatalogSourceId`, which is persisted and switched over as the
/// identity of Explore catalog sources, and Riven serves no catalog.
class RivenMark extends StatelessWidget {
  final double size;

  const RivenMark({super.key, this.size = 20});

  @override
  Widget build(BuildContext context) {
    final color = IconTheme.of(context).color ?? Theme.of(context).colorScheme.onSurface;
    return SvgPicture.asset(
      'assets/riven_mark.svg',
      width: size,
      height: size,
      theme: SvgTheme(currentColor: color),
    );
  }
}
