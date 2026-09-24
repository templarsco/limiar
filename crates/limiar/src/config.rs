use crate::identity::{Identity, IdentityPlan};
use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct VmConfig {
    pub schema_version: u32,
    pub name: String,
    pub cpus: u16,
    pub memory_mib: u32,
    pub runtime: Runtime,
    pub boot: Boot,
    pub identity: Option<Identity>,
    #[serde(default)]
    pub verification: Verification,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Runtime {
    pub executable: PathBuf,
}

#[derive(Debug, Clone, Copy, Default, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum QemuCpuModel {
    #[default]
    Host,
    Compatible,
    Max,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum Boot {
    LinuxDirect {
        kernel: PathBuf,
        initrd: PathBuf,
        #[serde(default)]
        cmdline: String,
    },
    Uefi {
        firmware: PathBuf,
        disk: PathBuf,
        #[serde(default = "default_read_only")]
        read_only_base: bool,
    },
    QemuUefi {
        firmware: PathBuf,
        variables: PathBuf,
        disk: PathBuf,
        #[serde(default)]
        cpu_model: QemuCpuModel,
        cdrom: Option<PathBuf>,
        #[serde(default = "default_read_only")]
        read_only_base: bool,
        #[serde(default)]
        headless: bool,
        qmp_port: Option<u16>,
    },
}

fn default_read_only() -> bool {
    true
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Verification {
    pub serial_marker: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct Input {
    pub role: &'static str,
    pub path: PathBuf,
    pub exists: bool,
}

#[derive(Debug, Serialize)]
pub struct LaunchPlan {
    pub schema_version: u32,
    pub name: String,
    pub executable: PathBuf,
    pub arguments: Vec<String>,
    pub inputs: Vec<Input>,
    pub ready: bool,
    pub serial_marker: Option<String>,
    pub gpu_assignment: bool,
    pub identity: Option<IdentityPlan>,
}

impl VmConfig {
    pub fn parse(text: &str) -> Result<Self> {
        ensure!(text.len() <= 65_536, "profile exceeds 64 KiB");
        let config: Self = toml::from_str(text).context("invalid VM profile")?;
        config.validate()?;
        Ok(config)
    }

    pub fn parse_json(text: &str) -> Result<Self> {
        ensure!(text.len() <= 65_536, "profile exceeds 64 KiB");
        let config: Self = serde_json::from_str(text).context("invalid JSON VM profile")?;
        config.validate()?;
        Ok(config)
    }

    pub fn validate(&self) -> Result<()> {
        ensure!(self.schema_version == 1, "unsupported schema_version");
        ensure!((1..=64).contains(&self.cpus), "cpus must be 1..64");
        ensure!(
            (128..=262_144).contains(&self.memory_mib),
            "memory_mib must be 128..262144"
        );
        validate_name(&self.name)?;
        if let Some(identity) = &self.identity {
            if matches!(self.boot, Boot::QemuUefi { .. }) {
                identity.validate_qemu()?;
            } else {
                identity.validate(matches!(self.boot, Boot::LinuxDirect { .. }))?;
            }
        }
        if let Boot::QemuUefi {
            qmp_port: Some(port),
            ..
        } = self.boot
        {
            ensure!(port >= 1024, "QMP port must be 1024..65535");
        }
        if let Some(marker) = &self.verification.serial_marker {
            ensure!(
                !marker.trim().is_empty() && marker.len() <= 512 && !marker.contains('\0'),
                "serial_marker must contain 1..512 non-NUL bytes"
            );
        }
        Ok(())
    }

    pub fn load(path: &Path) -> Result<(Self, PathBuf)> {
        let path = path.canonicalize().context("profile not found")?;
        ensure!(
            fs::metadata(&path)?.len() <= 65_536,
            "profile exceeds 64 KiB"
        );
        let mut text = String::new();
        fs::File::open(&path)?
            .take(65_537)
            .read_to_string(&mut text)?;
        let json = path
            .extension()
            .and_then(|extension| extension.to_str())
            .is_some_and(|extension| extension.eq_ignore_ascii_case("json"));
        let config = if json {
            Self::parse_json(&text)?
        } else {
            Self::parse(&text)?
        };
        let base = path.parent().context("profile has no parent directory")?;
        Ok((config, base.to_owned()))
    }

    pub fn plan(&self, base: &Path) -> Result<LaunchPlan> {
        self.validate()?;
        let mut inputs = Vec::new();
        let executable = input_path(base, &self.runtime.executable, "runtime", &mut inputs)?;
        let mut arguments = vec![
            "--hypervisor".into(),
            "whp".into(),
            "-p".into(),
            self.cpus.to_string(),
            "-m".into(),
            format!("{}MB", self.memory_mib),
            "--com1".into(),
            "stderr".into(),
            "--guest-shutdown-action".into(),
            "exit".into(),
            "--guest-crash-action".into(),
            "exit:2".into(),
            "--guest-reset-action".into(),
            "exit:3".into(),
        ];
        match &self.boot {
            Boot::LinuxDirect {
                kernel,
                initrd,
                cmdline,
            } => {
                ensure!(
                    cmdline.len() <= 4096 && !cmdline.contains(['\0', '\n', '\r']),
                    "cmdline must be a single line of at most 4096 bytes"
                );
                let kernel = input_path(base, kernel, "kernel", &mut inputs)?;
                let initrd = input_path(base, initrd, "initrd", &mut inputs)?;
                arguments.extend([
                    "--kernel".into(),
                    path_arg(&kernel)?,
                    "--initrd".into(),
                    path_arg(&initrd)?,
                    "--cmdline".into(),
                    cmdline.clone(),
                ]);
            }
            Boot::Uefi {
                firmware,
                disk,
                read_only_base,
            } => {
                let firmware = input_path(base, firmware, "firmware", &mut inputs)?;
                let disk = input_path(base, disk, "disk", &mut inputs)?;
                let firmware = structured_path_arg(&firmware)?;
                let disk = structured_path_arg(&disk)?;
                let mode = if *read_only_base { "memdiff" } else { "file" };
                arguments.extend([
                    "--uefi".into(),
                    format!("firmware={firmware}"),
                    "--vmbus-scsi".into(),
                    "id=scsi0".into(),
                    "--disk".into(),
                    format!("{mode}:{disk},on=scsi0"),
                ]);
            }
            Boot::QemuUefi {
                firmware,
                variables,
                disk,
                cpu_model,
                cdrom,
                read_only_base,
                headless,
                qmp_port,
            } => {
                let firmware = input_path(base, firmware, "firmware", &mut inputs)?;
                let variables = input_path(base, variables, "variables", &mut inputs)?;
                let disk = input_path(base, disk, "disk", &mut inputs)?;
                let paths = [&firmware, &variables, &disk]
                    .map(|path| path.canonicalize().unwrap_or_else(|_| path.clone()));
                ensure!(
                    paths[0] != paths[1] && paths[0] != paths[2] && paths[1] != paths[2],
                    "QEMU firmware, writable variables and disk must be different files"
                );
                let firmware = structured_path_arg(&firmware)?;
                let variables = structured_path_arg(&variables)?;
                let disk = structured_path_arg(&disk)?;
                arguments = vec![
                    "-name".into(),
                    self.name.clone(),
                    "-machine".into(),
                    "q35".into(),
                    "-accel".into(),
                    "whpx".into(),
                    "-cpu".into(),
                    match cpu_model {
                        QemuCpuModel::Host => "host",
                        QemuCpuModel::Compatible => {
                            "qemu64,+ssse3,+sse4.1,+sse4.2,+popcnt,+cx16,+lahf_lm,-svm"
                        }
                        QemuCpuModel::Max => "max",
                    }
                    .into(),
                    "-smp".into(),
                    format!("{},sockets=1,cores={},threads=1", self.cpus, self.cpus),
                    "-m".into(),
                    self.memory_mib.to_string(),
                    "-nodefaults".into(),
                    "-drive".into(),
                    format!("if=pflash,format=raw,readonly=on,file={firmware}"),
                    "-drive".into(),
                    format!("if=pflash,format=raw,file={variables}"),
                    "-drive".into(),
                    format!("if=none,id=os,format=qcow2,file={disk}"),
                    "-device".into(),
                    "ide-hd,drive=os,bus=ide.0,bootindex=1".into(),
                    "-device".into(),
                    "VGA,vgamem_mb=32,xres=1280,yres=720".into(),
                    "-device".into(),
                    "qemu-xhci".into(),
                    "-device".into(),
                    "usb-tablet".into(),
                    "-display".into(),
                    if *headless { "none" } else { "sdl,gl=off" }.into(),
                    "-nic".into(),
                    "none".into(),
                    "-serial".into(),
                    "stdio".into(),
                    "-monitor".into(),
                    "none".into(),
                    "-rtc".into(),
                    "base=localtime".into(),
                ];
                if *read_only_base {
                    arguments.push("-snapshot".into());
                }
                if let Some(port) = qmp_port {
                    arguments.extend([
                        "-qmp".into(),
                        format!("tcp:127.0.0.1:{port},server=on,wait=off"),
                    ]);
                }
                if let Some(cdrom) = cdrom {
                    let cdrom = input_path(base, cdrom, "cdrom", &mut inputs)?;
                    let resolved = cdrom.canonicalize().unwrap_or_else(|_| cdrom.clone());
                    ensure!(
                        !paths.contains(&resolved),
                        "CD-ROM must not alias firmware, variables or the VM disk"
                    );
                    arguments.extend([
                        "-drive".into(),
                        format!(
                            "if=none,id=cdrom,media=cdrom,format=raw,readonly=on,file={}",
                            structured_path_arg(&cdrom)?
                        ),
                        "-device".into(),
                        "ide-cd,drive=cdrom,bus=ide.1".into(),
                    ]);
                }
            }
        }
        let identity = self
            .identity
            .as_ref()
            .map(|identity| {
                let (identity, smbios) = if matches!(self.boot, Boot::QemuUefi { .. }) {
                    identity.plan_qemu()?
                } else {
                    identity.plan(matches!(self.boot, Boot::LinuxDirect { .. }))?
                };
                arguments.extend(smbios);
                Ok::<_, anyhow::Error>(identity)
            })
            .transpose()?;
        Ok(LaunchPlan {
            schema_version: 1,
            name: self.name.clone(),
            executable,
            arguments,
            ready: inputs.iter().all(|input| input.exists)
                && !identity
                    .as_ref()
                    .is_some_and(|identity| identity.requires_registration),
            inputs,
            serial_marker: self.verification.serial_marker.clone(),
            gpu_assignment: false,
            identity,
        })
    }

    pub fn materialize_identity(&mut self, previous: Option<&Self>) -> Result<()> {
        if let Some(identity) = &mut self.identity {
            let previous = previous.and_then(|profile| profile.identity.as_ref());
            if matches!(self.boot, Boot::QemuUefi { .. }) {
                identity.materialize_qemu(previous)?;
            } else {
                identity.materialize(previous, matches!(self.boot, Boot::LinuxDirect { .. }))?;
            }
        }
        Ok(())
    }

    pub fn resolved(&self, base: &Path) -> Result<Self> {
        self.validate()?;
        ensure!(base.is_absolute(), "profile base must be absolute");
        let resolve = |path: &Path| {
            if path.is_absolute() {
                path.to_owned()
            } else {
                base.join(path)
            }
        };
        let mut config = self.clone();
        config.runtime.executable = resolve(&config.runtime.executable);
        match &mut config.boot {
            Boot::LinuxDirect { kernel, initrd, .. } => {
                *kernel = resolve(kernel);
                *initrd = resolve(initrd);
            }
            Boot::Uefi { firmware, disk, .. } => {
                *firmware = resolve(firmware);
                *disk = resolve(disk);
            }
            Boot::QemuUefi {
                firmware,
                variables,
                disk,
                cdrom,
                ..
            } => {
                *firmware = resolve(firmware);
                *variables = resolve(variables);
                *disk = resolve(disk);
                if let Some(cdrom) = cdrom {
                    *cdrom = resolve(cdrom);
                }
            }
        }
        config.plan(base)?;
        Ok(config)
    }
}

pub fn validate_name(name: &str) -> Result<()> {
    ensure!(
        (1..=48).contains(&name.len())
            && name.as_bytes()[0].is_ascii_alphanumeric()
            && name
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || b"-_.".contains(&c))
            && !name.ends_with('.'),
        "name must start with a letter/digit, contain only ASCII letters, digits, -, _, . and not end in ."
    );
    let stem = name
        .split('.')
        .next()
        .unwrap_or_default()
        .to_ascii_uppercase();
    let reserved = [
        "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8",
        "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    ];
    ensure!(
        !reserved.contains(&stem.as_str()),
        "name is reserved by Windows"
    );
    Ok(())
}

fn path_arg(path: &Path) -> Result<String> {
    let text = path.to_str().context("path is not valid UTF-8")?;
    ensure!(
        !text.contains(['\0', '\n', '\r']),
        "path contains control characters"
    );
    Ok(text.to_owned())
}

fn structured_path_arg(path: &Path) -> Result<String> {
    let text = path_arg(path)?;
    ensure!(
        !text.contains([',', '=']),
        "path contains an OpenVMM argument delimiter"
    );
    Ok(text)
}

fn input_path(
    base: &Path,
    path: &Path,
    role: &'static str,
    inputs: &mut Vec<Input>,
) -> Result<PathBuf> {
    ensure!(!path.as_os_str().is_empty(), "{role} path cannot be empty");
    let path = if path.is_absolute() {
        path.to_owned()
    } else {
        base.join(path)
    };
    path_arg(&path)?;
    let exists = path.is_file();
    inputs.push(Input {
        role,
        path: path.clone(),
        exists,
    });
    Ok(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    const QEMU_PROFILE: &str = r#"
schema_version = 1
name = "windows-custom"
cpus = 4
memory_mib = 8192
[runtime]
executable = "qemu-system-x86_64.exe"
[boot]
kind = "qemu_uefi"
firmware = "code.fd"
variables = "vars.fd"
disk = "system.qcow2"
read_only_base = false
headless = true
qmp_port = 61234
[identity]
preset = "limiar"
"#;

    #[test]
    fn qemu_plan_is_explicit_and_uses_only_loopback_control() {
        let directory = tempfile::tempdir().unwrap();
        for file in [
            "qemu-system-x86_64.exe",
            "code.fd",
            "vars.fd",
            "system.qcow2",
        ] {
            fs::write(directory.path().join(file), b"fixture").unwrap();
        }
        let mut config = VmConfig::parse(QEMU_PROFILE).unwrap();
        assert!(!config.plan(directory.path()).unwrap().ready);
        config.materialize_identity(None).unwrap();
        let plan = config.plan(directory.path()).unwrap();
        assert!(plan.ready);
        assert!(!plan.gpu_assignment);
        assert_eq!(plan.inputs.len(), 4);
        assert_eq!(plan.identity.unwrap().expected_dmi.len(), 22);
        for pair in [
            ["-accel", "whpx"],
            ["-cpu", "host"],
            ["-display", "none"],
            ["-nic", "none"],
            ["-qmp", "tcp:127.0.0.1:61234,server=on,wait=off"],
        ] {
            assert!(plan.arguments.windows(2).any(|args| args == pair));
        }
        assert!(!plan.arguments.iter().any(|arg| arg == "-snapshot"));
        assert!(!plan.arguments.iter().any(|arg| arg == "--hypervisor"));
    }

    #[test]
    fn qemu_defaults_to_temporary_writes_and_no_management_listener() {
        let text = QEMU_PROFILE
            .replace("read_only_base = false\n", "")
            .replace("qmp_port = 61234\n", "");
        let plan = VmConfig::parse(&text)
            .unwrap()
            .plan(Path::new("/tmp"))
            .unwrap();
        assert!(plan.arguments.iter().any(|arg| arg == "-snapshot"));
        assert!(!plan.arguments.iter().any(|arg| arg == "-qmp"));
    }

    #[test]
    fn qemu_optical_media_is_read_only_and_cannot_alias_writable_inputs() {
        let text =
            QEMU_PROFILE.replace("headless = true", "headless = true\ncdrom = \"tools.iso\"");
        let plan = VmConfig::parse(&text)
            .unwrap()
            .plan(Path::new("/tmp"))
            .unwrap();
        assert!(plan.inputs.iter().any(|input| input.role == "cdrom"));
        assert!(plan.arguments.iter().any(|argument| {
            argument.starts_with("if=none,id=cdrom,media=cdrom,format=raw,readonly=on,")
        }));
        for alias in ["vars.fd", "system.qcow2", "code.fd"] {
            let config = VmConfig::parse(&text.replace("tools.iso", alias)).unwrap();
            assert!(config.plan(Path::new("/tmp")).is_err());
        }
    }

    #[test]
    fn qemu_cpu_modes_are_explicit_choices_not_arbitrary_flags() {
        for model in ["host", "compatible", "max"] {
            let text = QEMU_PROFILE.replace(
                "headless = true",
                &format!("headless = true\ncpu_model = \"{model}\""),
            );
            assert!(VmConfig::parse(&text).is_ok());
        }
        let text = QEMU_PROFILE.replace(
            "headless = true",
            "headless = true\ncpu_model = \"host,surprise=on\"",
        );
        assert!(VmConfig::parse(&text).is_err());
    }

    #[test]
    fn json_profiles_share_validation_and_resolve_from_their_own_directory() {
        let directory = tempfile::tempdir().unwrap();
        let config = VmConfig::parse(QEMU_PROFILE).unwrap();
        let path = directory.path().join("profile.json");
        fs::write(&path, serde_json::to_vec(&config).unwrap()).unwrap();
        let (loaded, base) = VmConfig::load(&path).unwrap();
        let plan = loaded.plan(&base).unwrap();
        assert_eq!(plan.executable, base.join("qemu-system-x86_64.exe"));
        let mut value = serde_json::to_value(&config).unwrap();
        value["boot"]["extra_args"] = serde_json::json!(["-nic", "user"]);
        assert!(VmConfig::parse_json(&value.to_string()).is_err());
        assert!(VmConfig::parse_json(&" ".repeat(65_537)).is_err());
    }

    #[test]
    fn qemu_rejects_unsafe_port_aliases_and_missing_variables() {
        assert!(VmConfig::parse(&QEMU_PROFILE.replace("61234", "1023")).is_err());
        assert!(VmConfig::parse(&QEMU_PROFILE.replace("variables = \"vars.fd\"\n", "")).is_err());
        let config = VmConfig::parse(
            &QEMU_PROFILE.replace("variables = \"vars.fd\"", "variables = \"code.fd\""),
        )
        .unwrap();
        assert!(config.plan(Path::new("/tmp")).is_err());
        let config =
            VmConfig::parse(&QEMU_PROFILE.replace("code.fd", "code,readonly=off.fd")).unwrap();
        assert!(config.plan(Path::new("/tmp")).is_err());
    }

    const PROFILE: &str = r#"
schema_version = 1
name = "smoke"
cpus = 2
memory_mib = 512
[runtime]
executable = "openvmm.exe"
[boot]
kind = "linux_direct"
kernel = "kernel"
initrd = "initrd"
cmdline = "console=ttyS0"
[verification]
serial_marker = "guest-ready"
"#;

    #[test]
    fn accepts_strict_profile_and_resolves_from_profile_directory() {
        let base = tempfile::tempdir().unwrap();
        let plan = VmConfig::parse(PROFILE).unwrap().plan(base.path()).unwrap();
        assert_eq!(plan.executable, base.path().join("openvmm.exe"));
        assert!(!plan.ready);
        assert!(!plan.gpu_assignment);
        assert!(!plan.arguments.iter().any(|arg| arg == "--no-hv"));
    }

    #[test]
    fn rejects_unknown_fields_and_invalid_resources() {
        for bad in [
            PROFILE.replace("schema_version = 1", "schema_version = 2"),
            PROFILE.replace("cpus = 2", "cpus = 0"),
            PROFILE.replace("cpus = 2", "cpus = 65"),
            PROFILE.replace("memory_mib = 512", "memory_mib = 1"),
            PROFILE.replace("name = \"smoke\"", "name = \"../escape\""),
            PROFILE.replace("cpus = 2", "cpus = 2\nextra_args = [\"--device\", \"x\"]"),
            PROFILE.replace("cmdline =", "surprise = true\ncmdline ="),
            PROFILE.replace("guest-ready", ""),
        ] {
            assert!(VmConfig::parse(&bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn readiness_requires_all_files() {
        let dir = tempfile::tempdir().unwrap();
        for name in ["openvmm.exe", "kernel", "initrd"] {
            fs::write(dir.path().join(name), b"fixture").unwrap();
        }
        assert!(
            VmConfig::parse(PROFILE)
                .unwrap()
                .plan(dir.path())
                .unwrap()
                .ready
        );
    }

    #[test]
    fn structured_paths_reject_runtime_delimiters() {
        assert!(structured_path_arg(Path::new("disk,on=other")).is_err());
        assert!(structured_path_arg(Path::new("a=disk")).is_err());
        assert!(structured_path_arg(Path::new("disk with spaces.vhdx")).is_ok());
    }

    #[test]
    fn spaces_are_one_argument_not_a_shell_command() {
        let text = PROFILE.replace("kernel = \"kernel\"", "kernel = \"a b;echo\" ");
        let plan = VmConfig::parse(&text)
            .unwrap()
            .plan(Path::new("/tmp"))
            .unwrap();
        let i = plan
            .arguments
            .iter()
            .position(|arg| arg == "--kernel")
            .unwrap();
        assert!(plan.arguments[i + 1].ends_with("a b;echo"));
    }
}
