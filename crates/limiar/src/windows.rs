use crate::report::{Adapter, Capability, DoctorReport, GpuTestReport, select_adapter};
use anyhow::{Context, Result, ensure};
use std::path::PathBuf;
use std::process::Command;
use std::time::Instant;
use windows::Win32::Graphics::Direct3D::{
    D3D_DRIVER_TYPE_UNKNOWN, D3D_FEATURE_LEVEL, D3D_FEATURE_LEVEL_10_0, D3D_FEATURE_LEVEL_10_1,
    D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_11_1,
};
use windows::Win32::Graphics::Direct3D11::*;
use windows::Win32::Graphics::Dxgi::Common::{DXGI_FORMAT_R8G8B8A8_UNORM, DXGI_SAMPLE_DESC};
use windows::Win32::Graphics::Dxgi::{
    CreateDXGIFactory1, DXGI_ADAPTER_FLAG_SOFTWARE, DXGI_ERROR_NOT_FOUND, IDXGIAdapter1,
    IDXGIFactory1,
};
use windows::Win32::System::SystemInformation::GetSystemDirectoryW;

pub(crate) fn system_directory() -> Result<PathBuf> {
    let mut path = [0_u16; 32768];
    let length = unsafe { GetSystemDirectoryW(Some(&mut path)) } as usize;
    ensure!(
        length > 0 && length < path.len(),
        "cannot locate Windows system directory"
    );
    Ok(PathBuf::from(String::from_utf16(&path[..length])?))
}

pub(crate) const FEATURE_LEVELS: [D3D_FEATURE_LEVEL; 4] = [
    D3D_FEATURE_LEVEL_11_1,
    D3D_FEATURE_LEVEL_11_0,
    D3D_FEATURE_LEVEL_10_1,
    D3D_FEATURE_LEVEL_10_0,
];

pub(crate) fn enumerate() -> Result<Vec<(IDXGIAdapter1, Adapter)>> {
    let factory: IDXGIFactory1 = unsafe { CreateDXGIFactory1()? };
    let mut result = Vec::new();
    for index in 0..128 {
        let adapter = match unsafe { factory.EnumAdapters1(index) } {
            Ok(adapter) => adapter,
            Err(error) if error.code() == DXGI_ERROR_NOT_FOUND => return Ok(result),
            Err(error) => return Err(error.into()),
        };
        let desc = unsafe { adapter.GetDesc1()? };
        let length = desc
            .Description
            .iter()
            .position(|&c| c == 0)
            .unwrap_or(desc.Description.len());
        let info = Adapter {
            index,
            luid: Some(format!(
                "{:08x}:{:08x}",
                desc.AdapterLuid.HighPart as u32, desc.AdapterLuid.LowPart
            )),
            name: String::from_utf16_lossy(&desc.Description[..length]),
            vendor_id: desc.VendorId,
            device_id: desc.DeviceId,
            dedicated_video_memory_bytes: desc.DedicatedVideoMemory as u64,
            software: desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE.0 as u32 != 0,
        };
        result.push((adapter, info));
    }
    anyhow::bail!("DXGI adapter enumeration exceeded its safety bound")
}

pub fn adapters() -> Result<Vec<Adapter>> {
    Ok(enumerate()?.into_iter().map(|(_, info)| info).collect())
}

pub fn gpu_demo(selector: &str, seconds: u16) -> Result<serde_json::Value> {
    crate::presentation::run(selector, seconds)
}

pub fn gpu_pv_inventory() -> Result<crate::gpu_pv::Inventory> {
    use std::os::windows::process::CommandExt;
    let powershell = system_directory()?.join("WindowsPowerShell/v1.0/powershell.exe");
    let output = Command::new(powershell)
        .args([
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            include_str!("../../../scripts/gpu-pv-inventory.ps1"),
        ])
        .creation_flags(0x08000000)
        .output()?;
    ensure!(
        output.status.success(),
        "GPU-PV inventory process failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout).context("invalid GPU-PV inventory JSON")
}

pub fn gpu_pv_probe(
    plan: &crate::gpu_pv::ProbePlan,
    timeout: std::time::Duration,
    logs: &std::path::Path,
) -> Result<crate::gpu_pv::ProbeReport> {
    crate::hcs::probe(plan, timeout, logs)
}

fn display_routing() -> Result<serde_json::Value> {
    use windows::Win32::Devices::Display::{
        DISPLAYCONFIG_MODE_INFO, DISPLAYCONFIG_PATH_INFO, GetDisplayConfigBufferSizes,
        QDC_ONLY_ACTIVE_PATHS, QueryDisplayConfig,
    };
    let adapters = enumerate()?;
    for _ in 0..3 {
        let (mut path_count, mut mode_count) = (0_u32, 0_u32);
        let result = unsafe {
            GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &mut path_count, &mut mode_count)
        };
        ensure!(result.0 == 0, "display path sizing failed: {}", result.0);
        ensure!(
            path_count <= 512 && mode_count <= 1024,
            "unexpected display path count"
        );
        let mut paths = vec![DISPLAYCONFIG_PATH_INFO::default(); path_count as usize];
        let mut modes = vec![DISPLAYCONFIG_MODE_INFO::default(); mode_count as usize];
        let result = unsafe {
            QueryDisplayConfig(
                QDC_ONLY_ACTIVE_PATHS,
                &mut path_count,
                paths.as_mut_ptr(),
                &mut mode_count,
                modes.as_mut_ptr(),
                None,
            )
        };
        if result.0 == 122 {
            continue; // A monitor topology change can invalidate the first count.
        }
        ensure!(result.0 == 0, "active display query failed: {}", result.0);
        let mut routes = Vec::new();
        for path in paths.iter().take(path_count as usize) {
            let mut matched = None;
            for (adapter, info) in &adapters {
                let desc = unsafe { adapter.GetDesc1()? };
                if desc.AdapterLuid.LowPart == path.sourceInfo.adapterId.LowPart
                    && desc.AdapterLuid.HighPart == path.sourceInfo.adapterId.HighPart
                {
                    matched = Some(info);
                    break;
                }
            }
            routes.push(serde_json::json!({
                "adapter_index": matched.map(|adapter| adapter.index),
                "adapter_name": matched.map(|adapter| adapter.name.as_str()),
                "source_id": path.sourceInfo.id,
                "target_id": path.targetInfo.id
            }));
        }
        return Ok(serde_json::json!({
            "status": "queried",
            "active_paths": routes,
            "limitation": "A snapshot of active display routing, not confirmation of a recovery display."
        }));
    }
    anyhow::bail!("display topology changed repeatedly")
}

fn whp_query() -> Result<bool> {
    type Query = unsafe extern "system" fn(i32, *mut u32, u32, *mut u32) -> i32;
    let path = system_directory()?.join("WinHvPlatform.dll");
    // Load from System32 explicitly; a disabled/missing WHP remains reportable.
    unsafe {
        let library = libloading::Library::new(path)?;
        let query: libloading::Symbol<'_, Query> = library.get(b"WHvGetCapability\0")?;
        let mut present = 0_u32;
        let mut written = 0_u32;
        let result = query(0, &mut present, 4, &mut written);
        ensure!(
            result >= 0,
            "WHvGetCapability failed: 0x{:08x}",
            result as u32
        );
        ensure!(written == 4, "unexpected WHP capability size: {written}");
        Ok(present != 0)
    }
}

pub fn whp_device_capabilities() -> Result<crate::gpu_pv::WhpDeviceCapabilities> {
    use crate::gpu_pv::{WhpDeviceCapabilities, WhpDeviceFeatures};
    type Query = unsafe extern "system" fn(i32, *mut u64, u32, *mut u32) -> i32;
    let path = system_directory()?.join("WinHvPlatform.dll");
    let (features, exports) = unsafe {
        let library = libloading::Library::new(path)?;
        let query: libloading::Symbol<'_, Query> = library.get(b"WHvGetCapability\0")?;
        let mut features = 0_u64;
        let mut written = 0_u32;
        let result = query(1, &mut features, 8, &mut written);
        ensure!(
            result >= 0,
            "WHP device-capability query failed: 0x{:08x}",
            result as u32
        );
        ensure!(
            written == 8,
            "unexpected WHP feature buffer size: {written}"
        );
        // Inspect exports only. Do not allocate a resource or modify a partition.
        let names = [
            "WHvAllocateVpciResource",
            "WHvCreateVpciDevice",
            "WHvDeleteVpciDevice",
            "WHvGetVpciDeviceProperty",
            "WHvReadVpciDeviceRegister",
            "WHvWriteVpciDeviceRegister",
            "WHvMapVpciDeviceMmioRanges",
            "WHvUnmapVpciDeviceMmioRanges",
            "WHvMapVpciDeviceInterrupt",
            "WHvUnmapVpciDeviceInterrupt",
            "WHvRetargetVpciDeviceInterrupt",
            "WHvGetVpciDeviceNotification",
        ];
        let exports = names
            .into_iter()
            .map(|name| {
                let symbol = format!("{name}\0");
                let available = library
                    .get::<unsafe extern "system" fn()>(symbol.as_bytes())
                    .is_ok();
                (name.to_owned(), available)
            })
            .collect();
        (features, exports)
    };
    Ok(WhpDeviceCapabilities {
        schema_version: 1,
        scope: "read_only_whp_device_backend_capabilities",
        hypervisor_present: whp_query()?,
        feature_bits: format!("0x{features:016x}"),
        features: WhpDeviceFeatures::from_bits(features),
        vpci_api_exports: exports,
        resource_allocation_attempted: false,
        qemu_gpu_pv_bridge: "not_implemented_in_limiar",
        limitations: vec![
            "Generic vPCI/IOMMU features and API exports are not GPU-PV resource-provider validation.",
            "No VM, physical device, GPU partition, host driver or boot setting was changed.",
            "The existing HCS GPU-PV probe cannot attach its resource to an unrelated QEMU partition.",
            "QEMU needs a compatible device transport and guest-driver path before this can enable GPU-PV.",
        ],
    })
}

fn host_inventory() -> Result<serde_json::Value> {
    use std::os::windows::process::CommandExt;
    let powershell = system_directory()?.join("WindowsPowerShell/v1.0/powershell.exe");
    let output = Command::new(powershell)
        .args([
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            include_str!("../../../scripts/host-inventory.ps1"),
        ])
        .creation_flags(0x08000000)
        .output()?;
    ensure!(
        output.status.success(),
        "host inventory failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let text = String::from_utf8(output.stdout)?;
    serde_json::from_str(text.trim_start_matches('\u{feff}')).context("invalid host inventory JSON")
}

pub fn doctor() -> Result<DoctorReport> {
    let mut warnings = vec![
        "No device was disabled, dismounted, partitioned, or assigned.".into(),
        "GPU inventory and WHP availability do not prove passthrough support.".into(),
        "Host display wiring requires separate physical confirmation.".into(),
        "Local inventory can contain PCI instance/location paths; review before publishing.".into(),
    ];
    let host = match host_inventory() {
        Ok(host) => host,
        Err(error) => {
            warnings.push(format!("Host inventory unavailable: {error:#}"));
            serde_json::json!({"inventory_status": "unknown"})
        }
    };
    let whp = match whp_query() {
        Ok(true) => Capability {
            status: "available",
            detail: "WHvGetCapability reports a present hypervisor".into(),
        },
        Ok(false) => Capability {
            status: "unavailable",
            detail: "WHvGetCapability reports no present hypervisor".into(),
        },
        Err(error) => Capability {
            status: "unknown",
            detail: format!("{error:#}"),
        },
    };
    let display_routing = match display_routing() {
        Ok(routing) => routing,
        Err(error) => serde_json::json!({"status": "unknown", "reason": format!("{error:#}")}),
    };
    Ok(DoctorReport {
        schema_version: 1,
        host,
        whp,
        gpu_assignment: Capability {
            status: "not_validated",
            detail: "Dedicated assignment is not implemented. DDA's documented host requirement is Windows Server; shared GPU-PV has a separate experimental probe.".into(),
        },
        adapters: adapters()?,
        display_routing,
        warnings,
    })
}

fn check_pixels(bytes: &[u8], pitch: usize, expected: [u8; 4], side: usize) -> Result<()> {
    ensure!(pitch >= side * 4, "invalid mapped row pitch");
    ensure!(bytes.len() >= pitch * side, "mapped data is truncated");
    for y in 0..side {
        for x in 0..side {
            let offset = y * pitch + x * 4;
            for channel in 0..4 {
                ensure!(
                    bytes[offset + channel].abs_diff(expected[channel]) <= 1,
                    "readback mismatch at ({x}, {y}), channel {channel}: got {}, expected {}",
                    bytes[offset + channel],
                    expected[channel]
                );
            }
        }
    }
    Ok(())
}

pub fn gpu_test(selector: &str, iterations: u16) -> Result<GpuTestReport> {
    ensure!((1..=32).contains(&iterations), "iterations must be 1..32");
    let devices = enumerate()?;
    let infos: Vec<_> = devices.iter().map(|(_, info)| info.clone()).collect();
    let index = select_adapter(&infos, selector)?;
    let (adapter, info) = &devices[index];
    let start = Instant::now();
    let mut device = None;
    let mut context = None;
    let mut feature_level = D3D_FEATURE_LEVEL_11_0;
    unsafe {
        D3D11CreateDevice(
            adapter,
            D3D_DRIVER_TYPE_UNKNOWN,
            None,
            D3D11_CREATE_DEVICE_BGRA_SUPPORT,
            Some(&FEATURE_LEVELS),
            D3D11_SDK_VERSION,
            Some(&mut device),
            Some(&mut feature_level),
            Some(&mut context),
        )?;
    }
    let device: ID3D11Device = device.context("D3D11 returned no device")?;
    let context: ID3D11DeviceContext = context.context("D3D11 returned no context")?;
    const SIDE: u32 = 64;
    let desc = D3D11_TEXTURE2D_DESC {
        Width: SIDE,
        Height: SIDE,
        MipLevels: 1,
        ArraySize: 1,
        Format: DXGI_FORMAT_R8G8B8A8_UNORM,
        SampleDesc: DXGI_SAMPLE_DESC {
            Count: 1,
            Quality: 0,
        },
        Usage: D3D11_USAGE_DEFAULT,
        BindFlags: D3D11_BIND_RENDER_TARGET.0 as u32,
        ..Default::default()
    };
    let staging_desc = D3D11_TEXTURE2D_DESC {
        Usage: D3D11_USAGE_STAGING,
        BindFlags: 0,
        CPUAccessFlags: D3D11_CPU_ACCESS_READ.0 as u32,
        ..desc
    };
    let mut texture = None;
    let mut staging = None;
    let mut view = None;
    unsafe {
        device.CreateTexture2D(&desc, None, Some(&mut texture))?;
        device.CreateTexture2D(&staging_desc, None, Some(&mut staging))?;
    }
    let texture: ID3D11Texture2D = texture.context("no render target")?;
    let staging: ID3D11Texture2D = staging.context("no staging resource")?;
    unsafe { device.CreateRenderTargetView(&texture, None, Some(&mut view))? };
    let view: ID3D11RenderTargetView = view.context("no render target view")?;
    let colors = [[17, 91, 203, 255], [231, 45, 71, 255], [0, 255, 0, 255]];
    for iteration in 0..iterations {
        let expected = colors[iteration as usize % colors.len()];
        let color = expected.map(|value| value as f32 / 255.0);
        let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
        unsafe {
            context.ClearRenderTargetView(&view, &color);
            context.CopyResource(&staging, &texture);
            context.Flush();
            context.Map(&staging, 0, D3D11_MAP_READ, 0, Some(&mut mapped))?;
        }
        // Map READ waits for the GPU copy. Always unmap before returning an error.
        let verified = (|| -> Result<()> {
            ensure!(
                !mapped.pData.is_null(),
                "D3D11 returned a null mapped pointer"
            );
            let pitch = mapped.RowPitch as usize;
            ensure!(
                (SIDE as usize * 4..=1024 * 1024).contains(&pitch),
                "invalid row pitch"
            );
            let bytes = unsafe {
                std::slice::from_raw_parts(mapped.pData.cast::<u8>(), pitch * SIDE as usize)
            };
            check_pixels(bytes, pitch, expected, SIDE as usize)
        })();
        unsafe { context.Unmap(&staging, 0) };
        verified?;
    }
    unsafe { device.GetDeviceRemovedReason()? };
    Ok(GpuTestReport {
        schema_version: 1,
        status: "passed",
        scope: "process_local_d3d11",
        adapter: info.clone(),
        feature_level: format!("0x{:x}", feature_level.0),
        iterations,
        pixels_verified: u64::from(SIDE) * u64::from(SIDE) * u64::from(iterations),
        elapsed_ms: start.elapsed().as_millis(),
        limitations: vec![
            "The caller must establish host/guest context and GPU delivery mode separately.",
            "Small clear/copy/readback workload; not a sustained-load benchmark.",
            "elapsed_ms is process wall time, not GPU timestamp-query timing.",
        ],
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validates_pixels_and_respects_row_padding() {
        let bytes = [17, 91, 203, 255, 0, 0, 0, 0];
        assert!(check_pixels(&bytes, 8, [17, 91, 203, 255], 1).is_ok());
        assert!(check_pixels(&bytes, 8, [99, 91, 203, 255], 1).is_err());
        assert!(check_pixels(&bytes, 3, [17, 91, 203, 255], 1).is_err());
    }
}
