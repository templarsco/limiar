use crate::config::{Boot, LaunchPlan, VmConfig, validate_name};
use crate::runner::{self, Mode, RunControl, RunEvent, RunReport};
use anyhow::{Context, Result, bail, ensure};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use std::fs::{self, File, OpenOptions, TryLockError};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const MAX_RECORD_BYTES: u64 = 128 * 1024;
const MANAGED_FILES: &[&str] = &["profile.json", "state.json", "run.lock", "stop.json"];
static RUN_SEQUENCE: AtomicU64 = AtomicU64::new(0);

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct VmRecord {
    pub schema_version: u32,
    pub name: String,
    pub revision: u64,
    pub created_at_unix_ms: u64,
    pub updated_at_unix_ms: u64,
    pub profile: VmConfig,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum VmState {
    Registered,
    Starting,
    Running,
    Stopping,
    Stopped,
    Failed,
    Interrupted,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RunState {
    pub schema_version: u32,
    pub run_id: String,
    pub profile_revision: u64,
    pub state: VmState,
    pub runtime_pid: Option<u32>,
    pub boot_verified: bool,
    pub started_at_unix_ms: u64,
    pub finished_at_unix_ms: Option<u64>,
    pub result: Option<RunReport>,
    pub error: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct VmStatus {
    pub schema_version: u32,
    pub name: String,
    pub profile_revision: u64,
    pub state: VmState,
    pub supervisor_active: bool,
    pub last_run: Option<RunState>,
}

#[derive(Debug, Serialize)]
pub struct Inventory {
    pub schema_version: u32,
    pub vms: Vec<VmStatus>,
    pub errors: Vec<InventoryError>,
}

#[derive(Debug, Serialize)]
pub struct InventoryError {
    pub name: String,
    pub error: String,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct StopRequest {
    schema_version: u32,
    run_id: String,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct RegistryMetadata {
    schema_version: u32,
    host_os: String,
}

#[derive(Debug, Clone)]
pub struct Registry {
    root: PathBuf,
}

fn now_ms() -> Result<u64> {
    Ok(SystemTime::now()
        .duration_since(UNIX_EPOCH)?
        .as_millis()
        .try_into()?)
}

fn read_json<T: DeserializeOwned>(path: &Path) -> Result<T> {
    let mut bytes = Vec::new();
    File::open(path)
        .with_context(|| format!("cannot read {}", path.display()))?
        .take(MAX_RECORD_BYTES + 1)
        .read_to_end(&mut bytes)?;
    ensure!(
        bytes.len() as u64 <= MAX_RECORD_BYTES,
        "registry record exceeds 128 KiB"
    );
    serde_json::from_slice(&bytes)
        .with_context(|| format!("invalid registry record {}", path.display()))
}

fn write_json(path: &Path, value: &impl Serialize) -> Result<()> {
    let bytes = serde_json::to_vec_pretty(value)?;
    ensure!(
        bytes.len() as u64 <= MAX_RECORD_BYTES,
        "registry record exceeds 128 KiB"
    );
    let mut temp =
        tempfile::NamedTempFile::new_in(path.parent().context("missing record directory")?)?;
    temp.write_all(&bytes)?;
    temp.as_file().sync_all()?;
    temp.persist(path).map_err(|error| error.error)?;
    Ok(())
}

fn lock_file(path: &Path) -> Result<File> {
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(path)?;
    ensure!(
        file.metadata()?.is_file(),
        "lock path must be a regular file"
    );
    Ok(file)
}

fn try_lease(path: &Path) -> Result<Option<File>> {
    let file = lock_file(path)?;
    match file.try_lock() {
        Ok(()) => Ok(Some(file)),
        Err(TryLockError::WouldBlock) => Ok(None),
        Err(TryLockError::Error(error)) => Err(error.into()),
    }
}

fn validate_record(record: &VmRecord, name: &str) -> Result<()> {
    ensure!(record.schema_version == 1, "unsupported registry schema");
    ensure!(record.revision > 0, "invalid profile revision");
    record.profile.validate()?;
    if let Some(identity) = &record.profile.identity {
        ensure!(
            identity.system.uuid.is_some() && identity.system.serial.is_some(),
            "stored identity is missing its persistent UUID or serial"
        );
    }
    ensure!(
        record.name == record.profile.name && record.name.eq_ignore_ascii_case(name),
        "registry name does not match the stored profile"
    );
    ensure!(
        record.profile.runtime.executable.is_absolute(),
        "stored runtime path must be absolute"
    );
    match &record.profile.boot {
        Boot::LinuxDirect { kernel, initrd, .. } => {
            ensure!(
                kernel.is_absolute() && initrd.is_absolute(),
                "stored boot paths must be absolute"
            );
        }
        Boot::Uefi { firmware, disk, .. } => {
            ensure!(
                firmware.is_absolute() && disk.is_absolute(),
                "stored boot paths must be absolute"
            );
        }
        Boot::QemuUefi {
            firmware,
            variables,
            disk,
            cdrom,
            ..
        } => {
            ensure!(
                firmware.is_absolute()
                    && variables.is_absolute()
                    && disk.is_absolute()
                    && cdrom.as_ref().is_none_or(|path| path.is_absolute()),
                "stored QEMU boot paths must be absolute"
            );
        }
    }
    Ok(())
}

impl Registry {
    pub fn open(root: &Path) -> Result<Self> {
        fs::create_dir_all(root)?;
        let registry = Self {
            root: root.canonicalize()?,
        };
        let metadata_path = registry.root.join(".registry.json");
        let _guard = registry.guard()?;
        if !metadata_path.exists() {
            let metadata = RegistryMetadata {
                schema_version: 1,
                host_os: std::env::consts::OS.to_owned(),
            };
            let mut temp = tempfile::NamedTempFile::new_in(&registry.root)?;
            temp.write_all(&serde_json::to_vec_pretty(&metadata)?)?;
            temp.as_file().sync_all()?;
            match temp.persist_noclobber(&metadata_path) {
                Ok(_) => {}
                Err(error) if error.error.kind() == std::io::ErrorKind::AlreadyExists => {}
                Err(error) => return Err(error.error.into()),
            }
        }
        let metadata: RegistryMetadata = read_json(&metadata_path)?;
        ensure!(
            metadata.schema_version == 1,
            "unsupported registry metadata schema"
        );
        ensure!(
            metadata.host_os == std::env::consts::OS,
            "registry belongs to {}; use a separate registry for {}",
            metadata.host_os,
            std::env::consts::OS
        );
        drop(_guard);
        Ok(registry)
    }

    fn guard(&self) -> Result<File> {
        let file = lock_file(&self.root.join(".registry.lock"))?;
        let start = Instant::now();
        loop {
            match file.try_lock() {
                Ok(()) => return Ok(file),
                Err(TryLockError::WouldBlock) if start.elapsed() < Duration::from_secs(5) => {
                    thread::sleep(Duration::from_millis(10));
                }
                Err(TryLockError::WouldBlock) => bail!("registry is busy; try again"),
                Err(TryLockError::Error(error)) => return Err(error.into()),
            }
        }
    }

    fn path(&self, name: &str) -> Result<PathBuf> {
        validate_name(name)?;
        Ok(self.root.join(name.to_ascii_lowercase()))
    }

    fn existing_path(&self, name: &str) -> Result<PathBuf> {
        let path = self.path(name)?;
        let metadata = fs::symlink_metadata(&path)
            .with_context(|| format!("VM {name:?} is not registered"))?;
        ensure!(
            metadata.is_dir() && !metadata.file_type().is_symlink(),
            "VM directory cannot be a link"
        );
        let canonical = path.canonicalize()?;
        ensure!(
            canonical.parent() == Some(self.root.as_path()),
            "VM directory escapes the registry"
        );
        Ok(canonical)
    }

    fn record_at(&self, path: &Path, name: &str) -> Result<VmRecord> {
        let record: VmRecord = read_json(&path.join("profile.json"))?;
        validate_record(&record, name)?;
        Ok(record)
    }

    fn run_at(&self, path: &Path) -> Result<Option<RunState>> {
        let path = path.join("state.json");
        if !path.exists() {
            return Ok(None);
        }
        let run: RunState = read_json(&path)?;
        ensure!(
            run.schema_version == 1 && !run.run_id.is_empty(),
            "invalid run state"
        );
        Ok(Some(run))
    }

    fn stop_matches(&self, path: &Path, run_id: &str) -> Result<bool> {
        let path = path.join("stop.json");
        if !path.exists() {
            return Ok(false);
        }
        let request: StopRequest = read_json(&path)?;
        ensure!(
            request.schema_version == 1,
            "unsupported stop request schema"
        );
        Ok(request.run_id == run_id)
    }

    pub fn register(&self, profile_path: &Path) -> Result<VmRecord> {
        let (profile, base) = VmConfig::load(profile_path)?;
        let mut profile = profile.resolved(&base)?;
        profile.materialize_identity(None)?;
        let timestamp = now_ms()?;
        let record = VmRecord {
            schema_version: 1,
            name: profile.name.clone(),
            revision: 1,
            created_at_unix_ms: timestamp,
            updated_at_unix_ms: timestamp,
            profile,
        };
        let _guard = self.guard()?;
        let directory = self.path(&record.name)?;
        fs::create_dir(&directory).with_context(|| {
            format!(
                "VM {:?} is already registered or its directory is unavailable",
                record.name
            )
        })?;
        if let Err(error) = write_json(&directory.join("profile.json"), &record) {
            let _ = fs::remove_dir(&directory);
            return Err(error);
        }
        Ok(record)
    }

    pub fn update(&self, name: &str, profile_path: &Path) -> Result<VmRecord> {
        let (profile, base) = VmConfig::load(profile_path)?;
        let mut profile = profile.resolved(&base)?;
        ensure!(
            profile.name.eq_ignore_ascii_case(name),
            "updated profile must keep the VM name"
        );
        let _guard = self.guard()?;
        let directory = self.existing_path(name)?;
        let _lease = try_lease(&directory.join("run.lock"))?
            .context("VM is running; stop it before updating")?;
        let old = self.record_at(&directory, name)?;
        profile.materialize_identity(Some(&old.profile))?;
        let record = VmRecord {
            schema_version: 1,
            name: profile.name.clone(),
            revision: old
                .revision
                .checked_add(1)
                .context("profile revision overflow")?,
            created_at_unix_ms: old.created_at_unix_ms,
            updated_at_unix_ms: now_ms()?,
            profile,
        };
        write_json(&directory.join("profile.json"), &record)?;
        Ok(record)
    }

    pub fn show(&self, name: &str) -> Result<VmRecord> {
        let _guard = self.guard()?;
        self.record_at(&self.existing_path(name)?, name)
    }

    pub fn preview(&self, name: &str) -> Result<LaunchPlan> {
        // Probe external input paths only after releasing the registry lock.
        self.show(name)?.profile.plan(&self.root)
    }

    fn status_unlocked(&self, name: &str) -> Result<VmStatus> {
        let directory = self.existing_path(name)?;
        let record = self.record_at(&directory, name)?;
        let active = try_lease(&directory.join("run.lock"))?.is_none();
        let mut run = self.run_at(&directory)?;
        let state = match run.as_mut() {
            None if active => VmState::Starting,
            None => VmState::Registered,
            Some(run) if active => {
                if self.stop_matches(&directory, &run.run_id)?
                    || matches!(run.state, VmState::Stopped | VmState::Failed)
                {
                    VmState::Stopping
                } else {
                    run.state
                }
            }
            Some(run) => {
                if matches!(
                    run.state,
                    VmState::Starting | VmState::Running | VmState::Stopping
                ) {
                    run.state = VmState::Interrupted;
                    run.error = Some("supervisor lock is no longer held".into());
                }
                run.state
            }
        };
        Ok(VmStatus {
            schema_version: 1,
            name: record.name,
            profile_revision: record.revision,
            state,
            supervisor_active: active,
            last_run: run,
        })
    }

    pub fn status(&self, name: &str) -> Result<VmStatus> {
        let _guard = self.guard()?;
        self.status_unlocked(name)
    }

    pub fn list(&self) -> Result<Inventory> {
        let _guard = self.guard()?;
        let mut inventory = Inventory {
            schema_version: 1,
            vms: vec![],
            errors: vec![],
        };
        for entry in fs::read_dir(&self.root)? {
            let entry = entry?;
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.starts_with('.') || entry.file_type()?.is_file() {
                continue;
            }
            match self.status_unlocked(&name) {
                Ok(status) => inventory.vms.push(status),
                Err(error) => inventory.errors.push(InventoryError {
                    name,
                    error: format!("{error:#}"),
                }),
            }
        }
        inventory.vms.sort_by_key(|vm| vm.name.to_ascii_lowercase());
        inventory.errors.sort_by(|a, b| a.name.cmp(&b.name));
        Ok(inventory)
    }

    pub fn unregister(&self, name: &str) -> Result<()> {
        let _guard = self.guard()?;
        let directory = self.existing_path(name)?;
        let lease = try_lease(&directory.join("run.lock"))?
            .context("VM is running; stop it before unregistering")?;
        for entry in fs::read_dir(&directory)? {
            let entry = entry?;
            let file_name = entry.file_name();
            ensure!(
                file_name
                    .to_str()
                    .is_some_and(|name| MANAGED_FILES.contains(&name))
                    && entry.file_type()?.is_file(),
                "VM directory contains unmanaged files; refusing to remove them"
            );
        }
        drop(lease);
        for name in MANAGED_FILES {
            let path = directory.join(name);
            if path.exists() {
                fs::remove_file(path)?;
            }
        }
        fs::remove_dir(directory)?;
        Ok(())
    }

    pub fn request_stop(&self, name: &str, force: bool) -> Result<VmStatus> {
        ensure!(
            force,
            "stop terminates the runtime, not a graceful guest shutdown; pass --force"
        );
        let _guard = self.guard()?;
        let directory = self.existing_path(name)?;
        let status = self.status_unlocked(name)?;
        if status.supervisor_active {
            let run = status
                .last_run
                .as_ref()
                .context("supervisor is still initializing; retry stop")?;
            write_json(
                &directory.join("stop.json"),
                &StopRequest {
                    schema_version: 1,
                    run_id: run.run_id.clone(),
                },
            )?;
        }
        self.status_unlocked(name)
    }

    pub fn stop(&self, name: &str, force: bool, wait: Duration) -> Result<VmStatus> {
        let initial = self.request_stop(name, force)?;
        if !initial.supervisor_active {
            return Ok(initial);
        }
        let start = Instant::now();
        loop {
            let status = self.status(name)?;
            if !status.supervisor_active {
                return Ok(status);
            }
            ensure!(
                start.elapsed() < wait,
                "stop requested but supervisor has not finished yet"
            );
            thread::sleep(Duration::from_millis(50));
        }
    }

    pub fn start(
        &self,
        name: &str,
        mode: Mode,
        timeout: Duration,
        logs: &Path,
    ) -> Result<RunReport> {
        self.start_using(
            name,
            mode,
            timeout,
            logs,
            |plan, mode, timeout, logs, control| {
                runner::execute_controlled(plan, mode, timeout, logs, Some(control))
            },
        )
    }

    fn update_run(
        &self,
        directory: &Path,
        run_id: &str,
        edit: impl FnOnce(&mut RunState),
    ) -> Result<()> {
        let _guard = self.guard()?;
        let mut state = self.run_at(directory)?.context("run state is missing")?;
        ensure!(state.run_id == run_id, "run state changed unexpectedly");
        edit(&mut state);
        write_json(&directory.join("state.json"), &state)
    }

    fn start_using<F>(
        &self,
        name: &str,
        mode: Mode,
        timeout: Duration,
        logs: &Path,
        execute: F,
    ) -> Result<RunReport>
    where
        F: FnOnce(&LaunchPlan, Mode, Duration, &Path, &RunControl<'_>) -> Result<RunReport>,
    {
        let (record, directory, lease, run_id) = {
            let _guard = self.guard()?;
            let directory = self.existing_path(name)?;
            let record = self.record_at(&directory, name)?;
            let lease = try_lease(&directory.join("run.lock"))?
                .context("VM already has an active supervisor")?;
            let stamp = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
            let sequence = RUN_SEQUENCE.fetch_add(1, Ordering::Relaxed);
            let run_id = format!("{stamp:x}-{}-{sequence:x}", std::process::id());
            write_json(
                &directory.join("state.json"),
                &RunState {
                    schema_version: 1,
                    run_id: run_id.clone(),
                    profile_revision: record.revision,
                    state: VmState::Starting,
                    runtime_pid: None,
                    boot_verified: false,
                    started_at_unix_ms: now_ms()?,
                    finished_at_unix_ms: None,
                    result: None,
                    error: None,
                },
            )?;
            (record, directory, lease, run_id)
        };

        // The long-lived VM lease never blocks while holding the registry guard.
        // Other operations only try the lease, preventing lock-order deadlocks.
        let notify = |event| {
            self.update_run(&directory, &run_id, |state| match event {
                RunEvent::Started(pid) => {
                    state.state = VmState::Running;
                    state.runtime_pid = Some(pid);
                }
                RunEvent::MarkerSeen => state.boot_verified = true,
            })
        };
        let stop_requested = || self.stop_matches(&directory, &run_id);
        let control = RunControl {
            notify: &notify,
            stop_requested: &stop_requested,
        };
        let outcome = (|| {
            let plan = record.profile.plan(&self.root)?;
            ensure!(plan.ready, "one or more required input files are missing");
            execute(&plan, mode, timeout, logs, &control)
        })();
        let finished_at = now_ms()?;
        let save = self.update_run(&directory, &run_id, |state| {
            state.finished_at_unix_ms = Some(finished_at);
            match &outcome {
                Ok(report) => {
                    state.state = if report.success {
                        VmState::Stopped
                    } else {
                        VmState::Failed
                    };
                    state.boot_verified = report.marker_seen;
                    state.result = Some(report.clone());
                }
                Err(error) => {
                    state.state = VmState::Failed;
                    state.error = Some(format!("{error:#}"));
                }
            }
        });
        drop(lease);
        save.context("runtime ended but its final state could not be persisted")?;
        outcome
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::sync::mpsc;

    fn profile(directory: &Path, name: &str) -> PathBuf {
        for file in ["runtime", "kernel", "initrd"] {
            fs::write(directory.join(file), b"fixture").unwrap();
        }
        let text = toml::to_string(&json!({
            "schema_version": 1, "name": name, "cpus": 2, "memory_mib": 512,
            "runtime": {"executable": "runtime"},
            "boot": {"kind": "linux_direct", "kernel": "kernel", "initrd": "initrd"},
            "verification": {"serial_marker": "ready"}
        }))
        .unwrap();
        let path = directory.join(format!("{name}.toml"));
        fs::write(&path, text).unwrap();
        path
    }

    fn fake_report(plan: &LaunchPlan) -> RunReport {
        RunReport {
            schema_version: 1,
            name: plan.name.clone(),
            success: true,
            stop_reason: "stop_requested".into(),
            exit_code: None,
            marker_seen: true,
            elapsed_ms: 1,
            stdout_log: PathBuf::from("out"),
            stderr_log: PathBuf::from("err"),
            gpu_assignment: false,
            expected_dmi: plan
                .identity
                .as_ref()
                .map(|identity| identity.expected_dmi.clone()),
        }
    }

    #[test]
    fn registration_is_a_resolved_snapshot_and_names_are_case_insensitive() {
        let dir = tempfile::tempdir().unwrap();
        let registry = Registry::open(&dir.path().join("registry")).unwrap();
        let path = profile(dir.path(), "Guest");
        let record = registry.register(&path).unwrap();
        assert!(record.profile.runtime.executable.is_absolute());
        fs::remove_file(path).unwrap();
        assert!(registry.preview("GUEST").unwrap().ready);
        assert_eq!(registry.status("guest").unwrap().state, VmState::Registered);
        assert!(registry.register(&profile(dir.path(), "guest")).is_err());
    }

    #[test]
    fn unregister_never_removes_guest_inputs_or_unknown_files() {
        let dir = tempfile::tempdir().unwrap();
        let registry = Registry::open(&dir.path().join("registry")).unwrap();
        registry.register(&profile(dir.path(), "guest")).unwrap();
        let extra = registry.path("guest").unwrap().join("disk.vhdx");
        fs::write(&extra, b"keep").unwrap();
        assert!(registry.unregister("guest").is_err());
        assert_eq!(fs::read(&extra).unwrap(), b"keep");
        fs::remove_file(extra).unwrap();
        registry.unregister("guest").unwrap();
        assert!(dir.path().join("kernel").exists());
        assert!(registry.list().unwrap().vms.is_empty());
    }

    #[test]
    fn rejects_unsafe_names_and_reports_corrupt_entries_without_hiding_good_ones() {
        let dir = tempfile::tempdir().unwrap();
        let registry = Registry::open(&dir.path().join("registry")).unwrap();
        registry.register(&profile(dir.path(), "guest")).unwrap();
        for name in ["../escape", "CON", "nul.txt", "guest.", "."] {
            assert!(registry.status(name).is_err());
        }
        fs::create_dir(registry.root.join("broken")).unwrap();
        let inventory = registry.list().unwrap();
        assert_eq!(inventory.vms.len(), 1);
        assert_eq!(inventory.errors.len(), 1);
        registry.unregister("broken").unwrap();
    }

    #[test]
    fn running_vm_rejects_duplicate_start_update_and_unregister_and_can_be_stopped() {
        let dir = tempfile::tempdir().unwrap();
        let registry = Registry::open(&dir.path().join("registry")).unwrap();
        let path = profile(dir.path(), "guest");
        registry.register(&path).unwrap();
        let worker = registry.clone();
        let logs = dir.path().join("logs");
        let (tx, rx) = mpsc::channel();
        let thread = thread::spawn(move || {
            worker.start_using(
                "guest",
                Mode::Run,
                Duration::from_secs(5),
                &logs,
                |plan, _, _, _, control| {
                    (control.notify)(RunEvent::Started(123))?;
                    (control.notify)(RunEvent::MarkerSeen)?;
                    tx.send(()).unwrap();
                    let start = Instant::now();
                    while !(control.stop_requested)()? {
                        ensure!(
                            start.elapsed() < Duration::from_secs(5),
                            "test stop timed out"
                        );
                        thread::sleep(Duration::from_millis(10));
                    }
                    Ok(fake_report(plan))
                },
            )
        });
        rx.recv_timeout(Duration::from_secs(5)).unwrap();
        assert_eq!(registry.status("guest").unwrap().state, VmState::Running);
        assert!(
            registry
                .start("guest", Mode::Run, Duration::from_secs(1), dir.path())
                .is_err()
        );
        assert!(registry.update("guest", &path).is_err());
        assert!(registry.unregister("guest").is_err());
        assert!(
            registry
                .stop("guest", false, Duration::from_secs(1))
                .is_err()
        );
        let stopped = registry
            .stop("guest", true, Duration::from_secs(5))
            .unwrap();
        assert!(!stopped.supervisor_active);
        assert_eq!(stopped.state, VmState::Stopped);
        assert!(thread.join().unwrap().unwrap().success);
    }

    #[test]
    fn stale_stop_requests_do_not_stop_a_new_run_and_updates_increment_revision() {
        let dir = tempfile::tempdir().unwrap();
        let registry = Registry::open(&dir.path().join("registry")).unwrap();
        let path = profile(dir.path(), "guest");
        registry.register(&path).unwrap();
        let record = registry.update("guest", &path).unwrap();
        assert_eq!(record.revision, 2);
        write_json(
            &registry.path("guest").unwrap().join("stop.json"),
            &StopRequest {
                schema_version: 1,
                run_id: "old-run".into(),
            },
        )
        .unwrap();
        registry
            .start_using(
                "guest",
                Mode::Run,
                Duration::from_secs(1),
                dir.path(),
                |plan, _, _, _, control| {
                    assert!(!(control.stop_requested)()?);
                    Ok(fake_report(plan))
                },
            )
            .unwrap();
        assert_eq!(
            registry
                .status("guest")
                .unwrap()
                .last_run
                .unwrap()
                .profile_revision,
            2
        );
    }

    #[test]
    fn an_unowned_running_record_is_interrupted_and_does_not_kill_its_pid() {
        let dir = tempfile::tempdir().unwrap();
        let registry = Registry::open(&dir.path().join("registry")).unwrap();
        registry.register(&profile(dir.path(), "guest")).unwrap();
        write_json(
            &registry.path("guest").unwrap().join("state.json"),
            &RunState {
                schema_version: 1,
                run_id: "dead-supervisor".into(),
                profile_revision: 1,
                state: VmState::Running,
                runtime_pid: Some(std::process::id()),
                boot_verified: false,
                started_at_unix_ms: now_ms().unwrap(),
                finished_at_unix_ms: None,
                result: None,
                error: None,
            },
        )
        .unwrap();
        let status = registry
            .stop("guest", true, Duration::from_secs(1))
            .unwrap();
        assert_eq!(status.state, VmState::Interrupted);
        assert!(!status.supervisor_active);
    }

    #[test]
    fn failed_execution_is_persisted_and_releases_the_lease() {
        let dir = tempfile::tempdir().unwrap();
        let registry = Registry::open(&dir.path().join("registry")).unwrap();
        registry.register(&profile(dir.path(), "guest")).unwrap();
        let result = registry.start_using(
            "guest",
            Mode::Run,
            Duration::from_secs(1),
            dir.path(),
            |_, _, _, _, _| bail!("fixture runtime failed"),
        );
        assert!(result.is_err());
        let status = registry.status("guest").unwrap();
        assert_eq!(status.state, VmState::Failed);
        assert!(!status.supervisor_active);
        registry.unregister("guest").unwrap();
    }

    #[test]
    fn refuses_a_registry_marked_for_another_os() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("registry");
        Registry::open(&root).unwrap();
        write_json(
            &root.join(".registry.json"),
            &RegistryMetadata {
                schema_version: 1,
                host_os: "different-os".into(),
            },
        )
        .unwrap();
        assert!(Registry::open(&root).is_err());
    }

    #[cfg(unix)]
    #[test]
    fn refuses_linked_vm_directories() {
        let dir = tempfile::tempdir().unwrap();
        let registry = Registry::open(&dir.path().join("registry")).unwrap();
        let outside = dir.path().join("outside");
        fs::create_dir(&outside).unwrap();
        fs::write(outside.join("keep"), b"safe").unwrap();
        std::os::unix::fs::symlink(&outside, registry.root.join("guest")).unwrap();
        assert!(registry.status("guest").is_err());
        assert!(registry.unregister("guest").is_err());
        assert_eq!(fs::read(outside.join("keep")).unwrap(), b"safe");
    }
}
