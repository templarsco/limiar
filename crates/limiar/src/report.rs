use serde::Serialize;

#[derive(Debug, Serialize)]
pub struct Capability {
    pub status: &'static str,
    pub detail: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct Adapter {
    pub index: u32,
    pub name: String,
    pub vendor_id: u32,
    pub device_id: u32,
    pub dedicated_video_memory_bytes: u64,
    pub software: bool,
}

#[derive(Debug, Serialize)]
pub struct DoctorReport {
    pub schema_version: u32,
    pub host: serde_json::Value,
    pub whp: Capability,
    pub gpu_assignment: Capability,
    pub adapters: Vec<Adapter>,
    pub display_routing: serde_json::Value,
    pub warnings: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct GpuTestReport {
    pub schema_version: u32,
    pub status: &'static str,
    pub scope: &'static str,
    pub adapter: Adapter,
    pub feature_level: String,
    pub iterations: u16,
    pub pixels_verified: u64,
    pub elapsed_ms: u128,
    pub limitations: Vec<&'static str>,
}

pub fn select_adapter(adapters: &[Adapter], selector: &str) -> anyhow::Result<usize> {
    anyhow::ensure!(
        !selector.trim().is_empty(),
        "adapter selector cannot be empty"
    );
    let selector = selector.to_lowercase();
    let numeric_index = selector.parse::<u32>().ok();
    let matches: Vec<_> = adapters
        .iter()
        .enumerate()
        .filter(|(_, adapter)| {
            !adapter.software
                && match numeric_index {
                    Some(index) => adapter.index == index,
                    None => adapter.name.to_lowercase().contains(&selector),
                }
        })
        .map(|(index, _)| index)
        .collect();
    match matches.as_slice() {
        [index] => Ok(*index),
        [] => anyhow::bail!("no hardware adapter matches {selector:?}"),
        _ => anyhow::bail!("ambiguous adapter selector {selector:?}; use the DXGI index"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn adapters() -> Vec<Adapter> {
        ["AMD Radeon Graphics", "AMD Radeon RX 9070 XT", "Software"]
            .into_iter()
            .enumerate()
            .map(|(i, name)| Adapter {
                index: i as u32,
                name: name.into(),
                vendor_id: 0,
                device_id: 0,
                dedicated_video_memory_bytes: 0,
                software: i == 2,
            })
            .collect()
    }

    #[test]
    fn selection_is_explicit_and_case_insensitive() {
        assert_eq!(select_adapter(&adapters(), "rx 9070 xt").unwrap(), 1);
        assert_eq!(select_adapter(&adapters(), "0").unwrap(), 0);
    }

    #[test]
    fn selection_rejects_ambiguity_missing_and_software() {
        for selector in ["", "AMD", "not-a-gpu", "2", "Software"] {
            assert!(select_adapter(&adapters(), selector).is_err());
        }
    }
}
