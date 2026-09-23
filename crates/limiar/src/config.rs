use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct VmConfig {
    pub schema_version: u32,
    pub name: String,
    pub cpus: u16,
    pub memory_mib: u32,
    pub runtime: Runtime,
    pub boot: Boot,
    #[serde(default)]
    pub verification: Verification,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Runtime {
    pub executable: PathBuf,
}

#[derive(Debug, Deserialize)]
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
}

fn default_read_only() -> bool {
    true
}

#[derive(Debug, Default, Deserialize)]
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
}

impl VmConfig {
    pub fn parse(text: &str) -> Result<Self> {
        ensure!(text.len() <= 65_536, "profile exceeds 64 KiB");
        let config: Self = toml::from_str(text).context("invalid VM profile")?;
        ensure!(config.schema_version == 1, "unsupported schema_version");
        ensure!((1..=64).contains(&config.cpus), "cpus must be 1..64");
        ensure!(
            (128..=262_144).contains(&config.memory_mib),
            "memory_mib must be 128..262144"
        );
        ensure!(
            (1..=48).contains(&config.name.len())
                && config.name.as_bytes()[0].is_ascii_alphanumeric()
                && config
                    .name
                    .bytes()
                    .all(|c| c.is_ascii_alphanumeric() || b"-_.".contains(&c)),
            "name must start with a letter/digit and contain only ASCII letters, digits, -, _, ."
        );
        if let Some(marker) = &config.verification.serial_marker {
            ensure!(
                !marker.trim().is_empty() && marker.len() <= 512 && !marker.contains('\0'),
                "serial_marker must contain 1..512 non-NUL bytes"
            );
        }
        Ok(config)
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
        let config = Self::parse(&text)?;
        let base = path.parent().context("profile has no parent directory")?;
        Ok((config, base.to_owned()))
    }

    pub fn plan(&self, base: &Path) -> Result<LaunchPlan> {
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
        }
        Ok(LaunchPlan {
            schema_version: 1,
            name: self.name.clone(),
            executable,
            arguments,
            ready: inputs.iter().all(|input| input.exists),
            inputs,
            serial_marker: self.verification.serial_marker.clone(),
            gpu_assignment: false,
        })
    }
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
