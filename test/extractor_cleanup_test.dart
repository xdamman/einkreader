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

  test('fragment links with real text survive', () {
    final out = md('<p>See the <a href="#notes">notes below</a>.</p>');
    expect(out, contains('[notes below](#notes)'));
  });
}
