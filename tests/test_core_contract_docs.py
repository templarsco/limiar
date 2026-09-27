"""Regression checks for project direction, documentation and license scope."""

import json
from pathlib import Path
import re
import tempfile
import tomllib
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
LICENSING_DOCUMENTS = (
    Path("LICENSING.md"),
    Path("CONTRIBUTING.md"),
    Path("docs/PUBLICATION-REVIEW.md"),
    Path("docs/LIMIAR-FIRMWARE-BASE.md"),
    Path("docs/OPENHCL-COMPATIBILITY.md"),
)
RESTRICTED_FILES = {
    "docs/LIMIAR-FIRMWARE-BASE.md",
    "docs/PUBLICATION-REVIEW.md",
    "profiles/openhcl/limiar-reference.json",
    "scripts/openhcl/Firmware.psm1",
    "tests/openhcl_limiar_profile.ps1",
}


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

    def test_main_guides_point_to_the_active_native_workstream(self):
        workstream = ROOT / "docs/OPENHCL-COMPATIBILITY.md"
        for relative_path in DOCUMENTS:
            with self.subTest(document=str(relative_path)):
                document = ROOT / relative_path
                self.assertIn(workstream, {target for _, target in local_targets(document)})
                introduction = document.read_text(encoding="utf-8")[:2000]
                self.assertIn("OpenHCL", introduction)
                self.assertIn("QEMU", introduction)

    def test_readme_separates_current_status_from_reference_workflows(self):
        text = (ROOT / "README.md").read_text(encoding="utf-8")
        self.assertLess(
            text.index("## Current Native Status"),
            text.index("## Historical Reference Workflows"),
        )
        self.assertGreater(text.count("<details>"), 0)
        self.assertEqual(text.count("<details>"), text.count("</details>"))

    def test_nitro_inspiration_has_an_official_reference(self):
        for relative in (Path("README.md"), Path("docs/ARCHITECTURE.md")):
            with self.subTest(document=str(relative)):
                text = (ROOT / relative).read_text(encoding="utf-8")
                self.assertIn("AWS Nitro", text)
                self.assertIn("https://aws.amazon.com/ec2/nitro/", INLINE_LINK.findall(text))


class ComponentLicensingTests(unittest.TestCase):
    """Check license declarations, not legal validity or release clearance."""

    @classmethod
    def setUpClass(cls):
        cls.manifest = json.loads(
            (ROOT / "licensing/limiar-private-files.json").read_text(encoding="utf-8")
        )

    def test_restricted_scope_is_an_explicit_file_allowlist(self):
        self.assertEqual(self.manifest["schema_version"], 1)
        files = self.manifest["files"]
        self.assertEqual(len(files), len(set(files)), "duplicate restricted paths")
        self.assertEqual(set(files), RESTRICTED_FILES)
        for relative in files:
            with self.subTest(path=relative):
                self.assertNotRegex(relative, r"[\\*?\[\]]")
                path = Path(relative)
                self.assertFalse(path.is_absolute())
                self.assertNotIn("..", path.parts)
                target = (ROOT / path).resolve()
                self.assertTrue(target.is_relative_to(ROOT))
                self.assertTrue(target.is_file())

    def test_covered_files_have_matching_license_notices(self):
        identifier = "LicenseRef-Limiar-Private-Use-1.0"
        self.assertEqual(self.manifest["license_id"], identifier)
        for relative in self.manifest["files"]:
            with self.subTest(path=relative):
                path = ROOT / relative
                notice = Path(str(path) + ".license") if path.suffix == ".json" else path
                text = notice.read_text(encoding="utf-8")
                self.assertIn("SPDX-FileCopyrightText: 2026 SANSI GROUP", text)
                self.assertEqual(text.count("SPDX-License-Identifier: " + identifier), 1)

    def test_license_document_and_historical_cli_terms_are_separate(self):
        self.assertEqual(self.manifest["license_file"], "LICENSE-LIMIAR")
        license_text = (ROOT / self.manifest["license_file"]).read_text(encoding="utf-8")
        self.assertIn(self.manifest["license_id"], license_text)
        self.assertIn("No Sale / No Redistribution", license_text)
        self.assertIn("private copies", license_text)
        self.assertIn("Existing And Third-Party Rights", license_text)
        workspace = tomllib.loads((ROOT / "Cargo.toml").read_text(encoding="utf-8"))
        package = tomllib.loads(
            (ROOT / "crates/limiar/Cargo.toml").read_text(encoding="utf-8")
        )
        self.assertEqual(workspace["workspace"]["package"]["license"], "MIT OR Apache-2.0")
        self.assertTrue(package["package"]["license"]["workspace"])
        self.assertFalse(package["package"]["publish"])
        self.assertTrue((ROOT / "LICENSE-MIT").is_file())
        self.assertTrue((ROOT / "LICENSE-APACHE").is_file())

    def test_licensing_documents_resolve_local_references(self):
        for relative in LICENSING_DOCUMENTS:
            with self.subTest(document=str(relative)):
                for href, target in local_targets(ROOT / relative):
                    with self.subTest(link=href):
                        self.assertTrue(target.is_relative_to(ROOT))
                        self.assertTrue(target.is_file())

    def test_current_publication_guides_link_the_license_map(self):
        for relative in DOCUMENTS[:4] + LICENSING_DOCUMENTS[1:]:
            with self.subTest(document=str(relative)):
                targets = {target for _, target in local_targets(ROOT / relative)}
                self.assertIn(ROOT / "LICENSING.md", targets)


if __name__ == "__main__":
    unittest.main()
