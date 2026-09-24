use anyhow::{Context, Result, ensure};
use clap::{Parser, Subcommand};
use limiar::{config::VmConfig, gpu_pv, identity, platform, registry::Registry, runner};
use serde_json::Value;
use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::Duration;

#[derive(Parser)]
#[command(version, about = "Limiar VM launcher and hardware diagnostics")]
struct Cli {
    #[arg(
        long,
        global = true,
        help = "Write JSON to a new file (never overwrite)"
    )]
    output: Option<PathBuf>,
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Read-only host, WHP, and GPU inventory.
    Doctor,
    /// Hardware diagnostics and an explicitly enabled experimental GPU-PV lab.
    Gpu {
        #[command(subcommand)]
        command: GpuCommands,
    },
    /// Validate profiles and supervise a separately built OpenVMM runtime.
    Vm {
        #[arg(long, global = true, default_value = ".limiar/vms")]
        registry: PathBuf,
        #[command(subcommand)]
        command: VmCommands,
    },
}

#[derive(Subcommand)]
enum GpuCommands {
    List,
    Test {
        #[arg(long, help = "DXGI index or an unambiguous hardware adapter name")]
        adapter: String,
        #[arg(long, default_value_t = 3, value_parser = clap::value_parser!(u16).range(1..=32))]
        iterations: u16,
    },
    /// Shared GPU inventory and a disposable HCS Linux probe.
    Pv {
        #[command(subcommand)]
        command: GpuPvCommands,
    },
}

#[derive(Subcommand)]
enum GpuPvCommands {
    /// Query advertised partitionable GPUs without changing the host.
    List,
    /// Preview an exact-adapter HCS request. Creates no VM.
    Plan {
        #[arg(long)]
        adapter: String,
        #[arg(long)]
        kernel: PathBuf,
        #[arg(long)]
        initrd: PathBuf,
        #[arg(long)]
        verify_rendering: bool,
    },
    /// Run a disposable HCS GPU-PV probe, optionally verifying D3D12 pixels.
    Probe {
        #[arg(
            long,
            required = true,
            help = "Acknowledge experimental host GPU sharing"
        )]
        experimental: bool,
        #[arg(
            long,
            help = "Require guest D3D12 pixel readback; needs a GPU-enabled probe initrd"
        )]
        verify_rendering: bool,
        #[arg(long)]
        adapter: String,
        #[arg(long)]
        kernel: PathBuf,
        #[arg(long)]
        initrd: PathBuf,
        #[arg(long, default_value_t = 60, value_parser = clap::value_parser!(u64).range(1..=300))]
        timeout_seconds: u64,
        #[arg(long, default_value = ".limiar/runs")]
        logs: PathBuf,
    },
}

#[derive(Subcommand)]
enum VmCommands {
    /// Register a validated, resolved snapshot of a profile.
    Register {
        profile: PathBuf,
    },
    /// Replace a stopped VM's profile snapshot.
    Update {
        name: String,
        profile: PathBuf,
    },
    /// List registered VMs and report corrupt entries separately.
    List,
    /// Inspect a registered profile snapshot.
    Show {
        name: String,
    },
    /// Preview a registered VM's runtime arguments and input availability.
    Preview {
        name: String,
    },
    /// Inspect the supervisor state; does not infer liveness from a PID.
    Status {
        name: String,
    },
    /// Boot a registered Linux probe, then compare its DMI report with the profile.
    VerifyIdentity {
        name: String,
        #[arg(long, default_value_t = 90, value_parser = clap::value_parser!(u64).range(1..=3600))]
        timeout_seconds: u64,
        #[arg(long, default_value = ".limiar/runs")]
        logs: PathBuf,
    },
    /// Start a registered VM under foreground supervision.
    Start {
        name: String,
        #[arg(long, default_value_t = 120, value_parser = clap::value_parser!(u64).range(1..=86400))]
        timeout_seconds: u64,
        #[arg(long, conflicts_with_all = ["timeout_seconds", "smoke"], help = "Run until the guest exits or an explicit stop is requested")]
        until_shutdown: bool,
        #[arg(long, default_value = ".limiar/runs")]
        logs: PathBuf,
        #[arg(long, help = "Stop after observing the configured serial marker")]
        smoke: bool,
    },
    /// Request forced runtime termination from another terminal.
    Stop {
        name: String,
        #[arg(long, help = "Acknowledge that this is not a graceful guest shutdown")]
        force: bool,
        #[arg(long, default_value_t = 10, value_parser = clap::value_parser!(u64).range(1..=60))]
        wait_seconds: u64,
    },
    /// Remove only registration metadata, never VM input images or logs.
    Unregister {
        name: String,
    },
    Plan {
        profile: PathBuf,
    },
    Run {
        profile: PathBuf,
        #[arg(long, default_value_t = 120, value_parser = clap::value_parser!(u64).range(1..=86400))]
        timeout_seconds: u64,
        #[arg(
            long,
            conflicts_with = "timeout_seconds",
            help = "Run until the guest exits"
        )]
        until_shutdown: bool,
        #[arg(long, default_value = ".limiar/runs")]
        logs: PathBuf,
    },
    Smoke {
        profile: PathBuf,
        #[arg(long, default_value_t = 60, value_parser = clap::value_parser!(u64).range(1..=3600))]
        timeout_seconds: u64,
        #[arg(long, default_value = ".limiar/runs")]
        logs: PathBuf,
    },
}

fn dispatch(command: Commands) -> Result<(Value, bool)> {
    match command {
        Commands::Doctor => Ok((serde_json::to_value(platform::doctor()?)?, true)),
        Commands::Gpu { command } => match command {
            GpuCommands::Pv { command } => dispatch_gpu_pv(command),
            GpuCommands::List => Ok((
                serde_json::json!({"schema_version": 1, "adapters": platform::adapters()?}),
                true,
            )),
            GpuCommands::Test {
                adapter,
                iterations,
            } => Ok((
                serde_json::to_value(platform::gpu_test(&adapter, iterations)?)?,
                true,
            )),
        },
        Commands::Vm { registry, command } => dispatch_vm(command, &registry),
    }
}

fn dispatch_gpu_pv(command: GpuPvCommands) -> Result<(Value, bool)> {
    match command {
        GpuPvCommands::List => {
            let inventory = platform::gpu_pv_inventory()?;
            let queried = inventory.status == "queried";
            Ok((serde_json::to_value(inventory)?, queried))
        }
        GpuPvCommands::Plan {
            adapter,
            kernel,
            initrd,
            verify_rendering,
        } => {
            let inventory = platform::gpu_pv_inventory()?;
            let adapter = gpu_pv::select(&inventory, &adapter)?;
            Ok((
                serde_json::to_value(gpu_pv::plan(adapter, &kernel, &initrd, verify_rendering)?)?,
                true,
            ))
        }
        GpuPvCommands::Probe {
            experimental,
            verify_rendering,
            adapter,
            kernel,
            initrd,
            timeout_seconds,
            logs,
        } => {
            ensure!(experimental, "GPU-PV probe requires --experimental");
            let inventory = platform::gpu_pv_inventory()?;
            let adapter = gpu_pv::select(&inventory, &adapter)?;
            let plan = gpu_pv::plan(adapter, &kernel, &initrd, verify_rendering)?;
            let report =
                platform::gpu_pv_probe(&plan, Duration::from_secs(timeout_seconds), &logs)?;
            let success = report.success;
            Ok((serde_json::to_value(report)?, success))
        }
    }
}

fn run_profile(
    profile: &Path,
    mode: runner::Mode,
    seconds: u64,
    logs: &Path,
) -> Result<(Value, bool)> {
    ensure!(cfg!(windows), "WHP execution currently requires Windows");
    let (config, base) = VmConfig::load(profile)?;
    let plan = config.plan(&base)?;
    let report = runner::execute(&plan, mode, Duration::from_secs(seconds), logs)?;
    let success = report.success;
    Ok((serde_json::to_value(report)?, success))
}

fn dispatch_vm(command: VmCommands, root: &Path) -> Result<(Value, bool)> {
    match command {
        VmCommands::Plan { profile } => {
            let (config, base) = VmConfig::load(&profile)?;
            let plan = config.plan(&base)?;
            let ready = plan.ready;
            Ok((serde_json::to_value(plan)?, ready))
        }
        VmCommands::Run {
            profile,
            timeout_seconds,
            until_shutdown,
            logs,
        } => run_profile(
            &profile,
            runner::Mode::Run,
            if until_shutdown {
                u64::MAX
            } else {
                timeout_seconds
            },
            &logs,
        ),
        VmCommands::Smoke {
            profile,
            timeout_seconds,
            logs,
        } => run_profile(&profile, runner::Mode::Smoke, timeout_seconds, &logs),
        VmCommands::Register { profile } => Ok((
            serde_json::to_value(Registry::open(root)?.register(&profile)?)?,
            true,
        )),
        VmCommands::Update { name, profile } => Ok((
            serde_json::to_value(Registry::open(root)?.update(&name, &profile)?)?,
            true,
        )),
        VmCommands::List => {
            let inventory = Registry::open(root)?.list()?;
            let success = inventory.errors.is_empty();
            Ok((serde_json::to_value(inventory)?, success))
        }
        VmCommands::Show { name } => Ok((
            serde_json::to_value(Registry::open(root)?.show(&name)?)?,
            true,
        )),
        VmCommands::Preview { name } => {
            let plan = Registry::open(root)?.preview(&name)?;
            let ready = plan.ready;
            Ok((serde_json::to_value(plan)?, ready))
        }
        VmCommands::Status { name } => Ok((
            serde_json::to_value(Registry::open(root)?.status(&name)?)?,
            true,
        )),
        VmCommands::VerifyIdentity {
            name,
            timeout_seconds,
            logs,
        } => {
            ensure!(cfg!(windows), "WHP execution currently requires Windows");
            let registry = Registry::open(root)?;
            ensure!(
                matches!(
                    registry.show(&name)?.profile.boot,
                    limiar::config::Boot::LinuxDirect { .. }
                ),
                "vm verify-identity requires the Linux direct probe; use scripts/qemu/Test-GuestIdentity.ps1 for Windows reports"
            );
            let plan = registry.preview(&name)?;
            let expected = plan
                .identity
                .as_ref()
                .context("profile has no identity configuration")?;
            ensure!(
                !expected.requires_registration,
                "registered identity is incomplete"
            );
            let run = registry.start(
                &name,
                runner::Mode::Run,
                Duration::from_secs(timeout_seconds),
                &logs,
            )?;
            let transcript = runner::read_transcript(&run.stdout_log, &run.stderr_log)?
                .context("guest transcript exceeds the log limit")?;
            let verification = run
                .expected_dmi
                .as_ref()
                .context("the launched profile had no identity configuration")
                .and_then(|expected| identity::verify(expected, &transcript));
            let success = run.success && verification.as_ref().is_ok_and(|result| result.passed);
            let identity = match verification {
                Ok(result) => serde_json::to_value(result)?,
                Err(error) => serde_json::json!({"passed": false, "error": format!("{error:#}")}),
            };
            Ok((
                serde_json::json!({
                    "schema_version": 1, "success": success, "run": run, "identity": identity
                }),
                success,
            ))
        }
        VmCommands::Start {
            name,
            timeout_seconds,
            until_shutdown,
            logs,
            smoke,
        } => {
            ensure!(cfg!(windows), "WHP execution currently requires Windows");
            let mode = if smoke {
                runner::Mode::Smoke
            } else {
                runner::Mode::Run
            };
            let report = Registry::open(root)?.start(
                &name,
                mode,
                Duration::from_secs(if until_shutdown {
                    u64::MAX
                } else {
                    timeout_seconds
                }),
                &logs,
            )?;
            let success = report.success;
            Ok((serde_json::to_value(report)?, success))
        }
        VmCommands::Stop {
            name,
            force,
            wait_seconds,
        } => {
            let status =
                Registry::open(root)?.stop(&name, force, Duration::from_secs(wait_seconds))?;
            Ok((serde_json::to_value(status)?, true))
        }
        VmCommands::Unregister { name } => {
            Registry::open(root)?.unregister(&name)?;
            Ok((
                serde_json::json!({"schema_version": 1, "name": name, "unregistered": true, "input_images_deleted": false}),
                true,
            ))
        }
    }
}

fn report_file(path: Option<&Path>) -> Result<Option<File>> {
    if let Some(path) = path {
        if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
            fs::create_dir_all(parent)?;
        }
        let file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(path)
            .with_context(|| format!("cannot create report {}", path.display()))?;
        return Ok(Some(file));
    }
    Ok(None)
}

fn emit(value: &Value, file: Option<&mut File>) -> Result<()> {
    let text = serde_json::to_string_pretty(value)?;
    if let Some(file) = file {
        writeln!(file, "{text}")?;
    }
    println!("{text}");
    Ok(())
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    let mut output = match report_file(cli.output.as_deref()) {
        Ok(output) => output,
        Err(error) => {
            eprintln!("{error:#}");
            return ExitCode::FAILURE;
        }
    };
    let (value, success) = match dispatch(cli.command) {
        Ok(result) => result,
        Err(error) => (
            serde_json::json!({
                "schema_version": 1,
                "status": "failed",
                "error": format!("{error:#}")
            }),
            false,
        ),
    };
    if let Err(error) = emit(&value, output.as_mut()) {
        eprintln!("{error:#}");
        return ExitCode::FAILURE;
    }
    if success {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    }
}
