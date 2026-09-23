pub mod config;
pub mod report;
pub mod runner;

#[cfg(windows)]
#[path = "windows.rs"]
pub mod platform;

#[cfg(not(windows))]
#[path = "unsupported.rs"]
pub mod platform;
