use crate::{platform, report::select_adapter};
use anyhow::{Context, Result, ensure};
use serde_json::{Value, json};
use std::time::{Duration, Instant};
use windows::Win32::Foundation::{
    BOOL, DXGI_STATUS_OCCLUDED, HINSTANCE, HWND, LPARAM, LRESULT, RECT, WPARAM,
};
use windows::Win32::Graphics::Direct3D::Fxc::D3DCompile;
use windows::Win32::Graphics::Direct3D::{
    D3D_DRIVER_TYPE_UNKNOWN, D3D_FEATURE_LEVEL_10_0, D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST, ID3DBlob,
};
use windows::Win32::Graphics::Direct3D11::*;
use windows::Win32::Graphics::Dxgi::Common::*;
use windows::Win32::Graphics::Dxgi::*;
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::WindowsAndMessaging::*;
use windows::core::{PCSTR, PCWSTR, s, w};

const WIDTH: u32 = 960;
const HEIGHT: u32 = 600;
const SHADER: &[u8] = br#"
cbuffer Frame : register(b0) { float seconds; float aspect; float2 pad; };
struct Varying { float4 position : SV_POSITION; float3 color : COLOR; };
Varying vertex(uint id : SV_VertexID) {
    const float3 vertices[8] = {
        float3(-1,-1,-1), float3(-1,1,-1), float3(1,1,-1), float3(1,-1,-1),
        float3(-1,-1,1), float3(-1,1,1), float3(1,1,1), float3(1,-1,1)
    };
    const uint indices[36] = {
        0,1,2,0,2,3, 4,6,5,4,7,6, 4,5,1,4,1,0,
        3,2,6,3,6,7, 1,5,6,1,6,2, 4,0,3,4,3,7
    };
    const float3 colors[6] = {
        float3(.08,.75,.64), float3(.95,.31,.35), float3(.25,.50,.95),
        float3(.95,.72,.18), float3(.67,.36,.87), float3(.20,.78,.88)
    };
    float3 p = vertices[indices[id]];
    float angle = seconds * .7 + .35;
    float3 q = float3(p.x*cos(angle)+p.z*sin(angle), p.y, -p.x*sin(angle)+p.z*cos(angle));
    p = float3(q.x, q.y*cos(.4)-q.z*sin(.4), q.y*sin(.4)+q.z*cos(.4));
    p.z += 5;
    Varying output;
    output.position = float4(p.x*2/aspect, p.y*2, p.z*1.001-.1001, p.z);
    output.color = colors[id/6];
    return output;
}
float4 pixel(Varying input) : SV_TARGET { return float4(input.color, 1); }
"#;

unsafe extern "system" fn window_proc(
    window: HWND,
    message: u32,
    word: WPARAM,
    long: LPARAM,
) -> LRESULT {
    if message == WM_DESTROY {
        unsafe { PostQuitMessage(0) };
        LRESULT(0)
    } else {
        unsafe { DefWindowProcW(window, message, word, long) }
    }
}

struct Window(HWND);

impl Drop for Window {
    fn drop(&mut self) {
        unsafe {
            let _ = DestroyWindow(self.0);
        }
    }
}

fn window(title: &str) -> Result<Window> {
    let instance = HINSTANCE(unsafe { GetModuleHandleW(None)? }.0);
    let class = WNDCLASSW {
        lpfnWndProc: Some(window_proc),
        hInstance: instance,
        lpszClassName: w!("LimiarGraphicsProbe"),
        hCursor: unsafe { LoadCursorW(None, IDC_ARROW)? },
        ..Default::default()
    };
    ensure!(
        unsafe { RegisterClassW(&class) } != 0,
        "cannot register graphics window"
    );
    let style = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX;
    let mut rect = RECT {
        right: WIDTH as i32,
        bottom: HEIGHT as i32,
        ..Default::default()
    };
    unsafe { AdjustWindowRect(&mut rect, style, false)? };
    let title: Vec<u16> = title.encode_utf16().chain(Some(0)).collect();
    let handle = unsafe {
        CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            class.lpszClassName,
            PCWSTR(title.as_ptr()),
            style | WS_VISIBLE,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            rect.right - rect.left,
            rect.bottom - rect.top,
            None,
            None,
            instance,
            None,
        )?
    };
    Ok(Window(handle))
}

fn compile(entry: PCSTR, target: PCSTR) -> Result<Vec<u8>> {
    let mut code = None;
    let mut errors: Option<ID3DBlob> = None;
    let result = unsafe {
        D3DCompile(
            SHADER.as_ptr().cast(),
            SHADER.len(),
            s!("limiar-probe"),
            None,
            None,
            entry,
            target,
            0,
            0,
            &mut code,
            Some(&mut errors),
        )
    };
    if let Err(error) = result {
        let detail = errors
            .map(|blob| unsafe {
                String::from_utf8_lossy(std::slice::from_raw_parts(
                    blob.GetBufferPointer().cast::<u8>(),
                    blob.GetBufferSize(),
                ))
                .into_owned()
            })
            .unwrap_or_default();
        anyhow::bail!("scene shader compilation failed: {error}: {detail}");
    }
    let code = code.context("shader compiler returned no bytecode")?;
    Ok(unsafe {
        std::slice::from_raw_parts(code.GetBufferPointer().cast::<u8>(), code.GetBufferSize())
            .to_vec()
    })
}

fn colored_pixels(
    device: &ID3D11Device,
    context: &ID3D11DeviceContext,
    target: &ID3D11Texture2D,
) -> Result<u64> {
    let mut description = D3D11_TEXTURE2D_DESC::default();
    unsafe { target.GetDesc(&mut description) };
    description.Usage = D3D11_USAGE_STAGING;
    description.BindFlags = 0;
    description.CPUAccessFlags = D3D11_CPU_ACCESS_READ.0 as u32;
    let mut staging = None;
    unsafe { device.CreateTexture2D(&description, None, Some(&mut staging))? };
    let staging = staging.context("no scene readback resource")?;
    let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
    unsafe {
        context.CopyResource(&staging, target);
        context.Map(&staging, 0, D3D11_MAP_READ, 0, Some(&mut mapped))?;
    }
    let result = (|| {
        let pitch = mapped.RowPitch as usize;
        ensure!(
            !mapped.pData.is_null() && (WIDTH as usize * 4..=1024 * 1024).contains(&pitch),
            "invalid scene readback mapping"
        );
        let bytes = unsafe {
            std::slice::from_raw_parts(mapped.pData.cast::<u8>(), pitch * HEIGHT as usize)
        };
        Ok(bytes
            .chunks_exact(pitch)
            .take(HEIGHT as usize)
            .map(|row| {
                row[..WIDTH as usize * 4]
                    .chunks_exact(4)
                    .filter(|pixel| pixel[..3].iter().any(|&channel| channel > 40))
                    .count() as u64
            })
            .sum())
    })();
    unsafe { context.Unmap(&staging, 0) };
    result
}

pub fn run(selector: &str, seconds: u16) -> Result<Value> {
    ensure!(
        (1..=300).contains(&seconds),
        "demo duration must be 1..300 seconds"
    );
    let mut devices = platform::enumerate()?;
    let infos = devices
        .iter()
        .map(|(_, info)| info.clone())
        .collect::<Vec<_>>();
    let index = select_adapter(&infos, selector)?;
    let (adapter, info) = devices.swap_remove(index);
    let window = window(&format!("Limiar 3D | {}", info.name))?;
    let description = DXGI_SWAP_CHAIN_DESC {
        BufferDesc: DXGI_MODE_DESC {
            Width: WIDTH,
            Height: HEIGHT,
            Format: DXGI_FORMAT_R8G8B8A8_UNORM,
            ..Default::default()
        },
        SampleDesc: DXGI_SAMPLE_DESC {
            Count: 1,
            Quality: 0,
        },
        BufferUsage: DXGI_USAGE_RENDER_TARGET_OUTPUT,
        BufferCount: 2,
        OutputWindow: window.0,
        Windowed: BOOL(1),
        SwapEffect: DXGI_SWAP_EFFECT_DISCARD,
        ..Default::default()
    };
    let (mut swapchain, mut device, mut context) = (None, None, None);
    let mut feature = D3D_FEATURE_LEVEL_10_0;
    unsafe {
        D3D11CreateDeviceAndSwapChain(
            &adapter,
            D3D_DRIVER_TYPE_UNKNOWN,
            None,
            D3D11_CREATE_DEVICE_FLAG::default(),
            Some(&platform::FEATURE_LEVELS),
            D3D11_SDK_VERSION,
            Some(&description),
            Some(&mut swapchain),
            Some(&mut device),
            Some(&mut feature),
            Some(&mut context),
        )?;
    }
    let device = device.context("no presentation device")?;
    let context = context.context("no presentation context")?;
    let swapchain = swapchain.context("no swapchain")?;
    let target: ID3D11Texture2D = unsafe { swapchain.GetBuffer(0)? };
    let mut view = None;
    unsafe { device.CreateRenderTargetView(&target, None, Some(&mut view))? };
    let view = view.context("no presentation target view")?;
    let depth_desc = D3D11_TEXTURE2D_DESC {
        Width: WIDTH,
        Height: HEIGHT,
        MipLevels: 1,
        ArraySize: 1,
        Format: DXGI_FORMAT_D24_UNORM_S8_UINT,
        SampleDesc: DXGI_SAMPLE_DESC {
            Count: 1,
            Quality: 0,
        },
        Usage: D3D11_USAGE_DEFAULT,
        BindFlags: D3D11_BIND_DEPTH_STENCIL.0 as u32,
        ..Default::default()
    };
    let (mut depth, mut depth_view) = (None, None);
    unsafe { device.CreateTexture2D(&depth_desc, None, Some(&mut depth))? };
    let depth = depth.context("no depth buffer")?;
    unsafe { device.CreateDepthStencilView(&depth, None, Some(&mut depth_view))? };
    let depth_view = depth_view.context("no depth view")?;
    let (mut vertex, mut pixel, mut constants) = (None, None, None);
    unsafe {
        device.CreateVertexShader(
            &compile(s!("vertex"), s!("vs_4_0"))?,
            None,
            Some(&mut vertex),
        )?;
        device.CreatePixelShader(&compile(s!("pixel"), s!("ps_4_0"))?, None, Some(&mut pixel))?;
        device.CreateBuffer(
            &D3D11_BUFFER_DESC {
                ByteWidth: 16,
                Usage: D3D11_USAGE_DEFAULT,
                BindFlags: D3D11_BIND_CONSTANT_BUFFER.0 as u32,
                ..Default::default()
            },
            None,
            Some(&mut constants),
        )?;
    }
    let vertex = vertex.context("no vertex shader")?;
    let pixel = pixel.context("no pixel shader")?;
    let constants = constants.context("no frame constant buffer")?;
    unsafe {
        context.VSSetShader(&vertex, None);
        context.PSSetShader(&pixel, None);
        context.VSSetConstantBuffers(0, Some(&[Some(constants.clone())]));
        context.IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        context.OMSetRenderTargets(Some(&[Some(view.clone())]), &depth_view);
        context.RSSetViewports(Some(&[D3D11_VIEWPORT {
            Width: WIDTH as f32,
            Height: HEIGHT as f32,
            MaxDepth: 1.0,
            ..Default::default()
        }]));
    }
    let start = Instant::now();
    let duration = Duration::from_secs(u64::from(seconds));
    let mut frames = 0_u64;
    let mut verified = 0;
    let mut samples = Vec::new();
    let mut closed = false;
    while start.elapsed() < duration {
        let mut message = MSG::default();
        while unsafe { PeekMessageW(&mut message, None, 0, 0, PM_REMOVE).as_bool() } {
            if message.message == WM_QUIT {
                closed = true;
                break;
            }
            unsafe {
                let _ = TranslateMessage(&message);
                DispatchMessageW(&message);
            }
        }
        if closed {
            break;
        }
        let frame_start = Instant::now();
        let params = [
            start.elapsed().as_secs_f32(),
            WIDTH as f32 / HEIGHT as f32,
            0.0,
            0.0,
        ];
        unsafe {
            context.UpdateSubresource(&constants, 0, None, params.as_ptr().cast(), 0, 0);
            context.ClearRenderTargetView(&view, &[0.03, 0.04, 0.055, 1.0]);
            context.ClearDepthStencilView(&depth_view, D3D11_CLEAR_DEPTH.0, 1.0, 0);
            context.Draw(36, 0);
        }
        if frames == 0 {
            verified = colored_pixels(&device, &context, &target)?;
            ensure!(
                verified > 1000,
                "scene readback is blank or contains no drawn geometry"
            );
        }
        let result = unsafe { swapchain.Present(1, DXGI_PRESENT(0)) };
        result.ok()?;
        if result == DXGI_STATUS_OCCLUDED {
            std::thread::sleep(Duration::from_millis(50));
            continue;
        }
        frames += 1;
        if samples.len() < 100_000 {
            samples.push(frame_start.elapsed().as_secs_f64() * 1000.0);
        }
    }
    unsafe { device.GetDeviceRemovedReason()? };
    ensure!(frames >= 2, "not enough presented frames");
    samples.sort_by(f64::total_cmp);
    let percentile = |percent: usize| samples[((samples.len() - 1) * percent) / 100];
    Ok(json!({
        "schema_version": 1, "status": "passed",
        "scope": "process_local_d3d11_presentation", "adapter": info,
        "feature_level": format!("0x{:x}", feature.0),
        "width": WIDTH, "height": HEIGHT, "frames_presented": frames,
        "drawn_pixels_verified": verified, "elapsed_ms": start.elapsed().as_millis(),
        "completed_duration": !closed, "requested_seconds": seconds,
        "submit_present_ms": {"p50": percentile(50), "p95": percentile(95), "p99": percentile(99)},
        "limitations": [
            "A small shader and presentation probe, not a game benchmark.",
            "Submission/Present wall time is not display latency or measured monitor refresh.",
            "Guest context, graphics transport and the physical rendering adapter require separate evidence.",
            "Software adapters are rejected; no WARP fallback is used."
        ]
    }))
}
