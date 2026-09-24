use crate::gpu_pv::{ProbePlan, ProbeReport};
use anyhow::{Context, Result, ensure};
use libloading::Library;
use serde_json::Value;
use std::ffi::c_void;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::os::windows::io::AsRawHandle;
use std::path::Path;
use std::ptr;
use std::thread;
use std::time::{Duration, Instant};
use windows::Win32::Foundation::{HANDLE, HLOCAL, LocalFree};
use windows::Win32::System::Pipes::PeekNamedPipe;
use windows::core::PWSTR;

type Handle = *mut c_void;
type Completion = Option<unsafe extern "system" fn(Handle, *mut c_void)>;
type CreateOperation = unsafe extern "system" fn(*const c_void, Completion) -> Handle;
type Close = unsafe extern "system" fn(Handle);
type Cancel = unsafe extern "system" fn(Handle) -> i32;
type Wait = unsafe extern "system" fn(Handle, u32, *mut *mut u16) -> i32;
type Create =
    unsafe extern "system" fn(*const u16, *const u16, Handle, *const c_void, *mut Handle) -> i32;
type Action = unsafe extern "system" fn(Handle, Handle, *const u16) -> i32;
type Modify = unsafe extern "system" fn(Handle, Handle, *const u16, Handle) -> i32;
type Enumerate = unsafe extern "system" fn(*const u16, Handle) -> i32;

struct Api {
    _library: Library,
    create_operation: CreateOperation,
    close_operation: Close,
    cancel_operation: Cancel,
    wait: Wait,
    create: Create,
    start: Action,
    terminate: Action,
    properties: Action,
    modify: Modify,
    close_system: Close,
    enumerate: Enumerate,
}

impl Api {
    fn load() -> Result<Self> {
        // Late binding keeps diagnostics usable when the HCS component is absent.
        unsafe {
            let library =
                Library::new(crate::platform::system_directory()?.join("computecore.dll"))?;
            Ok(Self {
                create_operation: *library.get(b"HcsCreateOperation\0")?,
                close_operation: *library.get(b"HcsCloseOperation\0")?,
                cancel_operation: *library.get(b"HcsCancelOperation\0")?,
                wait: *library.get(b"HcsWaitForOperationResult\0")?,
                create: *library.get(b"HcsCreateComputeSystem\0")?,
                start: *library.get(b"HcsStartComputeSystem\0")?,
                terminate: *library.get(b"HcsTerminateComputeSystem\0")?,
                properties: *library.get(b"HcsGetComputeSystemProperties\0")?,
                modify: *library.get(b"HcsModifyComputeSystem\0")?,
                close_system: *library.get(b"HcsCloseComputeSystem\0")?,
                enumerate: *library.get(b"HcsEnumerateComputeSystems\0")?,
                _library: library,
            })
        }
    }

    fn operation(&self) -> Result<Operation<'_>> {
        let handle = unsafe { (self.create_operation)(ptr::null(), None) };
        ensure!(!handle.is_null(), "HcsCreateOperation returned no handle");
        Ok(Operation {
            api: self,
            handle,
            finished: false,
        })
    }

    fn wait_absent(&self, id: &str) -> Result<()> {
        let query = wide(&serde_json::json!({"Ids": [id]}).to_string())?;
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let mut op = self.operation()?;
            let result = unsafe { (self.enumerate)(query.as_ptr(), op.handle) };
            let text = op.wait("verify probe cleanup", result, Duration::from_secs(5))?;
            let systems: Vec<Value> =
                serde_json::from_str(&text).context("invalid HCS enumeration JSON")?;
            if systems.is_empty() {
                return Ok(());
            }
            ensure!(
                Instant::now() < deadline,
                "owned probe still exists after its handle was closed"
            );
            thread::sleep(Duration::from_millis(100));
        }
    }
}

struct Operation<'a> {
    api: &'a Api,
    handle: Handle,
    finished: bool,
}

impl Operation<'_> {
    fn wait(&mut self, label: &str, initial: i32, timeout: Duration) -> Result<String> {
        ensure!(
            initial >= 0,
            "{label}: immediate HRESULT 0x{:08x}",
            initial as u32
        );
        let mut document = ptr::null_mut();
        let result = unsafe {
            (self.api.wait)(
                self.handle,
                timeout.as_millis().min(u32::MAX as u128) as u32,
                &mut document,
            )
        };
        let text = if document.is_null() {
            String::new()
        } else {
            let text = unsafe { PWSTR(document).to_string() };
            unsafe {
                let _ = LocalFree(HLOCAL(document.cast()));
            }
            text.context("HCS returned invalid UTF-16")?
        };
        self.finished = result >= 0;
        ensure!(
            result >= 0,
            "{label}: HRESULT 0x{:08x}: {text}",
            result as u32
        );
        Ok(text)
    }
}

impl Drop for Operation<'_> {
    fn drop(&mut self) {
        unsafe {
            if !self.finished {
                (self.api.cancel_operation)(self.handle);
            }
            (self.api.close_operation)(self.handle);
        }
    }
}

struct System<'a> {
    api: &'a Api,
    handle: Handle,
}

impl<'a> System<'a> {
    fn create(api: &'a Api, plan: &ProbePlan) -> Result<Self> {
        let mut system = Self {
            api,
            handle: ptr::null_mut(),
        };
        let mut op = api.operation()?;
        let id = wide(&plan.id)?;
        let config = wide(&serde_json::to_string(&plan.configuration)?)?;
        let result = unsafe {
            (api.create)(
                id.as_ptr(),
                config.as_ptr(),
                op.handle,
                ptr::null(),
                &mut system.handle,
            )
        };
        op.wait("create HCS VM", result, Duration::from_secs(30))?;
        ensure!(
            !system.handle.is_null(),
            "HCS create succeeded without a system handle"
        );
        Ok(system)
    }

    fn action(
        &self,
        action: Action,
        label: &str,
        value: Option<&str>,
        timeout: Duration,
    ) -> Result<String> {
        let mut op = self.api.operation()?;
        let text = value.map(wide).transpose()?;
        let result = unsafe {
            action(
                self.handle,
                op.handle,
                text.as_ref().map_or(ptr::null(), |text| text.as_ptr()),
            )
        };
        op.wait(label, result, timeout)
    }

    fn attach(&self, request: &Value) -> Result<()> {
        let mut op = self.api.operation()?;
        let request = wide(&serde_json::to_string(request)?)?;
        let result =
            unsafe { (self.api.modify)(self.handle, op.handle, request.as_ptr(), ptr::null_mut()) };
        op.wait("attach selected GPU-PV", result, Duration::from_secs(30))?;
        Ok(())
    }

    fn state(&self) -> Result<Value> {
        let text = self.action(
            self.api.properties,
            "query VM state",
            Some("{}"),
            Duration::from_secs(5),
        )?;
        let properties: Value =
            serde_json::from_str(&text).context("invalid HCS properties JSON")?;
        Ok(properties)
    }
}

impl Drop for System<'_> {
    fn drop(&mut self) {
        if !self.handle.is_null() {
            let _ = self.action(
                self.api.terminate,
                "terminate owned probe",
                None,
                Duration::from_secs(5),
            );
            // The configuration also requests termination on the last handle close.
            unsafe {
                (self.api.close_system)(self.handle);
            }
        }
    }
}

fn wide(text: &str) -> Result<Vec<u16>> {
    ensure!(!text.contains('\0'), "HCS string contains NUL");
    Ok(text.encode_utf16().chain(Some(0)).collect())
}

fn connect_serial(path: &str, timeout: Duration) -> Result<File> {
    let start = Instant::now();
    loop {
        match OpenOptions::new().read(true).write(true).open(path) {
            Ok(file) => return Ok(file),
            Err(error)
                if matches!(error.raw_os_error(), Some(2 | 231)) && start.elapsed() < timeout =>
            {
                thread::sleep(Duration::from_millis(20))
            }
            Err(error) => return Err(error).context("cannot connect to the probe serial pipe"),
        }
    }
}

fn receive(file: &mut File, bytes: &mut Vec<u8>, log: &mut File) -> Result<bool> {
    let mut available = 0;
    let result = unsafe {
        PeekNamedPipe(
            HANDLE(file.as_raw_handle()),
            None,
            0,
            None,
            Some(&mut available),
            None,
        )
    };
    if let Err(error) = result {
        if matches!(error.code().0 as u32, 0x8007006d | 0x800700e8 | 0x800700e9) {
            return Ok(false);
        }
        return Err(error.into());
    }
    if available > 0 {
        let mut buffer = vec![0; (available as usize).min(16 * 1024)];
        let count = file.read(&mut buffer)?;
        ensure!(
            bytes.len() + count <= 8 * 1024 * 1024,
            "probe serial log exceeds 8 MiB"
        );
        log.write_all(&buffer[..count])?;
        bytes.extend_from_slice(&buffer[..count]);
    }
    Ok(true)
}

pub fn probe(plan: &ProbePlan, timeout: Duration, logs: &Path) -> Result<ProbeReport> {
    ensure!(
        (1..=300).contains(&timeout.as_secs()),
        "probe timeout must be 1..300 seconds"
    );
    fs::create_dir_all(logs)?;
    let directory = logs.join(format!("gpu-pv-{}", plan.id));
    fs::create_dir(&directory)?;
    let directory = directory.canonicalize()?;
    let serial_log = directory.join("serial.log");
    let mut log = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&serial_log)?;
    fs::write(
        directory.join("plan.json"),
        serde_json::to_vec_pretty(plan)?,
    )?;
    let start = Instant::now();
    let mut report = ProbeReport {
        schema_version: 1,
        scope: plan.scope,
        success: false,
        stage: "load_hcs".into(),
        error: None,
        id: plan.id.clone(),
        adapter: plan.adapter.clone(),
        vm_created: false,
        gpu_request_accepted: false,
        guest_boot_verified: false,
        guest_shutdown_verified: false,
        guest_exit_type: None,
        guest_dxg_device_reported: false,
        guest_rendering_verified: false,
        cleanup_verified: false,
        cleanup_error: None,
        elapsed_ms: 0,
        serial_log,
        limitations: plan.limitations.clone(),
    };
    let api = Api::load();
    let result = (|| -> Result<()> {
        let api = api.as_ref().map_err(|error| anyhow::anyhow!("{error:#}"))?;
        report.stage = "create_vm".into();
        let system = System::create(api, plan)?;
        report.vm_created = true;
        report.stage = "start_vm".into();
        system.action(api.start, "start HCS VM", None, Duration::from_secs(30))?;
        let mut serial = connect_serial(&plan.serial_pipe, Duration::from_secs(5))?;
        // GPU-PV is a runtime update: the partition must exist before assignment.
        report.stage = "attach_gpu_pv".into();
        system.attach(&plan.gpu_request)?;
        report.gpu_request_accepted = true;
        report.stage = "guest_probe".into();
        let mut bytes = Vec::new();
        let mut acknowledged = false;
        let deadline = Instant::now() + timeout;
        loop {
            let mut connected = receive(&mut serial, &mut bytes, &mut log)?;
            let state = system.state()?;
            let stopped = state["Stopped"] == true || state["State"] == "Stopped";
            if stopped {
                loop {
                    let before = bytes.len();
                    connected = receive(&mut serial, &mut bytes, &mut log)?;
                    if !connected || bytes.len() == before {
                        break;
                    }
                }
            }
            let text = String::from_utf8_lossy(&bytes);
            ensure!(
                !text.contains("Kernel panic - not syncing"),
                "guest kernel panic"
            );
            report.guest_boot_verified = text
                .lines()
                .any(|line| line.trim_end() == "LIMIAR_PROBE_READY")
                && text
                    .lines()
                    .any(|line| line.trim_end() == "LIMIAR_USERSPACE_OK");
            report.guest_dxg_device_reported = text
                .lines()
                .any(|line| line.trim_end() == "LIMIAR_GPU dxg_device=present");
            report.guest_rendering_verified =
                crate::gpu_pv::render_verified(plan.render_marker.as_deref(), &text);
            if report.guest_boot_verified && !acknowledged && !stopped {
                serial.write_all(b"limiar-poweroff\n")?;
                serial.flush()?;
                acknowledged = true;
            }
            if stopped {
                report.guest_exit_type = state["ExitType"].as_str().map(str::to_owned);
                report.guest_shutdown_verified =
                    report.guest_exit_type.as_deref() == Some("GracefulExit");
                ensure!(
                    report.guest_boot_verified,
                    "guest stopped without a complete probe report"
                );
                ensure!(
                    report.guest_shutdown_verified,
                    "HCS did not report GracefulExit"
                );
                ensure!(
                    plan.render_marker.is_none() || report.guest_rendering_verified,
                    "guest did not verify D3D12 pixels on the requested hardware GPU"
                );
                break;
            }
            ensure!(
                connected,
                "serial pipe disconnected before verified guest shutdown"
            );
            ensure!(Instant::now() < deadline, "guest probe timed out");
            thread::sleep(Duration::from_millis(100));
        }
        report.stage = "complete".into();
        Ok(())
    })();
    if let Ok(api) = &api {
        match api.wait_absent(&plan.id) {
            Ok(()) => report.cleanup_verified = true,
            Err(error) => report.cleanup_error = Some(format!("{error:#}")),
        }
    }
    report.elapsed_ms = start.elapsed().as_millis();
    report.success = result.is_ok() && report.cleanup_verified;
    if let Err(error) = result {
        report.error = Some(format!("{error:#}"));
    }
    log.sync_all()?;
    fs::write(
        directory.join("result.json"),
        serde_json::to_vec_pretty(&report)?,
    )?;
    Ok(report)
}
