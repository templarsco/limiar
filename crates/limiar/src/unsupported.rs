use crate::report::{Adapter, Capability, DoctorReport, GpuTestReport};
use anyhow::{Result, bail};

pub fn adapters() -> Result<Vec<Adapter>> {
    bail!("DXGI GPU diagnostics currently require Windows");
}

pub fn gpu_test(_selector: &str, _iterations: u16) -> Result<GpuTestReport> {
    bail!("the native D3D11 test currently requires Windows");
}

pub fn doctor() -> Result<DoctorReport> {
    Ok(DoctorReport {
        schema_version: 1,
        host: serde_json::json!({"os": std::env::consts::OS}),
        whp: Capability {
            status: "unavailable",
            detail: "WHP requires Windows; other Limiar backends are not implemented yet".into(),
        },
        gpu_assignment: Capability {
            status: "not_implemented",
            detail: "this release does not assign PCI devices".into(),
        },
        adapters: Vec::new(),
        display_routing: serde_json::json!({"status": "unavailable"}),
        warnings: vec!["Only profile validation is supported on this platform".into()],
    })
}
pub fn gpu_pv_inventory() -> anyhow::Result<crate::gpu_pv::Inventory> {
    anyhow::bail!("GPU-PV host inventory currently requires Windows")
}

pub fn gpu_pv_probe(
    _plan: &crate::gpu_pv::ProbePlan,
    _timeout: std::time::Duration,
    _logs: &std::path::Path,
) -> anyhow::Result<crate::gpu_pv::ProbeReport> {
    anyhow::bail!("HCS GPU-PV execution requires Windows")
}
pub fn gpu_demo(_selector: &str, _seconds: u16) -> anyhow::Result<serde_json::Value> {
    anyhow::bail!("The D3D11 presentation probe requires Windows")
}
