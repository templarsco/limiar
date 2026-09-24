"""Regression checks for the core-contract documentation added in PR #6."""

from pathlib import Path
import re
import tempfile
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
    """Yield each local link href and its resolved filesystem target found in the document."""
    for href in INLINE_LINK.findall(document.read_text(encoding="utf-8")):
        parsed = urlsplit(href)
        if parsed.scheme or parsed.netloc:
            continue
        target = document.parent / unquote(parsed.path) if parsed.path else document
        yield href, target.resolve()


class LocalTargetTests(unittest.TestCase):
    """Keep local link resolution consistent with Markdown URL semantics."""

    def test_fragment_only_link_targets_the_current_document(self):
        """An in-page link must resolve to its file, not the parent directory."""
        with tempfile.TemporaryDirectory() as temporary:
            document = Path(temporary) / "guide.md"
            document.write_text("[Section](#section)", encoding="utf-8")
            self.assertEqual(
                list(local_targets(document)), [("#section", document.resolve())]
            )

    def test_encoded_path_keeps_its_file_target_without_query_or_fragment(self):
        """Decode relative paths while leaving URL query and fragment out of the path."""
        with tempfile.TemporaryDirectory() as temporary:
            document = Path(temporary) / "guide.md"
            href = "other%20guide.md?view=raw#section"
            document.write_text(f"[Other]({href})", encoding="utf-8")
            self.assertEqual(
                list(local_targets(document)),
                [(href, (document.parent / "other guide.md").resolve())],
            )


class CoreContractDocumentationTests(unittest.TestCase):
    """Verify the core-contract documentation set stays internally consistent."""

    def test_changed_documents_have_no_broken_or_escaping_local_links(self):
        """Ensure every local link in the changed documents resolves to an existing in-repo file."""
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
        """Ensure every other document links back to the core contract."""
        for relative_path in DOCUMENTS:
            if relative_path == Path("docs/CORE-CONTRACT.md"):
                continue
            document = ROOT / relative_path
            with self.subTest(document=str(relative_path)):
                self.assertIn(CONTRACT, {target for _, target in local_targets(document)})

    def test_core_contract_links_back_to_implementation_and_roadmap(self):
        """Ensure the core contract links to both the identity implementation and the roadmap."""
        targets = {target for _, target in local_targets(CONTRACT)}
        self.assertIn(ROOT / "docs/IDENTITY.md", targets)
        self.assertIn(ROOT / "docs/DEVELOPMENT-PLAN.md", targets)


if __name__ == "__main__":
    unittest.main()
