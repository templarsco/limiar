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
