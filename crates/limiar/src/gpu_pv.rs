use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use uuid::Uuid;

#[derive(Debug, Serialize, PartialEq, Eq)]
pub struct WhpDeviceFeatures {
    pub virtual_pci: bool,
    pub iommu: bool,
}

impl WhpDeviceFeatures {
    pub fn from_bits(bits: u64) -> Self {
        Self {
            virtual_pci: bits & (1 << 7) != 0,
            iommu: bits & (1 << 8) != 0,
        }
    }
}

#[derive(Debug, Serialize)]
pub struct WhpDeviceCapabilities {
    pub schema_version: u32,
    pub scope: &'static str,
    pub hypervisor_present: bool,
    pub feature_bits: String,
    pub features: WhpDeviceFeatures,
    pub vpci_api_exports: BTreeMap<String, bool>,
    pub resource_allocation_attempted: bool,
    pub qemu_gpu_pv_bridge: &'static str,
    pub limitations: Vec<&'static str>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Adapter {
    pub name: String,
    pub device_interface: String,
    pub driver_version: Option<String>,
    pub partition_count: u32,
    pub valid_partition_counts: Vec<u32>,
    pub raw_quotas: BTreeMap<String, BTreeMap<String, String>>,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Inventory {
    pub schema_version: u32,
    pub status: String,
    pub adapters: Vec<Adapter>,
    pub error: Option<String>,
    pub limitations: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct ProbePlan {
    pub schema_version: u32,
    pub scope: &'static str,
    pub id: String,
    pub adapter: Adapter,
    pub kernel: PathBuf,
    pub initrd: PathBuf,
    pub serial_pipe: String,
    pub configuration: Value,
    pub gpu_request: Value,
    pub render_marker: Option<String>,
    pub limitations: Vec<&'static str>,
}

#[derive(Debug, Serialize)]
pub struct ProbeReport {
    pub schema_version: u32,
    pub scope: &'static str,
    pub success: bool,
    pub stage: String,
    pub error: Option<String>,
    pub id: String,
    pub adapter: Adapter,
    pub vm_created: bool,
    pub gpu_request_accepted: bool,
    pub guest_boot_verified: bool,
    pub guest_shutdown_verified: bool,
    pub guest_exit_type: Option<String>,
    pub guest_dxg_device_reported: bool,
    pub guest_rendering_verified: bool,
    pub cleanup_verified: bool,
    pub cleanup_error: Option<String>,
    pub elapsed_ms: u128,
    pub serial_log: PathBuf,
    pub limitations: Vec<&'static str>,
}

pub fn select<'a>(inventory: &'a Inventory, selector: &str) -> Result<&'a Adapter> {
    ensure!(
        inventory.schema_version == 1 && inventory.status == "queried",
        "GPU-PV inventory unavailable: {}",
        inventory.error.as_deref().unwrap_or("unknown")
    );
    ensure!(
        !selector.trim().is_empty(),
        "GPU-PV adapter selector cannot be empty"
    );
    let matches: Vec<_> = inventory
        .adapters
        .iter()
        .filter(|adapter| {
            adapter.device_interface.eq_ignore_ascii_case(selector)
                || adapter
                    .name
                    .to_lowercase()
                    .contains(&selector.to_lowercase())
        })
        .collect();
    match matches.as_slice() {
        [adapter] => Ok(adapter),
        [] => anyhow::bail!("no partitionable GPU matches {selector:?}"),
        _ => anyhow::bail!("ambiguous GPU-PV selector; use an exact device_interface"),
    }
}

fn boot_path(path: &Path) -> Result<(PathBuf, String)> {
    ensure!(
        path.is_file(),
        "boot input is not a file: {}",
        path.display()
    );
    let absolute = path.canonicalize()?;
    let text = absolute.to_str().context("boot path is not valid UTF-8")?;
    let text = text.strip_prefix(r"\\?\").unwrap_or(text);
    ensure!(
        !text.starts_with("UNC\\")
            && !text.starts_with("\\\\")
            && !text.contains(['\0', '\r', '\n']),
        "HCS probe requires local boot files"
    );
    Ok((absolute.clone(), text.to_owned()))
}

pub fn plan(
    adapter: &Adapter,
    kernel: &Path,
    initrd: &Path,
    verify_rendering: bool,
) -> Result<ProbePlan> {
    ensure!(
        adapter.device_interface.starts_with(r"\\?\")
            && adapter.device_interface.len() <= 2048
            && !adapter.device_interface.contains(['\0', '\r', '\n']),
        "invalid GPU device interface"
    );
    let (kernel, kernel_argument) = boot_path(kernel)?;
    let (initrd, initrd_argument) = boot_path(initrd)?;
    let id = Uuid::new_v4().to_string();
    let serial_pipe = format!(r"\\.\pipe\limiar-gpu-pv-{id}");
    let request = BTreeMap::from([(adapter.device_interface.clone(), 65535_u16)]);
    let mut cmdline = "console=ttyS0,115200 8250_core.nr_uarts=1 8250_core.skip_txen_test=1 panic=-1 rdinit=/limiar/probe-init limiar_probe_delay=2 limiar_probe_ack=1".to_owned();
    let render_marker = if verify_rendering {
        let (vendor, device) = hardware_ids(&adapter.device_interface)?;
        cmdline.push_str(&format!(" limiar_gpu_probe={vendor:04x}:{device:04x}"));
        Some(format!(
            "LIMIAR_GPU_RENDER api=d3d12-clear-readback vendor={vendor:04x} device={device:04x} pixels=4096"
        ))
    } else {
        None
    };
    let mut gpu_request = json!({
        "ResourcePath": "VirtualMachine/ComputeTopology/Gpu",
        "RequestType": "Update",
        "Settings": {
            "AssignmentMode": "List",
            "AssignmentRequest": request,
            "AllowVendorExtension": true
        }
    });
    if verify_rendering {
        // Match WSL's headless Linux GPU path; these are not Windows display flags.
        gpu_request["Settings"]["DisableGdiAcceleration"] = json!(true);
        gpu_request["Settings"]["DisablePresentation"] = json!(true);
    }
    Ok(ProbePlan {
        schema_version: 1,
        scope: if verify_rendering {
            "experimental_hcs_gpu_pv_linux_render_probe"
        } else {
            "experimental_hcs_gpu_pv_linux_probe"
        },
        id,
        adapter: adapter.clone(),
        kernel,
        initrd,
        serial_pipe: serial_pipe.clone(),
        configuration: json!({
            "SchemaVersion": {"Major": 2, "Minor": 2},
            "Owner": "Limiar.GpuPvProbe",
            "ShouldTerminateOnLastHandleClosed": true,
            "VirtualMachine": {
                "StopOnReset": true,
                "Chipset": {
                    "LinuxKernelDirect": {
                        "KernelFilePath": kernel_argument,
                        "InitRdPath": initrd_argument,
                        "KernelCmdLine": cmdline
                    }
                },
                "ComputeTopology": {
                    "Memory": {"SizeInMB": 1024, "AllowOvercommit": true},
                    "Processor": {"Count": 2}
                },
                "Devices": {"ComPorts": {"0": {"NamedPipe": serial_pipe}}}
            }
        }),
        gpu_request,
        render_marker,
        limitations: vec![
            "Disposable HCS laboratory VM, separate from the OpenVMM managed VM backend.",
            "No network, host directory shares, attached guest disks, or GPU disable/dismount operations.",
            "GPU request acceptance and /dev/dxg do not prove working guest rendering.",
            "HCS does not consume the OpenVMM SMBIOS identity configuration.",
            "No quota/performance guarantee; Windows client Radeon compatibility is experimental.",
        ],
    })
}

fn hardware_ids(interface: &str) -> Result<(u16, u16)> {
    let interface = interface.to_ascii_uppercase();
    let parse = |prefix: &str| -> Result<u16> {
        let value = interface
            .split(prefix)
            .nth(1)
            .context("GPU interface has no PCI hardware ID")?;
        let value = value.get(..4).context("truncated PCI hardware ID")?;
        ensure!(
            value.bytes().all(|byte| byte.is_ascii_hexdigit()),
            "invalid PCI hardware ID"
        );
        Ok(u16::from_str_radix(value, 16)?)
    };
    Ok((parse("VEN_")?, parse("DEV_")?))
}

pub fn render_verified(marker: Option<&str>, transcript: &str) -> bool {
    marker.is_some_and(|marker| {
        transcript
            .lines()
            .filter(|line| line.trim_end_matches('\r') == marker)
            .count()
            == 1
            && !transcript.contains("LIMIAR_GPU_RENDER_FAILED")
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn whp_device_features_preserve_independent_capability_bits() {
        assert_eq!(
            WhpDeviceFeatures::from_bits(0),
            WhpDeviceFeatures {
                virtual_pci: false,
                iommu: false
            }
        );
        assert_eq!(
            WhpDeviceFeatures::from_bits(1 << 7),
            WhpDeviceFeatures {
                virtual_pci: true,
                iommu: false
            }
        );
        assert_eq!(
            WhpDeviceFeatures::from_bits(1 << 8),
            WhpDeviceFeatures {
                virtual_pci: false,
                iommu: true
            }
        );
        assert_eq!(
            WhpDeviceFeatures::from_bits((1 << 7) | (1 << 8)),
            WhpDeviceFeatures {
                virtual_pci: true,
                iommu: true
            }
        );
        assert_eq!(
            WhpDeviceFeatures::from_bits((1 << 6) | (1 << 9) | (1 << 63)),
            WhpDeviceFeatures::from_bits(0)
        );
    }

    fn adapter(name: &str, suffix: &str) -> Adapter {
        Adapter {
            name: name.into(),
            device_interface: format!(r"\\?\PCI#{suffix}"),
            driver_version: None,
            partition_count: 32,
            valid_partition_counts: vec![32],
            raw_quotas: BTreeMap::new(),
        }
    }

    #[test]
    fn selector_never_falls_back_to_a_default_gpu() {
        let mut inventory = Inventory {
            schema_version: 1,
            status: "queried".into(),
            adapters: vec![adapter("AMD integrated", "1"), adapter("AMD RX", "2")],
            error: None,
            limitations: vec![],
        };
        assert_eq!(select(&inventory, "RX").unwrap().name, "AMD RX");
        for bad in ["", "AMD", "missing"] {
            assert!(select(&inventory, bad).is_err());
        }
        assert_eq!(
            select(&inventory, r"\\?\PCI#1").unwrap().name,
            "AMD integrated"
        );
        inventory.status = "unknown".into();
        assert!(select(&inventory, "RX").is_err());
    }

    #[test]
    fn probe_requests_exactly_one_shared_gpu_and_has_no_host_shares_or_network() {
        let dir = tempfile::tempdir().unwrap();
        let kernel = dir.path().join("kernel with spaces");
        let initrd = dir.path().join("initrd");
        std::fs::write(&kernel, b"fixture").unwrap();
        std::fs::write(&initrd, b"fixture").unwrap();
        let adapter = adapter("AMD RX", "2");
        let plan = plan(&adapter, &kernel, &initrd, false).unwrap();
        assert_eq!(
            plan.configuration["ShouldTerminateOnLastHandleClosed"],
            true
        );
        assert_eq!(plan.configuration["Owner"], "Limiar.GpuPvProbe");
        let devices = plan.configuration["VirtualMachine"]["Devices"]
            .as_object()
            .unwrap();
        assert_eq!(devices.len(), 1);
        assert!(devices.contains_key("ComPorts"));
        let requested = plan.gpu_request["Settings"]["AssignmentRequest"]
            .as_object()
            .unwrap();
        assert_eq!(requested.len(), 1);
        assert_eq!(requested[&adapter.device_interface], 65535);
        assert_eq!(plan.gpu_request["Settings"]["AssignmentMode"], "List");
    }

    #[test]
    fn render_target_requires_exact_numeric_pci_ids() {
        assert_eq!(
            hardware_ids(r"\\?\PCI#VEN_1002&DEV_7550&SUBSYS_1").unwrap(),
            (0x1002, 0x7550)
        );
        for bad in [
            r"\\?\PCI#1",
            "VEN_zzzz&DEV_7550",
            "VEN_1002&DEV_",
            "VEN_1002&DEV_75xx",
        ] {
            assert!(hardware_ids(bad).is_err());
        }
    }

    #[test]
    fn rendering_needs_one_exact_result_and_no_failure_marker() {
        let marker =
            "LIMIAR_GPU_RENDER api=d3d12-clear-readback vendor=1002 device=7550 pixels=4096";
        assert!(render_verified(Some(marker), &format!("{marker}\r\n")));
        for text in [
            "LIMIAR_PROBE_READY".to_owned(),
            marker.replace("7550", "13c0"),
            marker.replace("4096", "1"),
            format!("prefix {marker}"),
            format!("{marker}\n{marker}\n"),
            format!("{marker}\nLIMIAR_GPU_RENDER_FAILED\n"),
        ] {
            assert!(!render_verified(Some(marker), &text));
        }
        assert!(!render_verified(None, marker));
    }
}
