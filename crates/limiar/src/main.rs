use anyhow::{Context, Result, ensure};
use clap::{Parser, Subcommand};
use limiar::{config::VmConfig, platform, runner};
use serde_json::Value;
use std::fs::{self, OpenOptions};
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
    /// Native GPU diagnostics. These do not assign devices to VMs.
    Gpu {
        #[command(subcommand)]
        command: GpuCommands,
    },
    /// Validate profiles and supervise a separately built OpenVMM runtime.
    Vm {
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
}

#[derive(Subcommand)]
enum VmCommands {
    Plan {
        profile: PathBuf,
    },
    Run {
        profile: PathBuf,
        #[arg(long, default_value_t = 120, value_parser = clap::value_parser!(u64).range(1..=3600))]
        timeout_seconds: u64,
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
        Commands::Vm { command } => {
            let (profile, execution) = match command {
                VmCommands::Plan { profile } => (profile, None),
                VmCommands::Run {
                    profile,
                    timeout_seconds,
                    logs,
                } => (profile, Some((runner::Mode::Run, timeout_seconds, logs))),
                VmCommands::Smoke {
                    profile,
                    timeout_seconds,
                    logs,
                } => (profile, Some((runner::Mode::Smoke, timeout_seconds, logs))),
            };
            let (config, base) = VmConfig::load(&profile)?;
            let plan = config.plan(&base)?;
            match execution {
                None => {
                    let ready = plan.ready;
                    Ok((serde_json::to_value(plan)?, ready))
                }
                Some((mode, seconds, logs)) => {
                    ensure!(cfg!(windows), "WHP execution currently requires Windows");
                    let report = runner::execute(&plan, mode, Duration::from_secs(seconds), &logs)?;
                    let success = report.success;
                    Ok((serde_json::to_value(report)?, success))
                }
            }
        }
    }
}

fn emit(value: &Value, path: Option<&Path>) -> Result<()> {
    let text = serde_json::to_string_pretty(value)?;
    if let Some(path) = path {
        if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
            fs::create_dir_all(parent)?;
        }
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(path)
            .with_context(|| format!("cannot create report {}", path.display()))?;
        writeln!(file, "{text}")?;
    }
    println!("{text}");
    Ok(())
}

fn main() -> ExitCode {
    let cli = Cli::parse();
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
    if let Err(error) = emit(&value, cli.output.as_deref()) {
        eprintln!("{error:#}");
        return ExitCode::FAILURE;
    }
    if success {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    }
}
