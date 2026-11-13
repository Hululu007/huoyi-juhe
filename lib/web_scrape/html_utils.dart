// 移植自 NexHub（https://github.com/nexhub-app/NexHub，提交 37ddbdd，Apache-2.0）。
// 原始路径：lib/core/utils/html_utils.dart。
// 移植状态：改编——本树无 xpath_selector 引擎，XPath 分支一律抛
// UnsupportedError；CSS 选择器路径与原文一致，isXPath 保留供路由判定。
// clean/queryHtml/queryAttrExpr 与原文一致（均只走 CSS 路径）。
/// HTML / CSS selector 工具（XPath 不可用）。
///
/// 由网页爬取服务使用：CSS 选择器走 `package:html` 的 querySelector(All)；
/// XPath 选择器抛 [UnsupportedError]（本树未引入 xpath 引擎）。
library;

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

class HtmlUtils {
  HtmlUtils._();

  static Document parse(String html) => html_parser.parse(html);

  /// Returns matching elements (for per-field extraction by the parser).
  ///
  /// XPath selectors throw [UnsupportedError] in this tree; CSS selectors
  /// use `querySelectorAll`.
  static List<Element> elements(String html, String selector) {
    final doc = parse(html);
    if (isXPath(selector)) {
      throw UnsupportedError('XPath 选择器在本应用里不可用：$selector');
    }
    return doc.querySelectorAll(selector);
  }

  static String? query(String html, String selector) {
    final doc = parse(html);
    if (isXPath(selector)) {
      throw UnsupportedError('XPath 选择器在本应用里不可用：$selector');
    }
    return doc.querySelector(selector)?.text.trim();
  }

  static List<String> queryAll(String html, String selector) {
    final doc = parse(html);
    if (isXPath(selector)) {
      throw UnsupportedError('XPath 选择器在本应用里不可用：$selector');
    }
    return doc
        .querySelectorAll(selector)
        .map((e) => e.text.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  static String? queryAttr(String html, String selector, String attr) {
    final doc = parse(html);
    if (isXPath(selector)) {
      throw UnsupportedError('XPath 选择器在本应用里不可用：$selector');
    }
    return doc.querySelector(selector)?.attributes[attr];
  }

  /// Returns the **inner HTML** of the first element matched by [selector].
  /// Unlike [query] (which returns trimmed text), this preserves the markup.
  static String? queryHtml(String html, String selector) {
    final doc = parse(html);
    if (isXPath(selector)) {
      throw UnsupportedError('XPath 选择器在本应用里不可用：$selector');
    }
    return doc.querySelector(selector)?.innerHtml;
  }

  /// Strips noise nodes (`script`/`style`/`ins`/`iframe`/`noscript`/`head`/
  /// `link`/`meta`/`svg`) and comments from [html], returning the cleaned
  /// inner HTML.
  static String clean(String html) {
    final doc = parse(html);
    doc
        .querySelectorAll(
          'script, style, ins, iframe, noscript, head, link, meta, svg',
        )
        .forEach((e) => e.remove());
    _removeComments(doc);
    final body = doc.body;
    return body?.innerHtml ?? doc.documentElement?.innerHtml ?? '';
  }

  static void _removeComments(Node node) {
    final comments = node.nodes.whereType<Comment>().toList();
    for (final c in comments) {
      c.remove();
    }
    for (final child in node.nodes.whereType<Element>()) {
      _removeComments(child);
    }
  }

  /// Parses `a@href` / `img@data-src` style composite selectors:
  /// the CSS part matches an element, then `@attr` is read; without `@` the
  /// text is returned. XPath expressions throw [UnsupportedError].
  static String? queryAttrExpr(String html, String expr) {
    if (isXPath(expr)) {
      throw UnsupportedError('XPath 选择器在本应用里不可用：$expr');
    }
    final atIndex = expr.indexOf('@');
    if (atIndex < 0) return query(html, expr);
    final css = expr.substring(0, atIndex).trim();
    final attr = expr.substring(atIndex + 1).trim();
    return queryAttr(html, css, attr);
  }

  /// A selector is treated as XPath when it begins with an XPath path prefix
  /// (`//`, `/`, `./`, `.//`), a top-level XPath string function
  /// (`substring-before(` / `substring-after(`), or contains an XPath
  /// attribute predicate (`[@attr]` / `[@attr='val']`). CSS selectors never
  /// use `[@`, so CSS routing is unaffected.
  static bool isXPath(String selector) {
    final s = selector.trim();
    if (s.startsWith('//') ||
        s.startsWith('./') ||
        s.startsWith('.//') ||
        s.startsWith('/')) {
      return true;
    }
    if (s.startsWith('substring-before(') || s.startsWith('substring-after(')) {
      return true;
    }
    // XPath attribute predicate: tag[@attr] or tag[@attr='val'].
    // CSS uses [attr] without @, so [@ is a safe XPath signal.
    return s.contains('[@');
  }
}
