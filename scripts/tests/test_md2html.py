import unittest

from scripts.md2html import inline


class Md2HtmlTests(unittest.TestCase):
    def test_inline_links_are_converted(self):
        out = inline('见[指南](工程.md)与[外链](https://example.test/a)')
        self.assertIn('<a href="工程.md">指南</a>', out)
        self.assertIn('<a href="https://example.test/a">外链</a>', out)
        self.assertNotIn('](', out)

    def test_bare_url_stops_at_cjk_punctuation(self):
        self.assertEqual(inline('见 https://example.test/a。'), '见 <a href="https://example.test/a">https://example.test/a</a>。')

    def test_link_target_is_not_wrapped_twice(self):
        out = inline('[外链](https://example.test/a)')
        self.assertEqual(out.count('<a '), 1)


if __name__ == '__main__':
    unittest.main()
