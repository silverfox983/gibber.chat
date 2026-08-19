import 'package:flutter/material.dart';
import '../breakpoints.dart';

enum SplitViewState { none, one, two }

class SplitView extends StatefulWidget {
  final Widget master;
  final Widget? detail;
  final Widget? secondaryDetail;
  final SplitViewState state;
  final bool showMasterInExpanded;
  final double masterWidth;
  final double secondaryWidth;
  final Duration animationDuration;
  final Curve animationCurve;

  const SplitView({
    super.key,
    required this.master,
    this.detail,
    this.secondaryDetail,
    this.state = SplitViewState.none,
    this.showMasterInExpanded = true,
    this.masterWidth = 320,
    this.secondaryWidth = 380,
    this.animationDuration = const Duration(milliseconds: 250),
    this.animationCurve = Curves.easeInOut,
  });

  @override
  State<SplitView> createState() => _SplitViewState();
}

class _SplitViewState extends State<SplitView> {
  @override
  Widget build(BuildContext context) {
    final size = Breakpoints.getSize(context);
    final theme = Theme.of(context);

    switch (size) {
      case ScreenSize.compact:
        return _buildCompact(context, theme);
      case ScreenSize.medium:
        return _buildMedium(context, theme);
      case ScreenSize.expanded:
        return _buildExpanded(context, theme);
    }
  }

  Widget _buildCompact(BuildContext context, ThemeData theme) {
    switch (widget.state) {
      case SplitViewState.none:
        return widget.master;
      case SplitViewState.one:
        return widget.detail ?? widget.master;
      case SplitViewState.two:
        return widget.secondaryDetail ?? widget.detail ?? widget.master;
    }
  }

  Widget _buildMedium(BuildContext context, ThemeData theme) {
    return Row(
      children: [
        SizedBox(
          width: Breakpoints.mediumRailWidth.toDouble(),
          child: widget.master,
        ),
        VerticalDivider(width: 1, color: theme.colorScheme.outlineVariant),
        Expanded(
          child: AnimatedSwitcher(
            duration: widget.animationDuration,
            switchInCurve: widget.animationCurve,
            switchOutCurve: widget.animationCurve,
            transitionBuilder: (child, animation) {
              return FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0.05, 0),
                    end: Offset.zero,
                  ).animate(animation),
                  child: child,
                ),
              );
            },
            child: _getDetailWidget(key: ValueKey(widget.state)),
          ),
        ),
      ],
    );
  }

  Widget _buildExpanded(BuildContext context, ThemeData theme) {
    final hasDetail = widget.state != SplitViewState.none;
    final hasSecondary = widget.state == SplitViewState.two;

    if (!hasDetail) {
      return widget.master;
    }

    return Row(
      children: [
        if (widget.showMasterInExpanded)
          SizedBox(
            width: widget.masterWidth,
            child: widget.master,
          ),
        if (widget.showMasterInExpanded)
          VerticalDivider(width: 1, color: theme.colorScheme.outlineVariant),
        Expanded(
          child: AnimatedSwitcher(
            duration: widget.animationDuration,
            switchInCurve: widget.animationCurve,
            switchOutCurve: widget.animationCurve,
            transitionBuilder: (child, animation) {
              return FadeTransition(opacity: animation, child: child);
            },
            child: _getDetailWidget(key: ValueKey('detail_${widget.state}')),
          ),
        ),
        if (hasSecondary) ...[
          VerticalDivider(width: 1, color: theme.colorScheme.outlineVariant),
          SizedBox(
            width: widget.secondaryWidth,
            child: widget.secondaryDetail,
          ),
        ],
      ],
    );
  }

  Widget _getDetailWidget({Key? key}) {
    switch (widget.state) {
      case SplitViewState.none:
        return Container(
          key: key,
          color: Theme.of(context).scaffoldBackgroundColor,
          child: const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.chat_bubble_outline_rounded, size: 48, color: Colors.grey),
                SizedBox(height: 16),
                Text('Select a conversation', style: TextStyle(color: Colors.grey)),
              ],
            ),
          ),
        );
      case SplitViewState.one:
        return Container(
          key: key,
          color: Theme.of(context).scaffoldBackgroundColor,
          child: widget.detail ?? const SizedBox.shrink(),
        );
      case SplitViewState.two:
        return Container(
          key: key,
          color: Theme.of(context).scaffoldBackgroundColor,
          child: widget.secondaryDetail ?? widget.detail ?? const SizedBox.shrink(),
        );
    }
  }
}

class MasterDetailSplitter extends StatelessWidget {
  final double initialRatio;
  final double minRatio;
  final double maxRatio;
  final VoidCallback? onSplitterDragStart;
  final VoidCallback? onSplitterDragEnd;
  final ValueChanged<double>? onRatioChanged;

  const MasterDetailSplitter({
    super.key,
    this.initialRatio = 0.4,
    this.minRatio = 0.2,
    this.maxRatio = 0.7,
    this.onSplitterDragStart,
    this.onSplitterDragEnd,
    this.onRatioChanged,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: (_) => onSplitterDragStart?.call(),
      onHorizontalDragEnd: (_) => onSplitterDragEnd?.call(),
      onHorizontalDragUpdate: (details) {
        final box = context.findRenderObject() as RenderBox?;
        if (box != null) {
          final width = box.size.width;
          final ratio = (details.localPosition.dx / width).clamp(minRatio, maxRatio);
          onRatioChanged?.call(ratio);
        }
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeColumn,
        child: SizedBox(
          width: 8,
          child: Center(
            child: Container(
              width: 1,
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
        ),
      ),
    );
  }
}
