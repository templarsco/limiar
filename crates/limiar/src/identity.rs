use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use uuid::Uuid;

#[derive(Debug, Clone, Copy, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Preset {
    #[default]
    Limiar,
    Custom,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Identity {
    #[serde(default)]
    pub preset: Preset,
    #[serde(default)]
    pub system: System,
    pub bios: Option<Bios>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub baseboard: Option<Baseboard>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub chassis: Option<Chassis>,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct System {
    pub manufacturer: Option<String>,
    pub product: Option<String>,
    pub version: Option<String>,
    pub serial: Option<String>,
    pub uuid: Option<Uuid>,
    pub sku: Option<String>,
    pub family: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Bios {
    pub vendor: Option<String>,
    pub version: Option<String>,
    pub date: Option<String>,
    pub release: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Baseboard {
    pub manufacturer: Option<String>,
    pub product: Option<String>,
    pub version: Option<String>,
    pub serial: Option<String>,
    pub asset: Option<String>,
    pub location: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Chassis {
    pub manufacturer: Option<String>,
    pub version: Option<String>,
    pub serial: Option<String>,
    pub asset: Option<String>,
    pub sku: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct IdentityPlan {
    pub preset: Preset,
    pub requires_registration: bool,
    pub expected_dmi: BTreeMap<String, String>,
    pub limitations: Vec<&'static str>,
}

#[derive(Debug, Serialize)]
pub struct Comparison {
    pub field: String,
    pub expected: String,
    pub observed: Option<String>,
    pub matches: bool,
}

#[derive(Debug, Serialize)]
pub struct Verification {
    pub scope: &'static str,
    pub passed: bool,
    pub fields: Vec<Comparison>,
    pub observed_dmi: BTreeMap<String, String>,
    pub limitation: &'static str,
}

fn text(field: &str, value: &str) -> Result<()> {
    ensure!(
        !value.trim().is_empty()
            && value.trim() == value
            && value.len() <= 64
            && value.bytes().all(|byte| (0x20..=0x7e).contains(&byte))
            && !value.contains([',', '=']),
        "{field} must contain 1..64 printable ASCII bytes, without surrounding whitespace, ',' or '='"
    );
    Ok(())
}

fn validate_date(date: &str) -> Result<()> {
    let bytes = date.as_bytes();
    ensure!(
        bytes.len() == 10
            && bytes[2] == b'/'
            && bytes[5] == b'/'
            && bytes
                .iter()
                .enumerate()
                .all(|(index, byte)| index == 2 || index == 5 || byte.is_ascii_digit()),
        "identity.bios.date must use MM/DD/YYYY"
    );
    let month: usize = date[0..2].parse()?;
    let day: u32 = date[3..5].parse()?;
    let year: u32 = date[6..10].parse()?;
    let leap = year.is_multiple_of(4) && (!year.is_multiple_of(100) || year.is_multiple_of(400));
    let days = [
        31,
        if leap { 29 } else { 28 },
        31,
        30,
        31,
        30,
        31,
        31,
        30,
        31,
        30,
        31,
    ];
    ensure!(
        (1900..=9999).contains(&year)
            && (1..=12).contains(&month)
            && day > 0
            && day <= days[month - 1],
        "identity.bios.date is not a valid calendar date"
    );
    Ok(())
}

impl Identity {
    pub fn validate(&self, linux_direct: bool) -> Result<()> {
        ensure!(
            self.baseboard.is_none() && self.chassis.is_none(),
            "baseboard and chassis identity require the experimental qemu_uefi backend"
        );
        for (key, value) in [
            ("manufacturer", &self.system.manufacturer),
            ("product", &self.system.product),
            ("version", &self.system.version),
            ("serial", &self.system.serial),
            ("sku", &self.system.sku),
            ("family", &self.system.family),
        ] {
            if let Some(value) = value {
                text(&format!("identity.system.{key}"), value)?;
            }
        }
        if let Some(uuid) = self.system.uuid {
            ensure!(
                !uuid.is_nil() && uuid.as_u128() != u128::MAX,
                "identity.system.uuid cannot be zero or all-ones"
            );
        }
        if let Some(bios) = &self.bios {
            ensure!(
                linux_direct,
                "OpenVMM UEFI supports Type 1 system identity only; identity.bios requires linux_direct"
            );
            for (key, value) in [
                ("vendor", &bios.vendor),
                ("version", &bios.version),
                ("date", &bios.date),
                ("release", &bios.release),
            ] {
                if let Some(value) = value {
                    text(&format!("identity.bios.{key}"), value)?;
                }
            }
            if let Some(date) = &bios.date {
                validate_date(date)?;
            }
            if let Some(release) = &bios.release {
                let (major, minor) = release
                    .split_once('.')
                    .context("identity.bios.release must use MAJOR.MINOR")?;
                for part in [major, minor] {
                    ensure!(
                        !part.is_empty() && part.bytes().all(|byte| byte.is_ascii_digit()),
                        "identity.bios.release must use MAJOR.MINOR"
                    );
                    part.parse::<u8>()
                        .context("BIOS release components must be 0..255")?;
                }
            }
        }
        if self.preset == Preset::Custom {
            ensure!(
                self.system.manufacturer.is_some() && self.system.product.is_some(),
                "custom identity requires system.manufacturer and system.product"
            );
        }
        Ok(())
    }

    /// Resolve defaults once into the registered snapshot, never at each boot.
    pub fn materialize(&mut self, previous: Option<&Self>, linux_direct: bool) -> Result<()> {
        self.validate(linux_direct)?;
        self.apply_defaults(linux_direct);
        if self.system.uuid.is_none() {
            self.system.uuid = Some(
                previous
                    .and_then(|identity| identity.system.uuid)
                    .unwrap_or_else(Uuid::new_v4),
            );
        }
        if self.system.serial.is_none() {
            self.system.serial = Some(
                previous
                    .and_then(|identity| identity.system.serial.clone())
                    .unwrap_or_else(|| {
                        format!(
                            "LMR-{}",
                            &self.system.uuid.unwrap().simple().to_string()[..16]
                                .to_ascii_uppercase()
                        )
                    }),
            );
        }
        self.validate(linux_direct)
    }

    fn apply_defaults(&mut self, linux_direct: bool) {
        if self.preset != Preset::Limiar {
            return;
        }
        for (slot, value) in [
            (&mut self.system.manufacturer, "Limiar"),
            (&mut self.system.product, "Limiar One"),
            (&mut self.system.version, "1.0"),
            (&mut self.system.sku, "LMR-ONE"),
            (&mut self.system.family, "Limiar Desktop"),
        ] {
            slot.get_or_insert_with(|| value.to_owned());
        }
        if linux_direct {
            let bios = self.bios.get_or_insert_with(Bios::default);
            for (slot, value) in [
                (&mut bios.vendor, "Limiar"),
                (&mut bios.version, "0.3"),
                (&mut bios.date, "09/24/2026"),
                (&mut bios.release, "0.3"),
            ] {
                slot.get_or_insert_with(|| value.to_owned());
            }
        }
    }

    pub fn plan(&self, linux_direct: bool) -> Result<(IdentityPlan, Vec<String>)> {
        self.validate(linux_direct)?;
        let mut effective = self.clone();
        effective.apply_defaults(linux_direct);
        let mut expected = BTreeMap::new();
        let mut arguments = Vec::new();
        let mut system = vec!["type=1".to_owned()];
        for (key, dmi, value) in [
            ("manufacturer", "sys_vendor", &effective.system.manufacturer),
            ("product", "product_name", &effective.system.product),
            ("version", "product_version", &effective.system.version),
            ("serial", "product_serial", &effective.system.serial),
            ("sku", "product_sku", &effective.system.sku),
            ("family", "product_family", &effective.system.family),
        ] {
            if let Some(value) = value {
                system.push(format!("{key}={value}"));
                expected.insert(dmi.to_owned(), value.clone());
            }
        }
        if let Some(uuid) = effective.system.uuid {
            system.push(format!("uuid={uuid}"));
            expected.insert("product_uuid".to_owned(), uuid.to_string());
        }
        arguments.extend(["--smbios".to_owned(), system.join(",")]);
        if let Some(bios) = &effective.bios {
            let mut values = vec!["type=0".to_owned()];
            for (key, dmi, value) in [
                ("vendor", "bios_vendor", &bios.vendor),
                ("version", "bios_version", &bios.version),
                ("date", "bios_date", &bios.date),
                ("release", "bios_release", &bios.release),
            ] {
                if let Some(value) = value {
                    values.push(format!("{key}={value}"));
                    let observed_format = if key == "release" {
                        let (major, minor) = value.split_once('.').unwrap();
                        format!("{}.{}", major.parse::<u8>()?, minor.parse::<u8>()?)
                    } else {
                        value.clone()
                    };
                    expected.insert(dmi.to_owned(), observed_format);
                }
            }
            if values.len() > 1 {
                arguments.extend(["--smbios".to_owned(), values.join(",")]);
            }
        }
        Ok((
            IdentityPlan {
                preset: effective.preset,
                requires_registration: effective.system.uuid.is_none()
                    || effective.system.serial.is_none(),
                expected_dmi: expected,
                limitations: vec![
                    "Type 2 baseboard and Type 3 chassis overrides are not implemented by the pinned OpenVMM CLI.",
                    "UEFI self-describes Type 0 BIOS; only linux_direct accepts BIOS overrides.",
                    "SMBIOS customization does not replace CPUID, ACPI, PCI, drivers, or the underlying hypervisor.",
                ],
            },
            arguments,
        ))
    }

    fn type01(&self) -> Self {
        let mut identity = self.clone();
        identity.baseboard = None;
        identity.chassis = None;
        identity
    }

    pub fn validate_qemu(&self) -> Result<()> {
        self.type01().validate(true)?;
        if let Some(board) = &self.baseboard {
            for (field, value) in [
                ("manufacturer", &board.manufacturer),
                ("product", &board.product),
                ("version", &board.version),
                ("serial", &board.serial),
                ("asset", &board.asset),
                ("location", &board.location),
            ] {
                if let Some(value) = value {
                    text(&format!("identity.baseboard.{field}"), value)?;
                }
            }
        }
        if let Some(chassis) = &self.chassis {
            for (field, value) in [
                ("manufacturer", &chassis.manufacturer),
                ("version", &chassis.version),
                ("serial", &chassis.serial),
                ("asset", &chassis.asset),
                ("sku", &chassis.sku),
            ] {
                if let Some(value) = value {
                    text(&format!("identity.chassis.{field}"), value)?;
                }
            }
        }
        Ok(())
    }

    fn apply_qemu_defaults(&mut self) {
        self.apply_defaults(true);
        if self.preset != Preset::Limiar {
            return;
        }
        let board = self.baseboard.get_or_insert_with(Baseboard::default);
        for (slot, value) in [
            (&mut board.manufacturer, "Limiar"),
            (&mut board.product, "Limiar Mainboard"),
            (&mut board.version, "1.0"),
            (&mut board.asset, "LMR-BOARD"),
            (&mut board.location, "Mainboard"),
        ] {
            slot.get_or_insert_with(|| value.to_owned());
        }
        let chassis = self.chassis.get_or_insert_with(Chassis::default);
        for (slot, value) in [
            (&mut chassis.manufacturer, "Limiar"),
            (&mut chassis.version, "Limiar Desktop"),
            (&mut chassis.asset, "LMR-CHASSIS"),
            (&mut chassis.sku, "LMR-DESKTOP"),
        ] {
            slot.get_or_insert_with(|| value.to_owned());
        }
        if let Some(uuid) = self.system.uuid {
            let suffix = uuid.simple().to_string()[..16].to_ascii_uppercase();
            board
                .serial
                .get_or_insert_with(|| format!("LMR-B-{suffix}"));
            chassis
                .serial
                .get_or_insert_with(|| format!("LMR-C-{suffix}"));
        }
    }

    pub fn materialize_qemu(&mut self, previous: Option<&Self>) -> Result<()> {
        self.validate_qemu()?;
        let mut base = self.type01();
        let previous_base = previous.map(Self::type01);
        base.materialize(previous_base.as_ref(), true)?;
        self.system = base.system;
        self.bios = base.bios;
        if self.preset == Preset::Limiar || self.baseboard.is_some() {
            let board = self.baseboard.get_or_insert_with(Baseboard::default);
            if board.serial.is_none() {
                board.serial = previous
                    .and_then(|identity| identity.baseboard.as_ref())
                    .and_then(|board| board.serial.clone());
            }
        }
        if self.preset == Preset::Limiar || self.chassis.is_some() {
            let chassis = self.chassis.get_or_insert_with(Chassis::default);
            if chassis.serial.is_none() {
                chassis.serial = previous
                    .and_then(|identity| identity.chassis.as_ref())
                    .and_then(|chassis| chassis.serial.clone());
            }
        }
        self.apply_qemu_defaults();
        self.validate_qemu()
    }

    pub fn plan_qemu(&self) -> Result<(IdentityPlan, Vec<String>)> {
        self.validate_qemu()?;
        let mut effective = self.clone();
        effective.apply_qemu_defaults();
        let (mut plan, mut arguments) = effective.type01().plan(true)?;
        // The Type 0/1 keys are shared; QEMU uses a single-dash option.
        for argument in &mut arguments {
            if argument == "--smbios" {
                *argument = "-smbios".to_owned();
            }
        }
        let mut bios_present = false;
        for pair in arguments.chunks_exact_mut(2) {
            if pair[1].starts_with("type=0,") {
                pair[1].push_str(",uefi=on");
                bios_present = true;
            }
        }
        if !bios_present {
            arguments.extend(["-smbios".to_owned(), "type=0,uefi=on".to_owned()]);
        }
        if let Some(board) = &effective.baseboard {
            append_qemu_table(
                &mut plan.expected_dmi,
                &mut arguments,
                2,
                &[
                    ("manufacturer", "board_vendor", &board.manufacturer),
                    ("product", "board_name", &board.product),
                    ("version", "board_version", &board.version),
                    ("serial", "board_serial", &board.serial),
                    ("asset", "board_asset_tag", &board.asset),
                    ("location", "board_location", &board.location),
                ],
            );
        }
        if let Some(chassis) = &effective.chassis {
            append_qemu_table(
                &mut plan.expected_dmi,
                &mut arguments,
                3,
                &[
                    ("manufacturer", "chassis_vendor", &chassis.manufacturer),
                    ("version", "chassis_version", &chassis.version),
                    ("serial", "chassis_serial", &chassis.serial),
                    ("asset", "chassis_asset_tag", &chassis.asset),
                    ("sku", "chassis_sku", &chassis.sku),
                ],
            );
        }
        plan.limitations = vec![
            "Experimental QEMU/WHPX UEFI path; graphics use an emulated display, not GPU-PV.",
            "Only the listed SMBIOS Type 0/1/2/3 fields are implemented.",
            "SMBIOS customization does not replace CPUID, ACPI, PCI, drivers, or the underlying hypervisor.",
        ];
        Ok((plan, arguments))
    }
}

fn append_qemu_table(
    expected: &mut BTreeMap<String, String>,
    arguments: &mut Vec<String>,
    kind: u8,
    fields: &[(&str, &str, &Option<String>)],
) {
    let mut values = vec![format!("type={kind}")];
    for (option, field, value) in fields {
        if let Some(value) = value {
            values.push(format!("{option}={value}"));
            expected.insert((*field).to_owned(), value.clone());
        }
    }
    if values.len() > 1 {
        arguments.extend(["-smbios".to_owned(), values.join(",")]);
    }
}

pub fn verify(expected: &BTreeMap<String, String>, transcript: &str) -> Result<Verification> {
    ensure!(!expected.is_empty(), "identity has no fields to verify");
    ensure!(
        transcript.len() <= 8 * 1024 * 1024,
        "guest transcript exceeds 8 MiB"
    );
    let mut observed = BTreeMap::new();
    let (mut started, mut finished) = (false, false);
    for line in transcript.lines().map(|line| line.trim_end_matches('\r')) {
        if line == "LIMIAR_DMI_BEGIN" {
            ensure!(!started, "duplicate guest identity block");
            started = true;
        } else if line == "LIMIAR_DMI_END" {
            ensure!(started && !finished, "invalid guest identity block end");
            finished = true;
        } else if let Some(value) = line.strip_prefix("LIMIAR_DMI ") {
            ensure!(
                started && !finished,
                "DMI field outside the guest identity block"
            );
            let (key, value) = value.split_once('=').context("invalid guest DMI line")?;
            ensure!(
                !key.is_empty()
                    && key.len() <= 64
                    && key
                        .bytes()
                        .all(|byte| byte.is_ascii_lowercase() || byte == b'_')
                    && value.len() <= 256
                    && !value.contains('\0'),
                "invalid guest DMI field"
            );
            ensure!(
                observed.insert(key.to_owned(), value.to_owned()).is_none(),
                "duplicate guest DMI field {key}"
            );
            ensure!(observed.len() <= 64, "too many guest DMI fields");
        }
    }
    ensure!(
        started && finished,
        "complete guest identity block not found"
    );
    let fields: Vec<_> = expected
        .iter()
        .map(|(field, expected)| {
            let value = observed.get(field).cloned();
            let matches = value.as_ref().is_some_and(|value| {
                if field == "product_uuid" {
                    value.eq_ignore_ascii_case(expected)
                } else {
                    value == expected
                }
            });
            Comparison {
                field: field.clone(),
                expected: expected.clone(),
                observed: value,
                matches,
            }
        })
        .collect();
    Ok(Verification {
        scope: "guest_reported_smbios",
        passed: !fields.is_empty() && fields.iter().all(|field| field.matches),
        fields,
        observed_dmi: observed,
        limitation: "Guest-reported values, not hardware attestation or proof of bare-metal equivalence.",
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn qemu_preset_materializes_and_maps_all_twenty_two_fields() {
        let mut identity = Identity::default();
        let (preview, _) = identity.plan_qemu().unwrap();
        assert!(preview.requires_registration);
        assert!(identity.baseboard.is_none());
        assert!(identity.system.uuid.is_none());
        identity.materialize_qemu(None).unwrap();
        let (plan, arguments) = identity.plan_qemu().unwrap();
        assert!(!plan.requires_registration);
        assert_eq!(plan.expected_dmi.len(), 22);
        assert_eq!(plan.expected_dmi["board_name"], "Limiar Mainboard");
        assert_eq!(plan.expected_dmi["chassis_sku"], "LMR-DESKTOP");
        assert_eq!(
            arguments.iter().filter(|value| *value == "-smbios").count(),
            4
        );
        assert!(!arguments.iter().any(|value| value == "--smbios"));
        assert!(
            arguments
                .iter()
                .any(|value| value.starts_with("type=0,") && value.ends_with(",uefi=on"))
        );
    }

    #[test]
    fn qemu_updates_preserve_all_persistent_identifiers() {
        let mut original = Identity::default();
        original.materialize_qemu(None).unwrap();
        original.baseboard.as_mut().unwrap().serial = Some("MY-BOARD".into());
        original.chassis.as_mut().unwrap().serial = Some("MY-CHASSIS".into());
        let mut update = Identity::default();
        update.materialize_qemu(Some(&original)).unwrap();
        assert_eq!(update.system.uuid, original.system.uuid);
        assert_eq!(update.system.serial, original.system.serial);
        assert_eq!(
            update.baseboard.unwrap().serial.as_deref(),
            Some("MY-BOARD")
        );
        assert_eq!(
            update.chassis.unwrap().serial.as_deref(),
            Some("MY-CHASSIS")
        );
    }

    #[test]
    fn qemu_explicit_board_serial_replacement_is_respected() {
        let mut original = Identity::default();
        original.materialize_qemu(None).unwrap();
        let mut update = Identity {
            baseboard: Some(Baseboard {
                serial: Some("REPLACEMENT".into()),
                ..Default::default()
            }),
            ..Default::default()
        };
        update.materialize_qemu(Some(&original)).unwrap();
        assert_eq!(
            update.baseboard.unwrap().serial.as_deref(),
            Some("REPLACEMENT")
        );
    }

    #[test]
    fn openvmm_does_not_silently_discard_extended_tables() {
        for identity in [
            Identity {
                baseboard: Some(Baseboard::default()),
                ..Default::default()
            },
            Identity {
                chassis: Some(Chassis::default()),
                ..Default::default()
            },
        ] {
            assert!(identity.validate(true).is_err());
            assert!(identity.plan(false).is_err());
            assert!(identity.plan_qemu().is_ok());
        }
    }

    #[test]
    fn qemu_validates_extensions_and_common_fields() {
        for value in ["comma,value", "equal=value", "line\nbreak", " space", ""] {
            let identity = Identity {
                baseboard: Some(Baseboard {
                    asset: Some(value.into()),
                    ..Default::default()
                }),
                ..Default::default()
            };
            assert!(identity.plan_qemu().is_err());
        }
        let identity = Identity {
            chassis: Some(Chassis {
                sku: Some("x".repeat(65)),
                ..Default::default()
            }),
            ..Default::default()
        };
        assert!(identity.validate_qemu().is_err());
        let identity = Identity {
            bios: Some(Bios {
                date: Some("02/31/2026".into()),
                ..Default::default()
            }),
            ..Default::default()
        };
        assert!(identity.validate_qemu().is_err());
    }

    #[test]
    fn preview_does_not_generate_identifiers_and_registration_persists_them() {
        let mut identity = Identity::default();
        let (plan, _) = identity.plan(true).unwrap();
        assert!(plan.requires_registration);
        assert!(identity.system.uuid.is_none());
        identity.materialize(None, true).unwrap();
        let mut updated = Identity::default();
        updated.materialize(Some(&identity), true).unwrap();
        assert_eq!(updated.system.uuid, identity.system.uuid);
        assert_eq!(updated.system.serial, identity.system.serial);
        let mut another = Identity::default();
        another.materialize(None, true).unwrap();
        assert_ne!(another.system.uuid, identity.system.uuid);
        assert_ne!(another.system.serial, identity.system.serial);
    }

    #[test]
    fn explicit_identifiers_are_respected() {
        let mut old = Identity::default();
        old.materialize(None, true).unwrap();
        let mut new = Identity::default();
        new.system.uuid = Some(Uuid::new_v4());
        new.system.serial = Some("MY-PC-01".into());
        let chosen = new.system.uuid;
        new.materialize(Some(&old), true).unwrap();
        assert_eq!(new.system.uuid, chosen);
        assert_eq!(new.system.serial.as_deref(), Some("MY-PC-01"));
    }

    #[test]
    fn rejects_argument_delimiters_control_characters_and_invalid_uuid() {
        for value in [
            "",
            " padded ",
            "name,uuid=random",
            "name=x",
            "line\nbreak",
            "\0",
            "\u{e9}",
        ] {
            let mut identity = Identity::default();
            identity.system.manufacturer = Some(value.into());
            assert!(identity.validate(true).is_err(), "{value:?}");
        }
        for uuid in [Uuid::nil(), Uuid::from_u128(u128::MAX)] {
            let mut identity = Identity::default();
            identity.system.uuid = Some(uuid);
            assert!(identity.validate(true).is_err());
        }
    }

    #[test]
    fn validates_calendar_dates_and_bios_release() {
        for date in ["02/29/2024", "09/24/2026"] {
            assert!(validate_date(date).is_ok());
        }
        for date in [
            "02/29/2025",
            "00/01/2026",
            "13/01/2026",
            "01/32/2026",
            "1/1/2026",
            "2026-09-24",
        ] {
            assert!(validate_date(date).is_err(), "{date}");
        }
        for release in ["256.0", "1.2.3", "1", "-1.2", "1.+2"] {
            let identity = Identity {
                bios: Some(Bios {
                    release: Some(release.into()),
                    ..Default::default()
                }),
                ..Default::default()
            };
            assert!(identity.validate(true).is_err());
        }
    }

    #[test]
    fn uefi_preset_never_emits_unsupported_bios_overrides() {
        let mut identity = Identity::default();
        identity.materialize(None, false).unwrap();
        let (plan, args) = identity.plan(false).unwrap();
        assert!(!plan.expected_dmi.contains_key("bios_vendor"));
        assert!(!args.iter().any(|arg| arg.starts_with("type=0")));
        identity.bios = Some(Bios::default());
        assert!(identity.plan(false).is_err());
    }

    #[test]
    fn verifies_all_requested_fields_and_rejects_incomplete_or_duplicate_evidence() {
        let mut identity = Identity::default();
        identity.materialize(None, true).unwrap();
        let (plan, _) = identity.plan(true).unwrap();
        let lines = plan
            .expected_dmi
            .iter()
            .map(|(key, value)| format!("LIMIAR_DMI {key}={value}\n"))
            .collect::<String>();
        let transcript = format!("kernel log\nLIMIAR_DMI_BEGIN\n{lines}LIMIAR_DMI_END\n");
        let expected = &plan.expected_dmi;
        assert!(verify(expected, &transcript).unwrap().passed);
        assert!(
            !verify(expected, &transcript.replace("Limiar One", "Other PC"))
                .unwrap()
                .passed
        );
        assert!(
            !verify(expected, "LIMIAR_DMI_BEGIN\nLIMIAR_DMI_END\n")
                .unwrap()
                .passed
        );
        assert!(verify(expected, &transcript.replace("LIMIAR_DMI_END", "")).is_err());
        assert!(verify(expected, &format!("{transcript}{transcript}")).is_err());
        assert!(verify(expected, "LIMIAR_DMI product_name=x\n").is_err());
        assert!(verify(expected, "LIMIAR_DMI_BEGIN\nLIMIAR_DMI product_name=x\nLIMIAR_DMI product_name=y\nLIMIAR_DMI_END\n").is_err());
    }
}
