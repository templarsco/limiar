use serde_json::{Value, json};
use std::fs;
use std::path::Path;
use std::process::{Command, Output};

fn cli(args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_limiar"))
        .args(args)
        .output()
        .unwrap()
}

fn write_profile(directory: &Path) -> std::path::PathBuf {
    for file in ["runtime with spaces.exe", "kernel", "initrd"] {
        fs::write(directory.join(file), b"not executable; plan only").unwrap();
    }
    let text = toml::to_string(&json!({
        "schema_version": 1,
        "name": "cli-test",
        "cpus": 2,
        "memory_mib": 512,
        "runtime": {"executable": "runtime with spaces.exe"},
        "boot": {"kind": "linux_direct", "kernel": "kernel", "initrd": "initrd"},
        "verification": {"serial_marker": "test-ready"}
    }))
    .unwrap();
    let path = directory.join("profile.toml");
    fs::write(&path, text).unwrap();
    path
}

#[test]
fn help_and_version_are_usable() {
    let help = cli(&["--help"]);
    assert!(help.status.success());
    assert!(String::from_utf8_lossy(&help.stdout).contains("Limiar"));
    assert!(cli(&["--version"]).status.success());
}

#[test]
fn missing_profile_is_a_structured_failure() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("missing.toml");
    let output = cli(&["vm", "plan", path.to_str().unwrap()]);
    assert!(!output.status.success());
    let report: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(report["status"], "failed");
}

#[test]
fn plans_use_profile_directory_and_keep_space_containing_paths_intact() {
    let directory = tempfile::tempdir().unwrap();
    let profile = write_profile(directory.path());
    let output = cli(&["vm", "plan", profile.to_str().unwrap()]);
    assert!(output.status.success(), "{output:?}");
    let plan: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(plan["ready"], true);
    assert_eq!(plan["gpu_assignment"], false);
    assert!(
        plan["executable"]
            .as_str()
            .unwrap()
            .ends_with("runtime with spaces.exe")
    );
    assert!(
        !plan["arguments"]
            .as_array()
            .unwrap()
            .contains(&json!("--device"))
    );
}

#[test]
fn existing_reports_are_not_overwritten() {
    let directory = tempfile::tempdir().unwrap();
    let profile = write_profile(directory.path());
    let report = directory.path().join("report.json");
    fs::write(&report, b"sentinel").unwrap();
    let output = cli(&[
        "--output",
        report.to_str().unwrap(),
        "vm",
        "plan",
        profile.to_str().unwrap(),
    ]);
    assert!(!output.status.success());
    assert_eq!(fs::read(report).unwrap(), b"sentinel");
}

#[test]
fn gpu_workload_limits_are_checked_before_accessing_hardware() {
    for iterations in ["0", "33", "65536"] {
        let output = cli(&["gpu", "test", "--adapter", "0", "--iterations", iterations]);
        assert!(!output.status.success());
    }
}

#[test]
fn output_file_matches_stdout_json() {
    let directory = tempfile::tempdir().unwrap();
    let profile = write_profile(directory.path());
    let report = directory.path().join("new-report.json");
    let output = cli(&[
        "--output",
        report.to_str().unwrap(),
        "vm",
        "plan",
        profile.to_str().unwrap(),
    ]);
    assert!(output.status.success());
    let from_stdout: Value = serde_json::from_slice(&output.stdout).unwrap();
    let from_file: Value = serde_json::from_slice(&fs::read(report).unwrap()).unwrap();
    assert_eq!(from_stdout, from_file);
}
