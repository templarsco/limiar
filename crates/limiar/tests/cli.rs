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

#[test]
fn managed_profiles_can_be_registered_updated_inspected_and_unregistered() {
    let directory = tempfile::tempdir().unwrap();
    let profile = write_profile(directory.path());
    let registry = directory.path().join("registry");
    let registry = registry.to_str().unwrap();
    let registered = cli(&[
        "vm",
        "register",
        profile.to_str().unwrap(),
        "--registry",
        registry,
    ]);
    assert!(registered.status.success(), "{registered:?}");
    let duplicate = cli(&[
        "vm",
        "register",
        profile.to_str().unwrap(),
        "--registry",
        registry,
    ]);
    assert!(!duplicate.status.success());

    let listed = cli(&["vm", "list", "--registry", registry]);
    assert!(listed.status.success());
    let inventory: Value = serde_json::from_slice(&listed.stdout).unwrap();
    assert_eq!(inventory["vms"][0]["name"], "cli-test");
    assert_eq!(inventory["vms"][0]["state"], "registered");
    let shown = cli(&["vm", "show", "CLI-TEST", "--registry", registry]);
    assert!(shown.status.success());
    let snapshot: Value = serde_json::from_slice(&shown.stdout).unwrap();
    assert_eq!(snapshot["revision"], 1);
    assert!(
        Path::new(
            snapshot["profile"]["runtime"]["executable"]
                .as_str()
                .unwrap()
        )
        .is_absolute()
    );

    let updated = cli(&[
        "vm",
        "update",
        "cli-test",
        profile.to_str().unwrap(),
        "--registry",
        registry,
    ]);
    assert!(updated.status.success());
    let snapshot: Value = serde_json::from_slice(&updated.stdout).unwrap();
    assert_eq!(snapshot["revision"], 2);
    fs::remove_file(profile).unwrap();
    assert!(
        cli(&["vm", "preview", "cli-test", "--registry", registry])
            .status
            .success()
    );
    assert!(
        cli(&["vm", "status", "cli-test", "--registry", registry])
            .status
            .success()
    );

    let removed = cli(&["vm", "unregister", "cli-test", "--registry", registry]);
    assert!(removed.status.success());
    let report: Value = serde_json::from_slice(&removed.stdout).unwrap();
    assert_eq!(report["input_images_deleted"], false);
    assert!(directory.path().join("kernel").exists());
    assert!(
        !cli(&["vm", "status", "cli-test", "--registry", registry])
            .status
            .success()
    );
}

#[test]
fn existing_output_prevents_registry_mutations() {
    let directory = tempfile::tempdir().unwrap();
    let profile = write_profile(directory.path());
    let registry = directory.path().join("registry");
    let report = directory.path().join("report.json");
    fs::write(&report, b"do not overwrite").unwrap();
    let output = cli(&[
        "--output",
        report.to_str().unwrap(),
        "vm",
        "register",
        profile.to_str().unwrap(),
        "--registry",
        registry.to_str().unwrap(),
    ]);
    assert!(!output.status.success());
    assert!(!registry.exists());
    assert_eq!(fs::read(report).unwrap(), b"do not overwrite");
}

#[test]
fn managed_stop_requires_explicit_force_and_is_idempotent_when_stopped() {
    let directory = tempfile::tempdir().unwrap();
    let profile = write_profile(directory.path());
    let registry = directory.path().join("registry");
    let registry = registry.to_str().unwrap();
    assert!(
        cli(&[
            "vm",
            "register",
            profile.to_str().unwrap(),
            "--registry",
            registry
        ])
        .status
        .success()
    );
    assert!(
        !cli(&["vm", "stop", "cli-test", "--registry", registry])
            .status
            .success()
    );
    let stopped = cli(&["vm", "stop", "cli-test", "--force", "--registry", registry]);
    assert!(stopped.status.success());
    let status: Value = serde_json::from_slice(&stopped.stdout).unwrap();
    assert_eq!(status["supervisor_active"], false);
    assert_eq!(status["state"], "registered");
}

#[test]
fn identity_registration_materializes_defaults_and_update_keeps_identifiers() {
    let directory = tempfile::tempdir().unwrap();
    let profile = write_profile(directory.path());
    let text = format!(
        "{}\n[identity]\npreset = \"limiar\"\n",
        fs::read_to_string(&profile).unwrap()
    );
    fs::write(&profile, &text).unwrap();
    let pending = cli(&["vm", "plan", profile.to_str().unwrap()]);
    assert!(!pending.status.success());
    let plan: Value = serde_json::from_slice(&pending.stdout).unwrap();
    assert_eq!(plan["identity"]["requires_registration"], true);
    let registry = directory.path().join("registry");
    let registry = registry.to_str().unwrap();
    let registration = cli(&[
        "vm",
        "register",
        profile.to_str().unwrap(),
        "--registry",
        registry,
    ]);
    assert!(registration.status.success(), "{registration:?}");
    let record: Value = serde_json::from_slice(&registration.stdout).unwrap();
    let original = &record["profile"]["identity"]["system"];
    assert_eq!(original["manufacturer"], "Limiar");
    assert_eq!(original["product"], "Limiar One");
    assert!(original["uuid"].as_str().unwrap().len() == 36);
    assert!(original["serial"].as_str().unwrap().starts_with("LMR-"));
    let updated = cli(&[
        "vm",
        "update",
        "cli-test",
        profile.to_str().unwrap(),
        "--registry",
        registry,
    ]);
    assert!(updated.status.success(), "{updated:?}");
    let record: Value = serde_json::from_slice(&updated.stdout).unwrap();
    assert_eq!(&record["profile"]["identity"]["system"], original);
    let preview = cli(&["vm", "preview", "cli-test", "--registry", registry]);
    assert!(preview.status.success(), "{preview:?}");
    let plan: Value = serde_json::from_slice(&preview.stdout).unwrap();
    assert_eq!(plan["identity"]["requires_registration"], false);
    assert_eq!(
        plan["identity"]["expected_dmi"]["product_uuid"],
        original["uuid"]
    );
    assert_eq!(
        plan["identity"]["expected_dmi"]["product_serial"],
        original["serial"]
    );
}

#[test]
fn unsupported_identity_fields_fail_before_registration() {
    let directory = tempfile::tempdir().unwrap();
    let profile = write_profile(directory.path());
    let original = fs::read_to_string(&profile).unwrap();
    for section in ["baseboard", "chassis", "cpuid", "acpi"] {
        fs::write(
            &profile,
            format!("{original}\n[identity.{section}]\nvendor = \"Custom\"\n"),
        )
        .unwrap();
        let registry = directory.path().join(section);
        let output = cli(&[
            "vm",
            "register",
            profile.to_str().unwrap(),
            "--registry",
            registry.to_str().unwrap(),
        ]);
        assert!(!output.status.success(), "{section}");
        assert!(!registry.join("cli-test").exists());
        let report: Value = serde_json::from_slice(&output.stdout).unwrap();
        assert!(report["error"].as_str().unwrap().contains("unknown field"));
    }
}

#[test]
fn interactive_lifetime_is_explicit_and_conflicts_with_diagnostic_limits() {
    let directory = tempfile::tempdir().unwrap();
    let output = cli(&[
        "vm",
        "start",
        "not-registered",
        "--registry",
        directory.path().to_str().unwrap(),
        "--until-shutdown",
    ]);
    assert!(!output.status.success());
    let report: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert!(report["error"].is_string());
    for additional in [vec!["--timeout-seconds", "60"], vec!["--smoke"]] {
        let mut arguments = vec!["vm", "start", "not-registered", "--until-shutdown"];
        arguments.extend(additional);
        let output = cli(&arguments);
        assert!(!output.status.success());
        assert!(String::from_utf8_lossy(&output.stderr).contains("cannot be used with"));
    }
}

#[test]
fn linux_identity_verifier_rejects_qemu_before_starting_it() {
    let directory = tempfile::tempdir().unwrap();
    let profile = directory.path().join("qemu.toml");
    fs::write(
        &profile,
        r#"
schema_version = 1
name = "qemu-verify"
cpus = 2
memory_mib = 4096
[runtime]
executable = "missing-runtime.exe"
[boot]
kind = "qemu_uefi"
firmware = "code.fd"
variables = "vars.fd"
disk = "system.qcow2"
[identity]
preset = "limiar"
"#,
    )
    .unwrap();
    let registry = directory.path().join("registry");
    let output = cli(&[
        "vm",
        "register",
        profile.to_str().unwrap(),
        "--registry",
        registry.to_str().unwrap(),
    ]);
    assert!(output.status.success());
    let output = cli(&[
        "vm",
        "verify-identity",
        "qemu-verify",
        "--registry",
        registry.to_str().unwrap(),
    ]);
    assert!(!output.status.success());
    let report: Value = serde_json::from_slice(&output.stdout).unwrap();
    let error = report["error"].as_str().unwrap();
    assert!(error.contains(if cfg!(windows) {
        "Linux direct probe"
    } else {
        "requires Windows"
    }));
    assert!(!registry.join("qemu-verify/state.json").exists());
}

#[test]
fn gpu_pv_probe_requires_explicit_experimental_flag_before_accessing_hardware() {
    let output = cli(&[
        "gpu",
        "pv",
        "probe",
        "--adapter",
        "RX",
        "--kernel",
        "kernel",
        "--initrd",
        "initrd",
    ]);
    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("--experimental"));
}
