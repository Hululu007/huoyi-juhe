import 'package:flutter/material.dart';

/// 切换站点弹窗：居中弹窗（非底部弹层），站点按四列网格排列，
/// 点一项即选中并关闭，返回该站 id；点空白或返回则返回 null。
/// 站多时网格在弹窗内滚动（最高占屏高六成），站少时弹窗按内容收缩。
Future<String?> showSiteGridDialog({
  required BuildContext context,
  required List<({String id, String name})> sites,
  String? selectedId,
}) async {
  if (sites.isEmpty) return null;
  final screenHeight = MediaQuery.of(context).size.height;
  return showDialog<String>(
    context: context,
    builder: (dialogContext) {
      final theme = Theme.of(dialogContext);
      final selectedColor = theme.colorScheme.primary;
      return Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: screenHeight * 0.6),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '切换站点',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                Flexible(
                  child: GridView.builder(
                    shrinkWrap: true,
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 4,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                      childAspectRatio: 1.4,
                    ),
                    itemCount: sites.length,
                    itemBuilder: (ctx, index) {
                      final site = sites[index];
                      final selected = site.id == selectedId;
                      return InkWell(
                        onTap: () =>
                            Navigator.pop(dialogContext, site.id),
                        borderRadius: BorderRadius.circular(10),
                        child: Container(
                          alignment: Alignment.center,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: selected
                                  ? selectedColor
                                  : theme.dividerColor,
                              width: selected ? 2 : 1,
                            ),
                            color: selected
                                ? selectedColor.withValues(alpha: 0.12)
                                : null,
                          ),
                          child: Text(
                            site.name,
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight:
                                  selected ? FontWeight.w600 : null,
                              color: selected ? selectedColor : null,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
