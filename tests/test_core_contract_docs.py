"""Regression checks for the core-contract documentation added in PR #6."""

from pathlib import Path
import re
import unittest
from urllib.parse import unquote, urlsplit


ROOT = Path(__file__).resolve().parents[1]
DOCUMENTS = (
    Path("README.md"),
    Path("docs/ARCHITECTURE.md"),
    Path("docs/CORE-CONTRACT.md"),
    Path("docs/DEVELOPMENT-PLAN.md"),
    Path("docs/IDENTITY.md"),
)
CONTRACT = ROOT / "docs/CORE-CONTRACT.md"
INLINE_LINK = re.compile(r"(?<!!)\[[^\]]+\]\(([^)]+)\)")


def local_targets(document):
    for href in INLINE_LINK.findall(document.read_text(encoding="utf-8")):
        parsed = urlsplit(href)
        if parsed.scheme or parsed.netloc:
            continue
        yield href, (document.parent / unquote(parsed.path)).resolve()


class CoreContractDocumentationTests(unittest.TestCase):
    def test_changed_documents_have_no_broken_or_escaping_local_links(self):
        for relative_path in DOCUMENTS:
            document = ROOT / relative_path
            with self.subTest(document=str(relative_path)):
                links = list(local_targets(document))
                self.assertTrue(links, "expected at least one local link")
                for href, target in links:
                    with self.subTest(link=href):
                        self.assertTrue(target.is_relative_to(ROOT), "link leaves repository")
                        self.assertTrue(target.is_file(), "link target is missing")

    def test_existing_guides_link_to_the_core_contract(self):
        for relative_path in DOCUMENTS:
            if relative_path == Path("docs/CORE-CONTRACT.md"):
                continue
            document = ROOT / relative_path
            with self.subTest(document=str(relative_path)):
                self.assertIn(CONTRACT, {target for _, target in local_targets(document)})

    def test_core_contract_links_back_to_implementation_and_roadmap(self):
        targets = {target for _, target in local_targets(CONTRACT)}
        self.assertIn(ROOT / "docs/IDENTITY.md", targets)
        self.assertIn(ROOT / "docs/DEVELOPMENT-PLAN.md", targets)


if __name__ == "__main__":
    unittest.main()
