# Component Licensing

Limiar has component-specific licensing. The current owner direction is
private use and modification without sale or redistribution of newly
designated original material. This is not a blanket relicensing of
previously released code or of upstream dependencies.

## License Map

| Material | Applicable terms |
|---|---|
| Files explicitly listed in [the restricted-material manifest](licensing/limiar-private-files.json) | [Limiar Private-Use License 1.0](LICENSE-LIMIAR): own personal/internal use and private modification; no sale or redistribution, including modified builds, without separate written permission |
| Existing Limiar CLI and earlier MIT/Apache releases | [MIT](LICENSE-MIT) OR [Apache-2.0](LICENSE-APACHE), with existing grants preserved; the Cargo workspace describes this CLI, not every file in the repository |
| OpenVMM/OpenHCL and mu_msvm/EDK2 upstream portions | Their existing per-component licenses and notices; no Limiar ownership claim over upstream code |
| Looking Glass and work derived from it | Its upstream GPL terms, not the Limiar no-redistribution license |
| Historical QEMU device | Its GPL terms remain unchanged |
| Other new lab research and generated images | Private and not cleared for release; provenance and a per-file/artifact license decision are required before selection |

The manifest is a path allowlist, not a directory-wide wildcard. Only
copyrightable original material is covered. Existing grants, third-party
notices and separately licensed portions take precedence for their own
content. A license on the profile or generator is not a license covering
an entire generated IGVM, its Linux kernel, vendor drivers or OS images.
The neutral JSON profile uses a `.license` sidecar so that its validated
schema is unchanged.

## Previous Releases

The existing MIT and Apache license files are preserved. Rights already
granted to copies of earlier versions, including redistribution and sale
under those licenses, cannot be withdrawn by changing this repository's
current documentation. No Git history rewrite or historical-license
replacement is part of this decision.

The current Cargo package remains `MIT OR Apache-2.0`; the restricted
profile/generator material is outside that Rust package's implementation.
Adding such material to a future package requires an explicit packaging
and license review, not reuse of the old package declaration by default.

## Looking Glass

The inspected project fork at revision
`70b91772dbd5883d5e78854428c30d01ff38b7f8` contains the GPLv2 license text;
the inspected source headers specify version 2 or later. Preserve those
notices and check each component in the actual release candidate.
GPL permits compliant redistribution and charging for copies, and does
not permit a downstream no-sale or no-redistribution condition on the
covered derivative work. This applies to our changes within that work too.

Full publication of the Looking Glass integration remains the intended
scope, but it must use the compatible upstream terms. A restrictive
license for a genuinely independent component would require its own
ownership and dependency analysis; a different folder or binary name
does not establish that independence. No upstream fork was relicensed.

## Distribution Channels

Source-available is not the same as open source or confidential. A license
does not technically prevent copying. GitHub's terms also grant platform
viewing and forking rights when the copyright holder makes a repository
public. Do not promise an absolute no-fork rule for a public GitHub repo.
The owner authorized this limited public source-reference update on
September 27, 2026, with those platform rights preserved by section 4 of
the Limiar license. The separate license does not grant general sale or
redistribution rights beyond its exceptions and independently granted
rights. The lab firmware and broader study remain private. Future content
requiring strict no-copy confidentiality must not be placed in a public
repository. Repository visibility is unchanged by this update.

The [publication review](docs/PUBLICATION-REVIEW.md) still governs the
exact neutral-base selection, private lab hold and Looking Glass release.
Licensing permission and release approval are separate decisions.

This records project intent and the local license configuration, not a
legal opinion or independent legal review. Engineering and provenance
checks do not establish enforceability of the custom terms; obtain
qualified licensing advice before relying on enforcement.

## Primary References

- [GPLv2 terms, including sections 1, 2 and 6](https://www.gnu.org/licenses/old-licenses/gpl-2.0.en.html)
- [Looking Glass fork license at the inspected revision](https://github.com/templarsco/LookingGlass/blob/70b91772dbd5883d5e78854428c30d01ff38b7f8/LICENSE)
- [Looking Glass source notice at the inspected revision](https://github.com/templarsco/LookingGlass/blob/70b91772dbd5883d5e78854428c30d01ff38b7f8/host/src/app.c)
- [GitHub Terms of Service, user-generated content](https://docs.github.com/en/site-policy/github-terms/github-terms-of-service#d-user-generated-content)
