// Invisible-content cleanup before HTML→Markdown conversion: screen-reader
// labels ("Copy link to heading"), hidden elements, empty heading anchors,
// and byline avatars must never reach the reader.
import 'package:einkreader/services/extractor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  String md(String html) => ArticleExtractor.convertHtmlToMarkdown(html);

  test('screen-reader-only labels are stripped (Vercel headings)', () {
    final out = md(
        '<h2><a href="#incident"><span class="sr-only">Copy link to '
        'heading</span></a>The security incident</h2>'
        '<p>Body text follows.</p>');
    expect(out, contains('## The security incident'));
    expect(out, isNot(contains('Copy link')));
    expect(out, isNot(contains('[](#')),
        reason: 'the emptied heading anchor is dropped entirely');
  });

  test('hidden attribute and hidden inline styles are stripped', () {
    final out = md('<p hidden>secret one</p>'
        '<p style="display:none">secret two</p>'
        '<p style="visibility: hidden">secret three</p>'
        '<p>visible</p>');
    expect(out, 'visible');
  });

  test('avatars and icon-sized images are dropped, real images kept', () {
    final out = md(
        '<img src="https://cdn.example/w_36,h_36,c_fill/photo.png" '
        'alt="Author avatar">'
        '<img src="https://x.example/pic.png" width="32" height="32">'
        '<img class="author-avatar" src="https://x.example/face.jpg">'
        '<p>Story text here.</p>'
        '<img src="https://x.example/figure.png" alt="Figure 1" '
        'width="1200">');
    expect(out, isNot(contains('avatar')));
    expect(out, isNot(contains('w_36')));
    expect(out, isNot(contains('pic.png')));
    expect(out, contains('figure.png'), reason: 'content images survive');
    expect(out, contains('Story text here.'));
  });

  test('style/script blocks in feed fragments never leak as text', () {
    final out = md('<style>.table-ABC td { text-align: left }</style>'
        '<script>alert(1)</script>'
        '<p>Real content.</p>'
        '<table><tr><th>Revenue</th><th>Disney</th></tr>'
        '<tr><td>Net</td><td>11.5%</td></tr></table>');
    expect(out, isNot(contains('text-align')));
    expect(out, isNot(contains('alert')));
    expect(out, contains('Real content.'));
    expect(out, contains('Revenue'));
  });

  test("Daring Fireball's style-inside-table strips cleanly", () {
    // The feed nests <style> INSIDE <table> inside <p> — element removal
    // must work wherever the parser fosters it.
    final out = md('<p>For the most recent 12 months:</p>'
        '<p><table class="table-F0A58456" width=300>'
        '<style>.table-F0A58456 th:nth-child(1) { text-align: left }</style>'
        '<tr><th></th><th>Disney</th><th>Netflix</th></tr>'
        '<tr><td>Revenue</td><td>\$97 B</td><td>\$48 B</td></tr>'
        '</table></p>');
    expect(out, isNot(contains('text-align')));
    expect(out, contains('Disney'));
    expect(out, contains('Revenue'));
  });

  test('table-layout pages with no <p> extract the essay, not raw HTML', () {
    // paulgraham.com-style markup: nested layout tables, the whole essay a
    // <br><br>-separated run inside a <font>. The old candidate scorer
    // found no <p> text, fell back to the body, and html2md garbled the
    // nested tables into literal "<table …>" text.
    final essay = List.generate(
        12,
        (i) => 'Paragraph $i of the essay, long enough to count as real '
            'article text for the extractor scoring pass.').join('<br><br>');
    final html = '<html><body>'
        '<table border="0"><tr valign="top">'
        '<td><a href="index.html"><img src="nav.gif"></a></td>'
        '<td><table width="435"><tr><td>'
        '<font size="2" face="verdana">$essay</font>'
        '</td></tr></table></td>'
        '</tr></table></body></html>';
    final out = ArticleExtractor.extract(html,
        baseUrl: 'https://paulgraham.example/own.html')!;
    expect(out, contains('Paragraph 0 of the essay'));
    expect(out, contains('Paragraph 11 of the essay'));
    expect(out, isNot(contains('<table')));
    expect(out, isNot(contains('<font')));
    expect(out, isNot(contains('|')), reason: 'no layout-table pipe rows');
  });

  test('the post container wins over a page wrapper with sidebar text', () {
    // seths.blog: the sidebar's one paragraph lives inside the same
    // content wrapper as the post, and ancestors are visited first — the
    // wrapper used to win, dragging in menus, "Subscribe" and share icons.
    final paragraphs = List.generate(
        5,
        (i) => '<p>Paragraph $i of the post, with enough words in it to '
            'count as real article text for the scorer.</p>').join();
    final html = '<html><body><div id="content-container">'
        '<div class="sidebar-widget"><h2>More Seth</h2><ul>'
        '<li><a href="/more">Books, videos, and speaking</a></li></ul></div>'
        '<div id="nudge"><p>Have you thought about subscribing? It is free.'
        '</p></div>'
        '<div class="wrapper"><div class="post single">'
        '<h2><a href="/post">Measuring nothing</a></h2>$paragraphs'
        '<p class="byline">January 25, 2014</p>'
        '<ul class="icons"><li><a href="https://facebook.example/share">'
        '<svg><path d="M0"/></svg></a></li>'
        '<li><a href="https://twitter.example/intent"><svg/></a></li></ul>'
        '</div></div></div></body></html>';
    final out = ArticleExtractor.extract(html,
        baseUrl: 'https://seths.example/2014/01/post/')!;
    expect(out, startsWith('## [Measuring nothing]'));
    expect(out, contains('Paragraph 4 of the post'));
    expect(out, isNot(contains('More Seth')));
    expect(out, isNot(contains('subscribing')));
    expect(out, isNot(contains('facebook')),
        reason: 'icon-only share links vanish with their empty bullets');
    expect(out.trim(), endsWith('January 25, 2014'));
  });

  test('icon-only links and the lists they empty are dropped', () {
    final out = md('<p>Text.</p><ul><li><a href="https://a.example">'
        '<svg/></a></li><li><a href="https://b.example"> </a></li></ul>'
        '<p>More <a href="https://c.example">real link</a>.</p>'
        '<a href="https://d.example"><img src="https://d.example/big.png" '
        'width="800"></a>');
    expect(out, isNot(contains('a.example')));
    expect(out, isNot(contains('b.example')));
    expect(out, isNot(contains('*')), reason: 'no empty bullets left');
    expect(out, contains('[real link](https://c.example)'));
    expect(out, contains('big.png'), reason: 'image links are content');
  });

  test('fragment links with real text survive', () {
    final out = md('<p>See the <a href="#notes">notes below</a>.</p>');
    expect(out, contains('[notes below](#notes)'));
  });
}
