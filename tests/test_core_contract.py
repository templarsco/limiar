import re
from pathlib import Path
import unittest
from urllib.parse import unquote, urlsplit


ROOT = Path(__file__).resolve().parents[1]
CONTRACT = ROOT / "docs/CORE-CONTRACT.md"
CHANGED_DOCUMENTS = (
    ROOT / "README.md",
    ROOT / "docs/ARCHITECTURE.md",
    CONTRACT,
    ROOT / "docs/DEVELOPMENT-PLAN.md",
    ROOT / "docs/IDENTITY.md",
)


def section(document, heading):
    match = re.search(
        rf"^## {re.escape(heading)}\n(.*?)(?=^## |\Z)",
        document,
        re.MULTILINE | re.DOTALL,
    )
    if match is None:
        raise AssertionError(f"missing section: {heading}")
    return match.group(1)


class CoreContractTests(unittest.TestCase):
    def test_local_links_in_changed_documents_resolve(self):
        for document in CHANGED_DOCUMENTS:
            for destination in re.findall(r"\[[^]]+\]\(([^)]+)\)", document.read_text()):
                parsed = urlsplit(destination)
                if parsed.scheme or parsed.netloc or not parsed.path:
                    continue
                with self.subTest(document=document.relative_to(ROOT), link=destination):
                    target = document.parent / unquote(parsed.path)
                    self.assertTrue(target.is_file(), f"missing link target: {target}")

    def test_core_contract_is_reachable_and_links_to_supporting_docs(self):
        for document in CHANGED_DOCUMENTS:
            if document == CONTRACT:
                continue
            with self.subTest(document=document.relative_to(ROOT)):
                relative_link = (
                    CONTRACT.relative_to(document.parent)
                    if document.parent == ROOT
                    else Path("CORE-CONTRACT.md")
                )
                self.assertIn(f"]({relative_link.as_posix()})", document.read_text())

        contract = CONTRACT.read_text()
        self.assertIn("](IDENTITY.md)", contract)
        self.assertIn("](DEVELOPMENT-PLAN.md)", contract)

    def test_required_outcomes_have_unique_acceptance_targets(self):
        outcomes = section(CONTRACT.read_text(), "Required Outcome")
        rows = re.findall(r"^\|\s*([^|]+?)\s*\|\s*([^|]+?)\s*\|$", outcomes, re.MULTILINE)
        targets = {name.strip(): target.strip() for name, target in rows[2:]}

        self.assertEqual(len(targets), len(rows) - 2, "duplicate requirement names")
        self.assertEqual(
            set(targets),
            {
                "Machine ownership",
                "SMBIOS coverage",
                "Coherent virtual hardware",
                "Combined graphics",
                "Shared GPU preference",
                "Application experience",
                "Quality and performance",
            },
        )
        for name, target in targets.items():
            with self.subTest(requirement=name):
                self.assertTrue(target, "acceptance target must not be empty")

    def test_smbios_target_matches_identity_document(self):
        contract_gate = section(CONTRACT.read_text(), "Next Core Gate")
        identity_target = section((ROOT / "docs/IDENTITY.md").read_text(), "QEMU Coverage Target")
        expected = {0, 1, 2, 3, 4, 9, 11, 17, 41}

        for name, content in (("core gate", contract_gate), ("identity", identity_target)):
            with self.subTest(document=name):
                match = re.search(r"SMBIOS Types? ([\d,\s]+and\s+\d+)", content)
                self.assertIsNotNone(match)
                actual = {int(number) for number in re.findall(r"\d+", match.group(1))}
                self.assertEqual(actual, expected)
                self.assertIn("binary entries", content)

    def test_unimplemented_runtime_gate_remains_open(self):
        contract = CONTRACT.read_text()
        plan_gate = section((ROOT / "docs/DEVELOPMENT-PLAN.md").read_text(), "Core Gate: Configurable Accelerated PC")
        checklist = re.findall(r"^- \[([ x])\] ", plan_gate, re.MULTILINE)

        self.assertIn("the combined runtime described here is not implemented", contract)
        self.assertIn("runtime gate pending", plan_gate)
        self.assertEqual(checklist, ["x"] + [" "] * 7)


if __name__ == "__main__":
    unittest.main()
