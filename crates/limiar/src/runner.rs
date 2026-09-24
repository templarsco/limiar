use crate::config::LaunchPlan;
use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use std::fs::{self, File};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const MAX_LOG_BYTES: u64 = 8 * 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Run,
    Smoke,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct RunReport {
    pub schema_version: u32,
    pub name: String,
    pub success: bool,
    pub stop_reason: String,
    pub exit_code: Option<i32>,
    pub marker_seen: bool,
    pub elapsed_ms: u128,
    pub stdout_log: PathBuf,
    pub stderr_log: PathBuf,
    pub gpu_assignment: bool,
}

#[derive(Debug, Clone, Copy)]
pub enum RunEvent {
    Started(u32),
    MarkerSeen,
}

pub struct RunControl<'a> {
    pub notify: &'a dyn Fn(RunEvent) -> Result<()>,
    pub stop_requested: &'a dyn Fn() -> Result<bool>,
}

struct ManagedChild {
    child: Child,
    #[cfg(windows)]
    _job: std::os::windows::io::OwnedHandle,
}

impl Drop for ManagedChild {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn spawn(mut command: Command) -> Result<ManagedChild> {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x08000000); // CREATE_NO_WINDOW
    }
    let child = command.spawn().context("could not start runtime")?;
    #[cfg(windows)]
    let mut child = child;
    #[cfg(windows)]
    let job = match attach_job(&child) {
        Ok(job) => job,
        Err(error) => {
            let _ = child.kill();
            let _ = child.wait();
            return Err(error);
        }
    };
    Ok(ManagedChild {
        child,
        #[cfg(windows)]
        _job: job,
    })
}

#[cfg(windows)]
fn attach_job(child: &Child) -> Result<std::os::windows::io::OwnedHandle> {
    use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle};
    use windows::Win32::Foundation::HANDLE;
    use windows::Win32::System::JobObjects::{
        AssignProcessToJobObject, CreateJobObjectW, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JobObjectExtendedLimitInformation,
        SetInformationJobObject,
    };
    // The job owns this runtime and its descendants, never unrelated processes.
    unsafe {
        let handle = CreateJobObjectW(None, None)?;
        let owned = OwnedHandle::from_raw_handle(handle.0);
        let mut limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        SetInformationJobObject(
            handle,
            JobObjectExtendedLimitInformation,
            &limits as *const _ as *const _,
            std::mem::size_of_val(&limits) as u32,
        )?;
        AssignProcessToJobObject(handle, HANDLE(child.as_raw_handle()))?;
        Ok(owned)
    }
}

fn transcript(stdout: &Path, stderr: &Path) -> Result<Option<String>> {
    let mut out = Vec::new();
    File::open(stdout)?
        .take(MAX_LOG_BYTES + 1)
        .read_to_end(&mut out)?;
    if out.len() as u64 > MAX_LOG_BYTES {
        return Ok(None);
    }
    let mut err = Vec::new();
    File::open(stderr)?
        .take(MAX_LOG_BYTES - out.len() as u64 + 1)
        .read_to_end(&mut err)?;
    if (out.len() + err.len()) as u64 > MAX_LOG_BYTES {
        return Ok(None);
    }
    let mut text = String::from_utf8_lossy(&out).into_owned();
    text.push('\n');
    text.push_str(&String::from_utf8_lossy(&err));
    Ok(Some(text))
}

pub fn execute(plan: &LaunchPlan, mode: Mode, timeout: Duration, logs: &Path) -> Result<RunReport> {
    execute_controlled(plan, mode, timeout, logs, None)
}

pub fn execute_controlled(
    plan: &LaunchPlan,
    mode: Mode,
    timeout: Duration,
    logs: &Path,
    control: Option<&RunControl<'_>>,
) -> Result<RunReport> {
    ensure!(plan.ready, "one or more required input files are missing");
    ensure!(!plan.gpu_assignment, "device assignment is not implemented");
    ensure!(!timeout.is_zero(), "timeout must be positive");
    if mode == Mode::Smoke {
        ensure!(
            plan.serial_marker.is_some(),
            "smoke requires verification.serial_marker in the profile"
        );
    }
    fs::create_dir_all(logs)?;
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
    let directory = logs.join(format!("{}-{stamp}-{}", plan.name, std::process::id()));
    fs::create_dir(&directory)?;
    let directory = directory.canonicalize()?;
    let stdout_log = directory.join("stdout.log");
    let stderr_log = directory.join("stderr.log");
    let mut command = Command::new(&plan.executable);
    command
        .args(&plan.arguments)
        .stdin(Stdio::null())
        .stdout(Stdio::from(File::create(&stdout_log)?))
        .stderr(Stdio::from(File::create(&stderr_log)?));
    let mut process = spawn(command)?;
    if let Some(control) = control {
        (control.notify)(RunEvent::Started(process.child.id()))?;
    }
    let start = Instant::now();
    let mut marker_seen = false;
    let mut marker_time = None;
    let (success, stop_reason, exit_code) = loop {
        let Some(text) = transcript(&stdout_log, &stderr_log)? else {
            break (false, "log_limit", None);
        };
        if let Some(marker) = &plan.serial_marker {
            marker_seen |= text.contains(marker);
            if marker_seen && marker_time.is_none() {
                marker_time = Some(Instant::now());
                if let Some(control) = control {
                    (control.notify)(RunEvent::MarkerSeen)?;
                }
            }
        }
        if text.contains("Kernel panic - not syncing") {
            break (false, "guest_kernel_panic", None);
        }
        if let Some(status) = process.child.try_wait()? {
            // Re-read after exit: the final write can race the previous read.
            if let Some(text) = transcript(&stdout_log, &stderr_log)? {
                if text.contains("Kernel panic - not syncing") {
                    break (false, "guest_kernel_panic", status.code());
                }
                if let Some(marker) = &plan.serial_marker {
                    marker_seen |= text.contains(marker);
                }
            } else {
                break (false, "log_limit", status.code());
            }
            let verified = plan.serial_marker.is_none() || marker_seen;
            break (
                status.success() && verified,
                if status.success() && verified {
                    "guest_exit"
                } else {
                    "failed_or_unverified_exit"
                },
                status.code(),
            );
        }
        if let Some(control) = control
            && (control.stop_requested)()?
        {
            break (true, "stop_requested", None);
        }
        if mode == Mode::Smoke
            && marker_time.is_some_and(|time| time.elapsed() >= Duration::from_secs(2))
        {
            break (true, "verified_then_stopped", None);
        }
        if start.elapsed() >= timeout {
            break (false, "timeout", None);
        }
        thread::sleep(Duration::from_millis(100));
    };
    drop(process);
    let report = RunReport {
        schema_version: 1,
        name: plan.name.clone(),
        success,
        stop_reason: stop_reason.to_owned(),
        exit_code,
        marker_seen,
        elapsed_ms: start.elapsed().as_millis(),
        stdout_log,
        stderr_log,
        gpu_assignment: false,
    };
    fs::write(
        directory.join("result.json"),
        serde_json::to_vec_pretty(&report)?,
    )?;
    Ok(report)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> LaunchPlan {
        LaunchPlan {
            schema_version: 1,
            name: "runner-fixture".into(),
            executable: std::env::current_exe().unwrap(),
            arguments: vec!["--list".into()],
            inputs: vec![],
            ready: true,
            serial_marker: Some("runner::tests::records_a_verified_exit".into()),
            gpu_assignment: false,
        }
    }

    #[test]
    fn records_a_verified_exit() {
        let logs = tempfile::tempdir().unwrap();
        let report = execute(&fixture(), Mode::Smoke, Duration::from_secs(5), logs.path()).unwrap();
        assert!(
            report.success,
            "{report:?}\nstdout: {}\nstderr: {}",
            String::from_utf8_lossy(&fs::read(&report.stdout_log).unwrap()),
            String::from_utf8_lossy(&fs::read(&report.stderr_log).unwrap())
        );
        assert_eq!(report.exit_code, Some(0));
        assert!(report.stderr_log.is_file());
    }

    #[test]
    fn successful_exit_without_marker_is_not_boot_success() {
        let logs = tempfile::tempdir().unwrap();
        let mut plan = fixture();
        plan.serial_marker = Some("marker-that-is-not-printed".into());
        let report = execute(&plan, Mode::Smoke, Duration::from_secs(5), logs.path()).unwrap();
        assert!(!report.success);
        assert!(!report.marker_seen);
    }

    #[test]
    fn timeout_is_failure_and_process_is_reaped() {
        let logs = tempfile::tempdir().unwrap();
        let mut plan = fixture();
        plan.arguments = vec![
            "--ignored".into(),
            "--exact".into(),
            "runner::tests::sleep_fixture".into(),
        ];
        let report = execute(&plan, Mode::Run, Duration::from_millis(200), logs.path()).unwrap();
        assert!(!report.success);
        assert_eq!(
            report.stop_reason,
            "timeout",
            "{report:?}\nstderr: {}",
            String::from_utf8_lossy(&fs::read(&report.stderr_log).unwrap())
        );
        assert!(report.elapsed_ms < 5000);
    }

    #[test]
    fn refuses_smoke_without_a_marker() {
        let logs = tempfile::tempdir().unwrap();
        let mut plan = fixture();
        plan.serial_marker = None;
        assert!(execute(&plan, Mode::Smoke, Duration::from_secs(1), logs.path()).is_err());
    }

    #[test]
    #[ignore = "spawned only by the runner timeout test"]
    fn sleep_fixture() {
        thread::sleep(Duration::from_secs(10));
    }

    #[test]
    fn log_reads_are_bounded_even_when_files_grow() {
        let dir = tempfile::tempdir().unwrap();
        let out = dir.path().join("out");
        let err = dir.path().join("err");
        File::create(&out)
            .unwrap()
            .set_len(MAX_LOG_BYTES + 1)
            .unwrap();
        File::create(&err).unwrap();
        assert!(transcript(&out, &err).unwrap().is_none());
    }

    #[test]
    fn kernel_panic_is_failure_even_with_a_zero_exit_code() {
        let logs = tempfile::tempdir().unwrap();
        let mut plan = fixture();
        plan.arguments = vec![
            "--ignored".into(),
            "--exact".into(),
            "runner::tests::panic_fixture".into(),
            "--nocapture".into(),
        ];
        plan.serial_marker = None;
        let report = execute(&plan, Mode::Run, Duration::from_secs(5), logs.path()).unwrap();
        assert!(!report.success);
        assert_eq!(report.stop_reason, "guest_kernel_panic");
    }

    #[test]
    #[ignore = "spawned only by the runner panic-detection test"]
    fn panic_fixture() {
        println!("Kernel panic - not syncing");
    }

    #[test]
    fn controller_stop_reaps_only_the_owned_runtime() {
        let logs = tempfile::tempdir().unwrap();
        let mut plan = fixture();
        plan.arguments = vec![
            "--ignored".into(),
            "--exact".into(),
            "runner::tests::sleep_fixture".into(),
        ];
        let observed_pid = std::cell::Cell::new(0_u32);
        let notify = |event| {
            if let RunEvent::Started(pid) = event {
                observed_pid.set(pid);
            }
            Ok(())
        };
        let stop_requested = || Ok(true);
        let control = RunControl {
            notify: &notify,
            stop_requested: &stop_requested,
        };
        let report = execute_controlled(
            &plan,
            Mode::Run,
            Duration::from_secs(5),
            logs.path(),
            Some(&control),
        )
        .unwrap();
        assert!(observed_pid.get() > 0);
        assert!(report.success);
        assert_eq!(report.stop_reason, "stop_requested");
        assert!(report.elapsed_ms < 5000);
    }

    #[test]
    fn notification_failure_still_reaps_the_runtime() {
        let logs = tempfile::tempdir().unwrap();
        let mut plan = fixture();
        plan.arguments = vec![
            "--ignored".into(),
            "--exact".into(),
            "runner::tests::sleep_fixture".into(),
        ];
        let notify = |_| anyhow::bail!("state write failed");
        let stop_requested = || Ok(false);
        let control = RunControl {
            notify: &notify,
            stop_requested: &stop_requested,
        };
        let start = Instant::now();
        let result = execute_controlled(
            &plan,
            Mode::Run,
            Duration::from_secs(5),
            logs.path(),
            Some(&control),
        );
        assert!(result.is_err());
        assert!(start.elapsed() < Duration::from_secs(5));
    }
}
